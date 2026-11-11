'use strict';
/* NX 游戏库 — 前端逻辑（纯原生，无外部依赖）
   接口契约（与 server.py 严格一致）：
   GET    /api/status
   GET    /api/config            PUT /api/config
   GET    /api/games
   POST   /api/build             POST /api/build/cancel
   GET    /api/build/status      GET  /api/build/events (SSE)
   GET    /api/build/log?folder=
   POST   /api/launch            POST /api/launch/stop
   GET    /api/launch/status
*/

/* ============ API 封装 ============ */

class ApiError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

async function apiJSON(url, opts) {
  let res;
  try {
    res = await fetch(url, opts);
  } catch (e) {
    throw new ApiError(0, '网络错误：无法连接本地服务');
  }
  let body = null;
  try { body = await res.json(); } catch (e) { /* 非 JSON 响应 */ }
  if (!res.ok) {
    const msg = (body && (body.error || body.message)) || ('请求失败（HTTP ' + res.status + '）');
    throw new ApiError(res.status, msg);
  }
  return body;
}

const api = {
  status: () => apiJSON('/api/status'),
  getConfig: () => apiJSON('/api/config'),
  putConfig: (cfg) => apiJSON('/api/config', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(cfg),
  }),
  games: () => apiJSON('/api/games'),
  build: (folder) => apiJSON('/api/build', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ folder }),
  }),
  buildCancel: () => apiJSON('/api/build/cancel', { method: 'POST' }),
  buildStatus: () => apiJSON('/api/build/status'),
  buildLog: async (folder) => {
    let res;
    try {
      res = await fetch('/api/build/log?folder=' + encodeURIComponent(folder));
    } catch (e) {
      throw new ApiError(0, '网络错误：无法连接本地服务');
    }
    if (!res.ok) {
      let body = null;
      try { body = await res.json(); } catch (e) { /* ignore */ }
      throw new ApiError(res.status, (body && body.error) || ('读取日志失败（HTTP ' + res.status + '）'));
    }
    return res.text();
  },
  launch: (folder) => apiJSON('/api/launch', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ folder }),
  }),
  launchStop: () => apiJSON('/api/launch/stop', { method: 'POST' }),
  launchStatus: () => apiJSON('/api/launch/status'),
};

/* ============ 状态 ============ */

const state = {
  status: null,          // /api/status
  config: null,          // /api/config
  games: [],             // GameInfo[]
  names: {},             // title_id -> name
  build: { building: false, folder: null },
  launch: { running: false, folder: null, tail: [] },
  // 构建事件流的展示状态
  stream: {
    k: 0, n: 0, name: '', step: '',
    frac: null, eta: null, done: null, total: null, unit: '', est: false,
    lastOk: true, lastSummary: '', lastRed: '',
    sawEvents: false, firstT: null, lastSeq: null,
  },
  logFollow: true,
  esOpen: false,
  launchErrShown: false,
};

const $ = (id) => document.getElementById(id);

/* ============ 小工具 ============ */

function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function toast(msg, kind) {
  const box = $('toasts');
  const el = document.createElement('div');
  el.className = 'toast ' + (kind || 'error');
  el.textContent = msg;
  el.addEventListener('click', () => el.remove());
  box.appendChild(el);
  setTimeout(() => { el.remove(); }, 4200);
  while (box.children.length > 4) box.removeChild(box.firstChild);
}

function hms(sec) {
  if (sec == null || !isFinite(sec) || sec < 0) return '';
  sec = Math.round(sec);
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
  const p2 = (x) => String(x).padStart(2, '0');
  return h > 0 ? h + ':' + p2(m) + ':' + p2(s) : m + ':' + p2(s);
}

function durCN(sec) {
  if (sec == null || !isFinite(sec)) return '';
  sec = Math.round(sec);
  if (sec < 60) return sec + '秒';
  const m = Math.floor(sec / 60), s = sec % 60;
  if (m < 60) return m + '分' + (s ? s + '秒' : '');
  const h = Math.floor(m / 60);
  return h + '时' + (m % 60 ? (m % 60) + '分' : '');
}

function fmtBytes(n) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0, v = n;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return (i === 0 ? String(Math.round(v)) : v.toFixed(1)) + ' ' + u[i];
}

/* done/total + unit 的人性化展示（unit 'B' = 字节） */
function fmtCount(done, total, unit, est) {
  if (done == null) return '';
  if (!total) return unit === 'B' ? fmtBytes(done) : (done.toLocaleString() + (unit ? ' ' + unit : ''));
  if (unit === 'B') {
    let i = 0, t = total;
    while (t >= 1024 && i < 3) { t /= 1024; i++; }
    const d = 1024 ** i;
    const uu = ['B', 'KB', 'MB', 'GB'][i];
    return (done / d).toFixed(1) + '/~' + (total / d).toFixed(1) + ' ' + uu;
  }
  return done.toLocaleString() + '/' + (est ? '~' : '') + total.toLocaleString() + (unit ? ' ' + unit : '');
}

/* ============ 渲染：顶栏状态 ============ */

function renderStatus() {
  const st = state.status;
  const dotRepo = $('dot-repo'), dotKeys = $('dot-keys'), dotTools = $('dot-tools');
  if (!st) {
    [dotRepo, dotKeys, dotTools].forEach((d) => { d.className = 'dot'; });
    return;
  }
  dotRepo.className = 'dot ' + (st.repo_ok ? 'ok' : 'bad');
  dotRepo.title = st.repo_ok ? '仓库就绪：' + (st.repo || '') : '仓库缺失（找不到 scripts/build_ipa_from_nsp.py）';

  dotKeys.className = 'dot ' + (st.keys_ok ? 'ok' : 'bad');
  dotKeys.title = st.keys_ok ? 'prod.keys 就绪：' + (st.keys || '') : '未找到 prod.keys，请在设置中填写路径';

  const tools = st.tools || {};
  const missing = Object.keys(tools).filter((k) => !tools[k]);
  dotTools.className = 'dot ' + (missing.length ? 'bad' : 'ok');
  dotTools.title = missing.length
    ? '缺少工具：' + missing.join('、')
    : '工具链齐全（xcodebuild / xcodegen / dotnet / zstd / spirv-cross / metal）';

  const strip = $('warn-strip'), txt = $('warn-strip-text');
  const warns = [];
  if (!st.repo_ok) warns.push('未找到构建脚本仓库，无法构建');
  if (!st.keys_ok) warns.push('未配置 prod.keys，无法构建');
  if (missing.length) warns.push('缺少工具：' + missing.join('、'));
  if (warns.length) {
    txt.textContent = warns.join('；');
    strip.classList.remove('hidden');
  } else {
    strip.classList.add('hidden');
  }
}

/* ============ 游戏工具 ============ */

function gameByFolder(folder) {
  return state.games.find((g) => g.folder === folder) || null;
}

function displayNameOf(folder) {
  const g = gameByFolder(folder);
  if (g) return g.display_name || g.folder;
  return folder || '';
}

function launchBlockReason(g) {
  if (!g.build) return '尚未构建';
  if (!g.build.has_dmhost) return '缺少 dmhost，请重新构建';
  if (!g.build.has_msl) return '缺少着色器库，请重新构建';
  if (state.build.building) return '构建进行中';
  if (state.launch.running && state.launch.folder !== g.folder) return '已有游戏在运行';
  return null;
}

function buildBlockReason(g) {
  if (state.build.building) return '已有构建在进行中';
  return null;
}

function stopAction(g) {
  if (state.build.building && state.build.folder === g.folder) return 'build';
  if (state.launch.running && state.launch.folder === g.folder) return 'launch';
  return null;
}

/* ============ 渲染：游戏网格 ============ */

function renderGames() {
  const grid = $('grid'), empty = $('empty');
  const lib = state.status && state.status.library_ok;
  const games = state.games;

  if (!games.length) {
    grid.innerHTML = '';
    empty.classList.remove('hidden');
    const t = $('empty-title'), d = $('empty-desc'), a = $('empty-actions');
    a.innerHTML = '';
    if (!lib) {
      t.textContent = '尚未配置游戏库';
      d.textContent = '打开「设置」，填写 prod.keys 路径与游戏库目录（游戏库下每个含 .nsp / .xci 的文件夹会显示为一张卡片）。';
      const b = document.createElement('button');
      b.className = 'btn primary'; b.type = 'button'; b.textContent = '打开设置';
      b.addEventListener('click', openSettings);
      a.appendChild(b);
    } else {
      t.textContent = '游戏库中没有找到游戏';
      d.textContent = '在游戏库目录下放入包含 .nsp 或 .xci 文件的文件夹，然后点「刷新」。';
      const b = document.createElement('button');
      b.className = 'btn'; b.type = 'button'; b.textContent = '刷新';
      b.addEventListener('click', refreshAll);
      const s = document.createElement('button');
      s.className = 'btn'; s.type = 'button'; s.textContent = '设置';
      s.addEventListener('click', openSettings);
      a.appendChild(b); a.appendChild(s);
    }
    return;
  }

  empty.classList.add('hidden');
  grid.innerHTML = games.map(cardHTML).join('');
}

function cardHTML(g) {
  const b = g.build;
  const running = state.launch.running && state.launch.folder === g.folder;
  const building = state.build.building && state.build.folder === g.folder;
  const launchable = b && b.has_dmhost && b.has_msl;

  let statusBadge;
  if (running) statusBadge = '<span class="badge green pulse">运行中</span>';
  else if (building) statusBadge = '<span class="badge orange">构建中…</span>';
  else if (launchable) statusBadge = '<span class="badge green">可启动</span>';
  else statusBadge = '<span class="badge gray">可构建</span>';

  const badges = [
    g.profile ? '<span class="badge green" title="该游戏在 dm/games 下已有配置">已建档</span>'
              : '<span class="badge gray" title="该游戏在 dm/games 下没有配置，构建时会先调查生成">未建档</span>',
  ];
  if (g.versions && g.versions.length) {
    const vs = [...g.versions].sort((x, y) => x - y);
    badges.push('<span class="badge" title="版本：' + vs.map((v) => 'v' + v).join('、') + '">v' + vs[vs.length - 1] + (vs.length > 1 ? ' 等' + vs.length + '个' : '') + '</span>');
  }
  if (typeof g.size_gb === 'number' && g.size_gb > 0) {
    badges.push('<span class="badge">' + g.size_gb.toFixed(1) + ' GB</span>');
  }
  badges.push(statusBadge);

  const ids = (g.title_ids || []).join('  ');
  const launchReason = launchBlockReason(g);
  const buildReason = buildBlockReason(g);
  const stopAct = stopAction(g);

  const launchDisabled = launchReason ? ' disabled title="' + esc(launchReason) + '"' : '';
  const buildDisabled = buildReason ? ' disabled title="' + esc(buildReason) + '"' : '';
  const stopDisabled = stopAct ? '' : ' disabled title="没有可停止的进程"';
  const stopTitle = stopAct === 'build' ? '取消当前构建' : (stopAct === 'launch' ? '停止运行中的游戏' : '');

  return '' +
    '<article class="card" data-folder="' + esc(g.folder) + '">' +
      '<h3 class="card-title">' + esc(g.display_name || g.folder) + '</h3>' +
      '<div class="card-folder" title="' + esc(g.path || g.folder) + '">' + esc(g.folder) + '</div>' +
      (ids ? '<div class="card-ids mono" title="' + esc(ids) + '">' + esc(ids) + '</div>' : '') +
      '<div class="badges">' + badges.join('') + '</div>' +
      '<div class="card-actions">' +
        '<button class="btn primary" data-act="launch"' + launchDisabled + '>▶ 启动</button>' +
        '<button class="btn" data-act="build"' + buildDisabled + '>构建</button>' +
        '<button class="btn danger" data-act="stop"' + stopDisabled + (stopTitle ? ' title="' + esc(stopTitle) + '"' : '') + '>停止</button>' +
      '</div>' +
    '</article>';
}

$('grid').addEventListener('click', (e) => {
  const btn = e.target.closest('button[data-act]');
  if (!btn || btn.disabled) return;
  const card = btn.closest('.card');
  if (!card) return;
  const folder = card.getAttribute('data-folder');
  const act = btn.getAttribute('data-act');
  if (act === 'launch') doLaunch(folder);
  else if (act === 'build') doBuild(folder);
  else if (act === 'stop') doStop(folder);
});

/* ============ 操作：构建 / 启动 / 停止 ============ */

async function doBuild(folder) {
  try {
    await api.build(folder);
    state.build = { building: true, folder };
    resetStream();
    openDrawer(true);
    hideBanner();
    $('drawer-folder').textContent = folder;
    $('drawer-folder').classList.remove('hidden');
    $('prog-title').textContent = '准备构建…';
    $('prog-meta').textContent = '';
    $('prog-say').textContent = '';
    $('prog-fill').classList.remove('indeterminate');
    $('prog-fill').style.width = '0%';
    appendLog('sys', '开始构建：' + folder);
    updateDrawerState();
    renderGames();
  } catch (err) {
    toast(err.message || '构建启动失败', 'error');
    if (err.status === 409) refreshBuildStatus();
  }
}

async function doLaunch(folder) {
  try {
    await api.launch(folder);
    toast('已启动：' + displayNameOf(folder), 'info');
    pollLaunch(); // 立即刷新运行状态
  } catch (err) {
    toast(err.message || '启动失败', 'error');
  }
}

async function doStop(folder) {
  const act = stopAction({ folder });
  try {
    if (act === 'build') {
      await api.buildCancel();
      toast('已请求取消构建', 'warn');
    } else if (act === 'launch') {
      await api.launchStop();
      toast('已请求停止游戏', 'warn');
    }
    pollLaunch();
  } catch (err) {
    toast(err.message || '停止失败', 'error');
  }
}

async function doCancelBuild() {
  try {
    await api.buildCancel();
    toast('已请求取消构建', 'warn');
  } catch (err) {
    toast(err.message || '取消失败', 'error');
  }
}

/* ============ 事件流：进度条 + 日志 ============ */

function resetStream() {
  state.stream = {
    k: 0, n: 0, name: '', step: '',
    frac: null, eta: null, done: null, total: null, unit: '', est: false,
    lastOk: true, lastSummary: '', lastRed: '',
    sawEvents: false, firstT: null, lastSeq: null,
  };
}

function appendLog(cls, text) {
  const log = $('log');
  const line = document.createElement('div');
  line.className = 'log-line ' + cls;
  line.textContent = text;
  log.appendChild(line);
  while (log.childNodes.length > 1200) log.removeChild(log.firstChild);
  if (state.logFollow) {
    log.scrollTop = log.scrollHeight;
  } else {
    $('btn-log-bottom').classList.remove('hidden');
  }
}

function updateProgressUI() {
  const s = state.stream;
  const title = (s.n ? '[' + s.k + '/' + s.n + '] ' : '') + (s.name || (state.build.building ? '构建中…' : '等待构建…'));
  $('prog-title').textContent = title;

  const meta = [];
  if (s.frac != null) meta.push(Math.round(s.frac * 100) + '%');
  const cnt = fmtCount(s.done, s.total, s.unit, s.est);
  if (cnt) meta.push(cnt);
  if (s.eta != null) meta.push('ETA ' + hms(s.eta));
  $('prog-meta').textContent = meta.join(' · ');

  const fill = $('prog-fill');
  if (s.frac != null) {
    fill.classList.remove('indeterminate');
    fill.style.width = Math.max(2, Math.round(s.frac * 100)) + '%';
  } else if (state.build.building) {
    fill.classList.add('indeterminate');
    fill.style.width = '35%';
  } else {
    fill.classList.remove('indeterminate');
    fill.style.width = '0%';
  }

  updateDrawerState();
}

function handleBuildEvent(ev) {
  if (!ev || typeof ev !== 'object') return;
  const s = state.stream;
  // seq 去重:回填、SSE 重连、轮询三路可能重叠,已应用过的直接丢弃
  if (typeof ev.seq === 'number') {
    if (s.lastSeq != null && ev.seq <= s.lastSeq) return;
    s.lastSeq = ev.seq;
  }
  s.sawEvents = true;
  if (s.firstT == null && typeof ev.t === 'number') s.firstT = ev.t;

  switch (ev.ev) {
    case 'stage': {
      s.k = ev.k; s.n = ev.n; s.name = ev.name || ''; s.step = ev.step || '';
      s.frac = null; s.eta = null; s.done = null; s.total = null; s.unit = ''; s.est = false;
      let line = '[' + ev.k + '/' + ev.n + '] ' + (ev.name || '');
      if (ev.step) line += ' · ' + ev.step;
      appendLog('stage', '▶ ' + line);
      updateProgressUI();
      break;
    }
    case 'step': {
      s.k = ev.k; s.step = ev.step || '';
      if (ev.name) s.name = ev.name;
      s.frac = null; s.eta = null; s.done = null; s.total = null;
      appendLog('step', '  └ ' + (ev.step || ''));
      updateProgressUI();
      break;
    }
    case 'progress': {
      if (ev.k != null) s.k = ev.k;
      if (ev.name != null) s.name = ev.name;
      if (ev.step != null) s.step = ev.step;
      s.frac = (ev.frac == null) ? null : ev.frac;
      s.eta = (ev.eta == null) ? null : ev.eta;
      s.done = (ev.done == null) ? null : ev.done;
      s.total = (ev.total == null) ? null : ev.total;
      s.unit = ev.unit || '';
      s.est = !!ev.est;
      updateProgressUI();
      break;
    }
    case 'stage_end': {
      if (ev.k != null) s.k = ev.k;
      const ok = ev.ok !== false;
      if (!ok) s.lastOk = false;
      if (ev.summary) s.lastSummary = ev.summary;
      if (ok) s.frac = 1;
      const mark = ok ? '✓' : '✗';
      let line = mark + ' [' + ev.k + '/' + (s.n || ev.k) + '] ' + (ev.name || '');
      if (ev.elapsed != null) line += '（' + durCN(ev.elapsed) + '）';
      if (ev.summary) line += '：' + ev.summary;
      appendLog(ok ? 'ok' : 'err', line);
      updateProgressUI();
      break;
    }
    case 'say': {
      let msg = String(ev.msg == null ? '' : ev.msg);
      if (msg.indexOf('[RED]') === 0) {
        msg = msg.slice(5).trim();
        s.lastRed = msg;
        s.lastOk = false;
        appendLog('say-red', msg);
        $('prog-say').textContent = msg;
        $('prog-say').style.color = 'var(--error)';
      } else {
        appendLog('', msg);
        $('prog-say').textContent = msg;
        $('prog-say').style.color = '';
      }
      break;
    }
    default:
      appendLog('dim', JSON.stringify(ev));
  }
}

/* ============ 构建事件流（SSE） ============ */

let es = null;

function connectEvents() {
  if (es) { try { es.close(); } catch (e) { /* ignore */ } }
  es = new EventSource('/api/build/events');

  es.onopen = () => {
    if (!state.esOpen && state.stream.sawEvents && state.build.building) {
      appendLog('sys', '事件流已重新连接，回填丢失事件…');
      // 服务端每个 SSE 连接都从当前序号起步、不重放历史:重连后必须主动回填缺口
      refreshBuildStatus(true);
    }
    state.esOpen = true;
  };

  es.onmessage = (e) => {
    let ev;
    try { ev = JSON.parse(e.data); } catch (err) { return; }
    handleBuildEvent(ev);
  };

  es.onerror = () => {
    // EventSource 会自动重连；仅在构建期间给出提示，避免噪音
    if (state.esOpen && state.build.building) {
      appendLog('sys', '事件流连接断开，正在重连…');
    }
    state.esOpen = false;
  };
}

/* 构建结束兜底：SSE 断开 或 status 轮询发现 building=false
   force=true：SSE 重连后按 seq 回填断线期间丢失的事件（已送达的按 seq 跳过） */
async function refreshBuildStatus(force) {
  try {
    const st = await api.buildStatus();
    const wasBuilding = state.build.building;
    state.build = { building: !!st.building, folder: st.folder || null };
    if (st.building) {
      if (st.folder) {
        $('drawer-folder').textContent = st.folder;
        $('drawer-folder').classList.remove('hidden');
      }
      if ((!wasBuilding || force) && Array.isArray(st.events)) {
        if (!wasBuilding) {
          // 刚进入“构建中”：整段重建日志与进度
          resetStream();
          $('log').innerHTML = '';
        }
        // 去重在 handleBuildEvent 里按 seq 做:已见事件跳过,断线缺口补上
        st.events.forEach((ev) => handleBuildEvent(ev));
        if (!wasBuilding) openDrawer(true);
      }
    } else if (wasBuilding) {
      finishBuildUI();
    }
    updateDrawerState();
    renderGames();
  } catch (err) { /* 静默 */ }
}

function finishBuildUI() {
  const s = state.stream;
  $('prog-fill').classList.remove('indeterminate');
  if (s.lastOk) {
    $('prog-fill').style.width = '100%';
    showBanner(true, '构建完成' + (s.lastSummary ? '：' + s.lastSummary : ''));
  } else {
    showBanner(false, '构建失败' + (s.lastRed ? '：' + s.lastRed : (s.lastSummary ? '：' + s.lastSummary : '（详情见日志）')));
  }
  $('prog-say').style.color = '';
  refreshGames();
}

function showBanner(ok, text) {
  const b = $('build-banner');
  b.className = 'banner ' + (ok ? 'ok' : 'fail');
  $('build-banner-text').textContent = text;
  b.classList.remove('hidden');
}

function hideBanner() {
  $('build-banner').classList.add('hidden');
}

/* ============ 抽屉 ============ */

function openDrawer(open) {
  const body = $('drawer-body'), chev = $('drawer-chevron'), tog = $('drawer-toggle');
  body.classList.toggle('hidden', !open);
  chev.textContent = open ? '▼' : '▲';
  tog.setAttribute('aria-expanded', open ? 'true' : 'false');
}

function toggleDrawer() {
  const body = $('drawer-body');
  openDrawer(body.classList.contains('hidden'));
}

function updateDrawerState() {
  const el = $('drawer-state');
  const cancelBtn = $('btn-cancel-build');
  if (state.build.building) {
    el.textContent = '构建中：' + (state.build.folder || '');
    el.className = 'drawer-state building';
    cancelBtn.classList.remove('hidden');
  } else if (state.launch.running) {
    el.textContent = '运行中：' + displayNameOf(state.launch.folder);
    el.className = 'drawer-state running-game';
    cancelBtn.classList.add('hidden');
  } else {
    el.textContent = '';
    el.className = 'drawer-state';
    cancelBtn.classList.add('hidden');
  }
  // 顶栏运行徽章
  const badge = $('run-badge');
  if (state.launch.running) {
    badge.classList.remove('hidden');
    $('run-badge-text').textContent = '运行中 · ' + displayNameOf(state.launch.folder);
  } else {
    badge.classList.add('hidden');
  }
}

/* 日志滚动跟随 */
const logEl = $('log');
logEl.addEventListener('scroll', () => {
  const nearBottom = logEl.scrollTop + logEl.clientHeight >= logEl.scrollHeight - 24;
  if (nearBottom) {
    if (!state.logFollow) { state.logFollow = true; }
    $('btn-log-bottom').classList.add('hidden');
  } else {
    state.logFollow = false;
    $('btn-log-bottom').classList.remove('hidden');
  }
});

$('btn-log-bottom').addEventListener('click', () => {
  state.logFollow = true;
  logEl.scrollTop = logEl.scrollHeight;
  $('btn-log-bottom').classList.add('hidden');
});

$('drawer-toggle').addEventListener('click', toggleDrawer);
$('btn-cancel-build').addEventListener('click', doCancelBuild);
$('build-banner-close').addEventListener('click', hideBanner);

$('btn-load-log').addEventListener('click', async () => {
  const g = state.games.find((x) => x.build);
  const folder = state.build.folder || (state.launch.running && state.launch.folder) || (g && g.folder);
  if (!folder) { toast('没有可查看的构建日志', 'warn'); return; }
  try {
    const text = await api.buildLog(folder);
    openDrawer(true);
    appendLog('sys', '—— 构建日志尾部：' + folder + ' ——');
    String(text).split('\n').forEach((ln) => appendLog('dim', ln));
    appendLog('sys', '——————————————');
  } catch (err) {
    toast(err.message || '读取日志失败', 'error');
  }
});

/* ============ 轮询：运行中的游戏 ============ */

async function pollLaunch() {
  try {
    const st = await api.launchStatus();
    const prev = state.launch;
    state.launch = {
      running: !!st.running,
      folder: st.folder || null,
      tail: Array.isArray(st.tail) ? st.tail : [],
    };
    if (state.launchErrShown) state.launchErrShown = false;
    if (!!st.running !== !!prev.running || st.folder !== prev.folder) {
      updateDrawerState();
      renderGames();
    }
  } catch (err) {
    if (!state.launchErrShown) {
      state.launchErrShown = true;
      toast('无法获取运行状态：' + err.message, 'warn');
    }
  }
}

/* ============ 设置弹层 ============ */

function openSettings() {
  const overlay = $('modal-overlay');
  overlay.classList.remove('hidden');
  loadConfigIntoForm();
  $('cfg-keys').focus();
}

function closeSettings() {
  $('modal-overlay').classList.add('hidden');
}

async function loadConfigIntoForm() {
  try {
    const cfg = await api.getConfig();
    if (cfg && cfg.config_error) {
      toast('配置文件已损坏：' + cfg.config_error + '（保存设置会覆盖原文件）', 'warn');
    }
    applyConfig(cfg);
    fillForm(cfg);
  } catch (err) {
    toast('读取配置失败：' + err.message, 'error');
    fillForm(state.config || { keys: '', library: '', language: '', extra_env: {} });
  }
}

function fillForm(cfg) {
  $('cfg-keys').value = cfg.keys || '';
  $('cfg-library').value = cfg.library || '';
  $('cfg-language').value = cfg.language || '';
  $('cfg-extra-env').value = Object.entries(cfg.extra_env || {})
    .map(([k, v]) => k + '=' + v).join('\n');
}

function parseExtraEnv(text) {
  const out = {};
  for (const raw of String(text || '').split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const i = line.indexOf('=');
    if (i <= 0) continue;
    const k = line.slice(0, i).trim();
    const v = line.slice(i + 1).trim();
    if (k) out[k] = v;
  }
  return out;
}

function applyConfig(cfg) {
  state.config = {
    keys: cfg.keys || '',
    library: cfg.library || '',
    language: cfg.language || '',
    extra_env: cfg.extra_env || {},
  };
}

$('btn-settings').addEventListener('click', openSettings);
$('btn-cancel-settings').addEventListener('click', closeSettings);
$('modal-overlay').addEventListener('click', (e) => {
  if (e.target === $('modal-overlay')) closeSettings();
});

$('settings-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const cfg = {
    keys: $('cfg-keys').value.trim(),
    library: $('cfg-library').value.trim(),
    language: $('cfg-language').value,
    extra_env: parseExtraEnv($('cfg-extra-env').value),
  };
  const btn = $('btn-save-settings');
  btn.disabled = true;
  try {
    const saved = await api.putConfig(cfg);
    applyConfig(saved || cfg);
    closeSettings();
    toast('设置已保存', 'info');
    refreshStatus();
    refreshGames();
  } catch (err) {
    toast(err.message || '保存失败', 'error');
  } finally {
    btn.disabled = false;
  }
});

/* ============ 数据刷新 ============ */

async function refreshStatus() {
  try {
    state.status = await api.status();
    renderStatus();
    renderGames();
  } catch (err) { /* 静默；首次加载失败时 toast 一次由 refreshAll 负责 */ }
}

async function refreshGames() {
  try {
    const data = await api.games();
    state.games = Array.isArray(data.games) ? data.games : [];
    state.names = data.names || {};
    renderGames();
  } catch (err) { /* 静默 */ }
}

async function refreshAll() {
  try {
    state.status = await api.status();
  } catch (err) {
    toast(err.message || '无法连接本地服务', 'error');
  }
  renderStatus();
  try {
    const cfg = await api.getConfig();
    applyConfig(cfg);
  } catch (err) { /* ignore */ }
  await refreshGames();
  await refreshBuildStatus();
  await pollLaunch();
}

$('btn-refresh').addEventListener('click', refreshAll);

/* ============ 启动 ============ */

function init() {
  connectEvents();
  refreshAll();
  setInterval(pollLaunch, 3000);
  // 构建期间的兜底轮询（SSE 之外的保险）
  setInterval(() => {
    if (state.build.building) refreshBuildStatus();
  }, 5000);
}

init();
