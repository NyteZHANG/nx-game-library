#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nxnative 游戏库前端后端(仅 Python 3 标准库)。

扫描多个游戏文件夹(NSP/XCI),对任意游戏发起构建(流式进度 SSE),并在 Mac 上启动已构建的游戏。
仓库只读参考:REPO 下的 scripts/build_ipa_from_nsp.py 与 dm/games/。
"""
import argparse
import collections
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer

BASE = Path(__file__).resolve().parent
STATIC_DIR = BASE / 'static'
# 环境变量 NXFE_CONFIG 覆盖 config.json 路径(测试/多实例用;README 约定)
CONFIG_PATH = Path(os.environ.get('NXFE_CONFIG') or (BASE / 'config.json'))
LOGS_DIR = BASE / 'logs'


def _resolve_repo() -> Path:
    """定位 nxnative 仓库,优先级:
    1. 环境变量 NXFE_REPO;
    2. config.json 可选的 "repo" 键(缺键/损坏一律跳过);
    3. 前端目录同级的 ../nxnative(标准并排克隆布局);
    4. 旧绝对路径兜底——仅本机历史布局;仓库放别处请设 NXFE_REPO 或 config 的 repo 键。"""
    env = (os.environ.get('NXFE_REPO') or '').strip()
    if env:
        return Path(env).expanduser()
    try:
        data = json.loads(CONFIG_PATH.read_text(encoding='utf-8'))
        if isinstance(data, dict):
            repo = data.get('repo')
            if isinstance(repo, str) and repo.strip():
                return Path(repo.strip()).expanduser()
    except (OSError, ValueError):
        pass
    sibling = BASE.resolve().parent / 'nxnative'
    if sibling.is_dir():
        return sibling
    # 兜底:仅本机历史布局(仓库放别处请设 NXFE_REPO 或 config 的 repo 键)
    return Path('/Users/nyte/AIproject/ns模拟/nxnative')


REPO = _resolve_repo()
BUILD_SCRIPT = REPO / 'scripts' / 'build_ipa_from_nsp.py'
GAMES_DIR = REPO / 'dm' / 'games'

DEFAULT_CONFIG = {'keys': '', 'library': '', 'language': '', 'extra_env': {}}

TITLE_RE = re.compile(r'\[([0-9A-Fa-f]{16})\]')
VERSION_RE = re.compile(r'\[v(\d+)\]')
SAFE_NAME_RE = re.compile(r'^[A-Za-z0-9._-]+$')

_BUILD_PY = {'path': None}
_DOTNET_ROOT = {'path': None}


def _dotnet_root():
    """brew formula 的 dotnet 不装到 /usr/local/share/dotnet,apphost 找不到运行时:
    找一个含 shared/Microsoft.NETCore.App 的根,注入构建环境(升级 brew 后 opt 别名仍有效)。"""
    if _DOTNET_ROOT['path'] is not None:
        return _DOTNET_ROOT['path'] or None
    _DOTNET_ROOT['path'] = ''
    cands = []
    for key in ('DOTNET_ROOT', 'DOTNET_ROOT_ARM64'):
        v = (os.environ.get(key) or '').strip()
        if v:
            cands.append(Path(v))
    which = shutil.which('dotnet')
    if which:
        real = Path(which).resolve()
        cands += [real.parent, real.parent.parent / 'libexec', real.parent / 'libexec']
    cands.append(Path('/opt/homebrew/opt/dotnet/libexec'))
    for c in cands:
        try:
            if (c / 'shared' / 'Microsoft.NETCore.App').is_dir():
                _DOTNET_ROOT['path'] = str(c)
                return str(c)
        except OSError:
            continue
    return None


def pick_build_python():
    """构建脚本需要 Python ≥3.12(嵌套引号 f-string):优先 NXFE_PYTHON,再前端 .venv,
    再 PATH 上的 python3.1x / python3,最后才 sys.executable(系统 3.9 会 SyntaxError)。"""
    if _BUILD_PY['path']:
        return _BUILD_PY['path']
    cands = []
    envpy = (os.environ.get('NXFE_PYTHON') or '').strip()
    if envpy:
        cands.append(str(Path(envpy).expanduser()))
    venv = BASE / '.venv' / 'bin' / 'python'
    if venv.is_file():
        cands.append(str(venv))
    for name in ('python3.14', 'python3.13', 'python3.12'):
        p = shutil.which(name)
        if p:
            cands.append(p)
    p = shutil.which('python3')
    if p:
        cands.append(p)
    cands.append(sys.executable)
    for c in cands:
        try:
            r = subprocess.run([c, '--version'], capture_output=True, text=True, timeout=10)
            m = re.search(r'(\d+)\.(\d+)', (r.stdout or '') + (r.stderr or ''))
            if m and (int(m.group(1)), int(m.group(2))) >= (3, 12):
                _BUILD_PY['path'] = c
                return c
        except Exception:
            continue
    _BUILD_PY['path'] = 'python3'  # 回退:构建会以 SyntaxError 失败,原因进事件流
    return 'python3'

MIME = {
    '.html': 'text/html; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.ico': 'image/x-icon',
    '.map': 'application/json',
    '.txt': 'text/plain; charset=utf-8',
}

STATE_LOCK = threading.Lock()
EVENT_COND = threading.Condition()
EVENT_SEQ = 0
EVENTS = collections.deque(maxlen=2000)  # (seq, event dict)

BUILD = {'proc': None, 'folder': None, 'log': None, 'building': False}
LAUNCH = {'proc': None, 'folder': None, 'busy': False}

_TOOLS_CACHE = {'t': 0.0, 'data': None}
_SCAN_CACHE = {'lib': None, 't': 0.0, 'data': None}
SCAN_TTL = 3.0  # scan_games 结果缓存秒数(热路径 /api/launch/status 每 3s 轮询)

CONFIG_ERROR = None  # 最近一次 load_config 的失败原因;None = 正常


# ---------------------------------------------------------------- config

def default_config():
    return {'keys': '', 'library': '', 'language': '', 'extra_env': {}}


def _coerce_config(data):
    out = default_config()
    if not isinstance(data, dict):
        return out
    for key in ('keys', 'library', 'language'):
        v = data.get(key)
        out[key] = v if isinstance(v, str) else (str(v) if v is not None else '')
    extra = data.get('extra_env')
    if isinstance(extra, dict):
        out['extra_env'] = {str(k): str(v) for k, v in extra.items()}
    return out


def load_config():
    global CONFIG_ERROR
    try:
        raw = CONFIG_PATH.read_text(encoding='utf-8')
    except FileNotFoundError:
        CONFIG_ERROR = None
        return default_config()
    except OSError as e:
        CONFIG_ERROR = f'读取失败: {e}'
        return default_config()
    try:
        data = json.loads(raw)
    except ValueError as e:
        CONFIG_ERROR = f'config.json 已损坏 ({e}),已回退默认值'
        return default_config()
    if not isinstance(data, dict):
        CONFIG_ERROR = 'config.json 不是 JSON 对象,已回退默认值'
        return default_config()
    CONFIG_ERROR = None
    return _coerce_config(data)


def save_config(cfg):
    cfg = _coerce_config(cfg)
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return cfg


# ---------------------------------------------------------------- tools / status

def _metal_ok():
    try:
        r = subprocess.run(
            ['xcrun', '-sdk', 'iphoneos', 'metal', '--version'],
            capture_output=True, text=True, timeout=10,
        )
        out = (r.stdout or '') + (r.stderr or '')
        # Xcode 大版本升级后 stub 会残留:此时能 exec 但报 missing Metal Toolchain
        return r.returncode == 0 and 'missing Metal Toolchain' not in out
    except Exception:
        return False


def _xcode_preflight():
    """Xcode 本体是「用户自己装」的重件:只检查、只给指引,绝不代装。
    返回 None=可用,否则返回给用户看的中文指引(组件类的缺失走 _ensure_metal_toolchain 自动修)。"""
    if not shutil.which('xcodebuild'):
        return '未找到 Xcode:请先从 App Store 或 developer.apple.com 安装 Xcode,再重试构建'
    try:
        r = subprocess.run(['xcodebuild', '-version'],
                           capture_output=True, text=True, timeout=15)
    except Exception as e:
        return f'Xcode 不可用({e}):请打开 Xcode 完成首次设置(含组件下载)后重试'
    if r.returncode != 0:
        out = ((r.stdout or '') + (r.stderr or '')).strip()
        if 'license' in out.lower():
            return 'Xcode 许可未接受:请在终端执行 sudo xcodebuild -license accept,再重试构建'
        return f'Xcode 不可用:{out[:200]}'
    return None


def _ensure_metal_toolchain(logf):
    """Metal Toolchain 属于 Xcode 组件(联网更新类):缺失时自动补装(约 839MB)。
    实测资产目录偶发拉取失败(exit 70),故每轮重试 3 次;下载进度转 say 事件,
    app 进度面板与网页控制台都能看到。返回 True=metal 可用。"""
    def say(msg):
        _push_event({'ev': 'say', 'msg': msg})
        try:
            logf.write(msg + '\n')
            logf.flush()
        except Exception:
            pass

    if _metal_ok():
        return True

    def cancelled():
        with STATE_LOCK:
            return bool(BUILD.get('cancel'))

    say('[server] Metal 工具链缺失(Xcode 升级后常见),正在自动补装(约 839MB,视网络需几分钟)…')
    for attempt in range(1, 4):
        if cancelled():
            say('[server] 已取消 Metal 工具链补装')
            return False
        p = None
        try:
            p = subprocess.Popen(
                ['xcodebuild', '-downloadComponent', 'MetalToolchain'],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding='utf-8', errors='replace', bufsize=1,
            )
            last_pct = -20
            tail_lines = []
            for line in p.stdout:
                if cancelled():
                    p.terminate()
                    say('[server] 已取消 Metal 工具链补装')
                    return False
                line = line.rstrip('\n')
                if line.strip():
                    tail_lines = tail_lines[-8:] + [line]
                    try:
                        logf.write(line + '\n')
                        logf.flush()
                    except Exception:
                        pass
                # "Downloading... (42 MB of 838.9 MB downloaded)" → 每 10% 播报一次
                m = re.search(r'\(([\d.]+) (?:MB|kB) of ([\d.]+) MB', line)
                if m:
                    try:
                        pct = int(float(m.group(1)) / float(m.group(2)) * 100)
                    except (ValueError, ZeroDivisionError):
                        pct = -1
                    if pct >= 0 and pct >= last_pct + 10:
                        last_pct = pct
                        say(f'[server] Metal 工具链下载 {pct}%')
            p.wait(timeout=1800)
            if p.returncode == 0 and _metal_ok():
                with STATE_LOCK:
                    _TOOLS_CACHE['t'] = 0  # 让 tools_status 立即刷新
                say('[server] Metal 工具链补装完成,继续构建')
                return True
            say(f'[server] 补装失败(第 {attempt}/3 次,退出码 {p.returncode}): '
                f'{" | ".join(tail_lines[-2:])[-300:]}')
        except subprocess.TimeoutExpired:
            if p is not None and p.poll() is None:
                p.kill()
            say(f'[server] 补装超时(第 {attempt}/3 次)')
        except Exception as e:
            say(f'[server] 补装出错(第 {attempt}/3 次): {e}')
        if attempt < 3:
            time.sleep(5)
    say('[RED] Metal 工具链自动补装 3 次均失败。请保持网络畅通后重试,'
        '或在终端手动执行:xcodebuild -downloadComponent MetalToolchain')
    return False


def tools_status():
    now = time.time()
    if _TOOLS_CACHE['data'] is not None and now - _TOOLS_CACHE['t'] < 30:
        return dict(_TOOLS_CACHE['data'])
    tools = {
        'xcodebuild': bool(shutil.which('xcodebuild')),
        'xcodegen': bool(shutil.which('xcodegen')),
        'dotnet': bool(shutil.which('dotnet')),
        'zstd': bool(shutil.which('zstd')),
        'spirv-cross': bool(shutil.which('spirv-cross')),
        'metal': _metal_ok(),
    }
    _TOOLS_CACHE['t'] = now
    _TOOLS_CACHE['data'] = tools
    return dict(tools)


def api_status(cfg):
    keys = cfg.get('keys') or ''
    library = cfg.get('library') or ''
    return {
        'repo': str(REPO),
        'repo_ok': BUILD_SCRIPT.is_file(),
        'keys': keys or None,
        'keys_ok': bool(keys) and Path(keys).expanduser().is_file(),
        'library': library or None,
        'library_ok': bool(library) and Path(library).expanduser().is_dir(),
        'config_error': CONFIG_ERROR,
        'build_python': pick_build_python(),
        'tools': tools_status(),
    }


# ---------------------------------------------------------------- library scan

def _read_gamepy_names():
    """python3 dm/games/game.py list -> {title_id: name};失败则空表。"""
    try:
        r = subprocess.run(
            [sys.executable, str(GAMES_DIR / 'game.py'), 'list'],
            cwd=str(REPO), capture_output=True, text=True, timeout=15,
            encoding='utf-8', errors='replace',
        )
    except Exception:
        return {}
    names = {}
    if r.returncode != 0:
        return names
    for line in (r.stdout or '').splitlines():
        parts = line.split('\t')
        if len(parts) >= 3 and parts[0].strip():
            names[parts[0].strip().upper()] = parts[2].strip()
    return names


def _parse_tsv_key(tsv_path, key):
    try:
        text = Path(tsv_path).read_text(encoding='utf-8', errors='replace')
    except OSError:
        return None
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        cols = line.split('\t')
        if cols[0].strip() == key and len(cols) >= 2 and cols[1].strip():
            return cols[1].strip()
    return None


def _has_rom_files(path):
    try:
        for p in path.iterdir():
            if p.is_file() and p.suffix.lower() in ('.nsp', '.xci'):
                return True
    except OSError:
        pass
    return False


def _dir_size_gb(path):
    total = 0
    try:
        for p in path.iterdir():
            if p.is_file() and p.suffix.lower() in ('.nsp', '.xci'):
                try:
                    total += p.stat().st_size
                except OSError:
                    pass
    except OSError:
        pass
    return round(total / 2 ** 30, 2)


def _base_title_id(title_ids):
    for t in title_ids:
        if t.lower().endswith('000'):
            return t.upper()
    return title_ids[0].upper() if title_ids else None


def _find_build(game_path):
    """游戏文件夹下最近修改的 *_build 子目录 -> dict 或 None。"""
    best = None
    best_mtime = -1.0
    try:
        for p in game_path.iterdir():
            if not p.is_dir() or not p.name.endswith('_build'):
                continue
            try:
                m = p.stat().st_mtime
            except OSError:
                continue
            if m > best_mtime:
                best, best_mtime = p, m
    except OSError:
        return None
    if best is None:
        return None
    title_id = best.name[: -len('_build')]
    dmhost = best / 'tools' / 'dmhost'
    has_dmhost = dmhost.is_file() and os.access(str(dmhost), os.X_OK)
    # 「可启动」看的是 Mac 宿主要读的库(shader/cache/b-* 或 shader/vk、shader/gl),不是 shader/ios(那是 IPA 打包用的)
    has_msl = _choose_msl(best) is not None
    extract_versions = []
    ex = best / 'extract'
    if ex.is_dir():
        try:
            for d in sorted(ex.iterdir()):
                # 旧布局 RomFS/ 目录,新布局 RomFS.img 镜像,都算解包完成
                if d.is_dir() and ((d / 'RomFS').is_dir() or (d / 'RomFS.img').is_file()):
                    extract_versions.append(d.name)
        except OSError:
            pass
    try:
        last_built = best.stat().st_mtime
    except OSError:
        last_built = None
    return {
        'dir': str(best),
        'title_id': title_id.upper(),
        'has_dmhost': has_dmhost,
        'has_msl': has_msl,
        'extract_versions': extract_versions,
        'last_built': last_built,
    }


def _find_ipa(game_path, title_id, build_info):
    cands = []
    if title_id:
        tsv = GAMES_DIR / title_id.upper() / 'game.tsv'
        ipa_name = _parse_tsv_key(tsv, 'ipa')
        if ipa_name:
            cands.append(game_path / ipa_name)
            cands.append(game_path / Path(ipa_name).name)
    try:
        cands.extend(sorted(game_path.glob('*.ipa'), key=lambda p: p.stat().st_mtime, reverse=True))
    except OSError:
        pass
    if build_info:
        ipa_dir = Path(build_info['dir']) / 'ipa'
        if ipa_dir.is_dir():
            try:
                cands.extend(sorted(ipa_dir.glob('*.ipa'), key=lambda p: p.stat().st_mtime, reverse=True))
            except OSError:
                pass
    seen = set()
    for p in cands:
        try:
            rp = str(p.resolve())
        except OSError:
            continue
        if rp in seen:
            continue
        seen.add(rp)
        if p.is_file():
            return rp
    return None


def scan_games(cfg):
    """扫描游戏库;结果带 3 秒 TTL 缓存(键=library),避免 /api/launch/status 轮询每次都全库扫描 + 跑 game.py。"""
    library = (cfg.get('library') or '').strip()
    now = time.time()
    with STATE_LOCK:
        if (_SCAN_CACHE['data'] is not None
                and _SCAN_CACHE['lib'] == library
                and now - _SCAN_CACHE['t'] < SCAN_TTL):
            return _SCAN_CACHE['data']
    data = _scan_games_uncached(cfg, library)
    with STATE_LOCK:
        _SCAN_CACHE['lib'] = library
        _SCAN_CACHE['t'] = time.time()
        _SCAN_CACHE['data'] = data
    return data


def _scan_games_uncached(cfg, library):
    library = (cfg.get('library') or '').strip()
    if not library:
        return {'games': [], 'names': {}}
    lib = Path(library).expanduser()
    names = _read_gamepy_names()
    games = []
    if not lib.is_dir():
        return {'games': [], 'names': names}

    entries = []
    if _has_rom_files(lib):
        entries.append(('.', lib))
    try:
        for p in sorted(lib.iterdir()):
            if p.is_dir() and not p.name.startswith('.') and _has_rom_files(p):
                entries.append((p.name, p))
    except OSError:
        pass

    for folder, path in entries:
        title_ids = []
        versions = []
        seen_t, seen_v = set(), set()
        try:
            for p in path.iterdir():
                if not p.is_file():
                    continue
                for m in TITLE_RE.finditer(p.name):
                    t = m.group(1).upper()
                    if t not in seen_t:
                        seen_t.add(t)
                        title_ids.append(t)
                for m in VERSION_RE.finditer(p.name):
                    v = int(m.group(1))
                    if v not in seen_v:
                        seen_v.add(v)
                        versions.append(v)
        except OSError:
            pass
        versions.sort()
        base = _base_title_id(title_ids)
        profile = bool(base) and (GAMES_DIR / base / 'game.tsv').is_file()
        display = names.get(base, '') if base else ''
        if not display:
            for t in title_ids:
                if names.get(t):
                    display = names[t]
                    break
        if not display:
            display = lib.name if folder == '.' else folder
        build_info = _find_build(path)
        ipa = _find_ipa(path, base, build_info)
        games.append({
            'folder': folder,
            'path': str(path),
            'title_ids': title_ids,
            'display_name': display,
            'profile': profile,
            'versions': versions,
            'size_gb': _dir_size_gb(path),
            'build': build_info,
            'ipa': ipa,
        })
    return {'games': games, 'names': names}


def _library_path(cfg, folder):
    """folder(扫描结果中的 folder 字段) -> 解析后的绝对路径;非法则抛 ValueError。"""
    library = (cfg.get('library') or '').strip()
    if not library:
        raise ValueError('未配置游戏库')
    lib = Path(library).expanduser().resolve()
    if not lib.is_dir():
        raise ValueError('游戏库目录不存在')
    if folder in ('.', ''):
        return lib
    if not isinstance(folder, str) or not folder or folder.startswith('/') or '..' in folder.split('/'):
        raise ValueError('非法的 folder')
    path = (lib / folder).resolve()
    try:
        path.relative_to(lib)
    except ValueError:
        raise ValueError('路径不在游戏库内') from None
    if not path.is_dir():
        raise ValueError('游戏文件夹不存在')
    return path


def _require_game(cfg, folder):
    """folder 必须匹配已扫描游戏(防路径穿越)。返回 (folder, path, scan_entry)。"""
    data = scan_games(cfg)
    for g in data['games']:
        if g['folder'] == folder:
            return folder, Path(g['path']), g
    raise KeyError(folder)


# ---------------------------------------------------------------- build events

def _push_event(ev):
    """入环形缓冲:补 t(与构建脚本事件一致,前端按 t/seq 去重回填)并盖全局 seq。"""
    global EVENT_SEQ
    with EVENT_COND:
        EVENT_SEQ += 1
        ev = dict(ev)
        ev.setdefault('t', round(time.time(), 3))
        ev['seq'] = EVENT_SEQ
        EVENTS.append((EVENT_SEQ, ev))
        EVENT_COND.notify_all()


def _clear_events():
    with EVENT_COND:
        EVENTS.clear()
        EVENT_COND.notify_all()


def _snapshot_events(limit=None):
    with EVENT_COND:
        items = [e for _, e in EVENTS]
    if limit is not None and len(items) > limit:
        items = items[-limit:]
    return items


def _log_filename(folder):
    """每游戏一份日志:纯 ASCII 且已安全的名字保留可读前缀;其余(如全中文文件夹名)用 utf-8 sha1,
    避免 re.sub 把「马力欧」「塞尔达」都折叠成同一个 build_root.log 而互相覆盖。"""
    safe = re.sub(r'[^A-Za-z0-9._-]+', '_', folder).strip('._')
    if safe and safe == folder:
        return LOGS_DIR / f'build_{safe}.log'
    digest = hashlib.sha1(folder.encode('utf-8')).hexdigest()[:12]
    return LOGS_DIR / f'build_{digest}.log'


def _run_build(cmd, cwd, log_path):
    code = -1
    try:
        LOGS_DIR.mkdir(parents=True, exist_ok=True)
        with open(log_path, 'a', encoding='utf-8', errors='replace') as logf:
            logf.write(f'\n===== {time.strftime("%Y-%m-%d %H:%M:%S")} build start =====\n')
            logf.write(' '.join(cmd) + '\n')
            logf.flush()
            if not _ensure_metal_toolchain(logf):
                code = 1
                logf.write('===== build aborted: Metal Toolchain unavailable =====\n')
                logf.flush()
            else:
                env = dict(os.environ)
                # brew formula 的 dotnet 不写默认位置,nx_extract 的 .NET apphost 找不到运行时
                # (missing_runtime / exit 131):补 DOTNET_ROOT(_ARM64),指向含 shared/ 的根
                root = _dotnet_root()
                if root:
                    env.setdefault('DOTNET_ROOT', root)
                    env.setdefault('DOTNET_ROOT_ARM64', root)
                proc = subprocess.Popen(
                    cmd, cwd=str(cwd), env=env,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, encoding='utf-8', errors='replace', bufsize=1,
                )
                with STATE_LOCK:
                    BUILD['proc'] = proc
                for line in proc.stdout:
                    line = line.rstrip('\n')
                    try:
                        logf.write(line + '\n')
                    except ValueError:
                        pass
                    logf.flush()
                    try:
                        ev = json.loads(line)
                    except ValueError:
                        if line.strip():
                            _push_event({'ev': 'say', 'msg': line})
                        continue
                    if isinstance(ev, dict) and 'ev' in ev:
                        _push_event(ev)
                code = proc.wait()
                try:
                    logf.write(f'===== build end, exit {code} =====\n')
                except ValueError:
                    pass
    except Exception as e:
        _push_event({'ev': 'say', 'msg': f'[server] 构建启动失败: {e}'})
        code = -1
    finally:
        with STATE_LOCK:
            BUILD['proc'] = None
            BUILD['building'] = False
        _push_event({'ev': 'say', 'msg': f'[server] 构建进程结束,退出码 {code}'})


def start_build(cfg, folder):
    _, path, entry = _require_game(cfg, folder)
    # Xcode 本体缺失/未接受许可:立即给指引(用户自己装,不代装)
    xcode_err = _xcode_preflight()
    if xcode_err:
        raise ValueError(xcode_err)
    keys = (cfg.get('keys') or '').strip()
    if not keys:
        raise ValueError('未配置 prod.keys')
    keys_path = Path(keys).expanduser()
    if not keys_path.is_file():
        raise ValueError(f'prod.keys 不存在: {keys_path}')
    with STATE_LOCK:
        # 单例闸门只看 building 标志:proc 要到线程内 Popen 才写入,
        # 若把 proc.poll() 也作为准入条件,构建线程尚未 Popen 的窗口里第二次 POST 会绕过锁并发跑两个构建
        if BUILD.get('building'):
            raise FileExistsError('已有构建在进行')
        BUILD['building'] = True
        BUILD['folder'] = folder
        BUILD['proc'] = None
        BUILD['cancel'] = False
    _clear_events()
    log_path = _log_filename(folder)
    with STATE_LOCK:
        BUILD['log'] = str(log_path)
    cmd = [
        pick_build_python(), str(BUILD_SCRIPT), str(path),
        '-k', str(keys_path),
        '--progress', 'json',
    ]
    lang = (cfg.get('language') or '').strip()
    if lang:
        cmd.extend(['-l', lang])
    t = threading.Thread(target=_run_build, args=(cmd, REPO, log_path), daemon=True)
    t.start()
    return {'ok': True}


def cancel_build():
    with STATE_LOCK:
        BUILD['cancel'] = True  # 预检/补装阶段(proc 尚未生成)也响应取消
        proc = BUILD.get('proc')
    if proc is None or proc.poll() is not None:
        return {'ok': True}
    try:
        proc.terminate()
    except Exception:
        pass

    def killer():
        time.sleep(5)
        if proc.poll() is None:
            try:
                proc.kill()
            except Exception:
                pass

    threading.Thread(target=killer, daemon=True).start()
    return {'ok': True}


# ---------------------------------------------------------------- launch

def _choose_launch_pair(build_dir):
    """(ver, RomFS, patched):同一版本的 extract/<ver>/ 与 patched_<ver>/ 必须配对。

    只认完整配对(绝不用一个版本的 patched 配另一个版本的 RomFS),在配对里取数值最新的
    版本(解析 v<N>;不再看 game.tsv 的 package 键——它可能比上次实际打包的版本旧)。
    游戏文件两种形态皆可(上游 hle_fs.c:DM_ROMFS 目录或镜像文件):旧布局 RomFS/ 目录,
    新布局(2026-11 起)RomFS.img 单镜像文件。
    """
    build_dir = Path(build_dir)
    ex = build_dir / 'extract'
    pairs = []
    try:
        for p in build_dir.iterdir():
            if not p.is_dir() or not p.name.startswith('patched_'):
                continue
            ver = p.name[len('patched_'):]
            if not ver:
                continue
            romfs = ex / ver / 'RomFS'
            if not romfs.is_dir():
                img = ex / ver / 'RomFS.img'
                romfs = img if img.is_file() else None
            if romfs is not None:
                try:
                    m = p.stat().st_mtime
                except OSError:
                    m = 0.0
                pairs.append((ver, romfs, p, m))
    except OSError:
        return None
    if not pairs:
        return None

    def _key(item):
        try:
            num = int(item[0])
        except ValueError:
            num = -1
        return (num, item[3])  # 数值版本优先,同版本按 mtime

    pairs.sort(key=_key)
    ver, romfs, patched, _ = pairs[-1]
    return ver, romfs, patched


def _dmsh_chain():
    """当前源码树的 DMSH_CHAIN(dm/gfx/nvn/dmsh_chain.h);读不到返回 None。"""
    try:
        text = (REPO / 'dm' / 'gfx' / 'nvn' / 'dmsh_chain.h').read_text(encoding='utf-8', errors='replace')
    except OSError:
        return None
    m = re.search(r'#define\s+DMSH_CHAIN\s+"([^"]+)"', text)
    return m.group(1) if m else None


def _msl_kind(build_dir):
    """Mac 宿主要读的着色器库类型: 'nvn' | 'vulkan' | 'gl' | None。

    布局(build 脚本 sh = <build>/shader):
      NVN    → shader/cache/b-<chain>/(宿主自行拼 DM_MSL_DIR/b-<DMSH_CHAIN>)
      Vulkan → shader/vk/            (宿主拼 DM_MSL_DIR/vk/...)
      GL     → shader/gl/            (宿主拼 DM_MSL_DIR/gl/...)
    shader/ios/ 只给 IPA 打包用,Mac 宿主不读。
    """
    sh = Path(build_dir) / 'shader'
    cache = sh / 'cache'
    if cache.is_dir():
        try:
            chain = _dmsh_chain()
            if chain:
                # 宿主只认 b-<当前链版本>:链已变而只有旧 b-* 时按缺库处理(启动也只会黑屏)
                if (cache / f'b-{chain}').is_dir():
                    return 'nvn'
            elif any(p.is_dir() for p in cache.glob('b-*')):
                return 'nvn'
        except OSError:
            pass
    if (sh / 'vk' / 'vk_shaders.tsv').is_file() or (sh / 'vk' / 'vk_shaders.metallib').is_file():
        return 'vulkan'
    if (sh / 'gl' / 'gl_shaders.tsv').is_file() or (sh / 'gl' / 'gl_shaders.metallib').is_file():
        return 'gl'
    return None


def _choose_msl(build_dir):
    """DM_MSL_DIR 该填的目录:一律是宿主拼接段之前的父目录,绝不把 b-* / vk / gl 子目录本身传下去。"""
    kind = _msl_kind(build_dir)
    if kind == 'nvn':
        return Path(build_dir) / 'shader' / 'cache'
    if kind in ('vulkan', 'gl'):
        return Path(build_dir) / 'shader'
    return None


class LaunchError(Exception):
    def __init__(self, message, status=409):
        super().__init__(message)
        self.status = status


def _host_fresh(host, title_id):
    """dmhost 是否与当前源码树匹配:宿主把 DMSH_CHAIN 和游戏 ID 编译进自身,
    引擎 pull 后链已变,旧宿主会去找不存在的 b-<旧链> 目录(启动即 [RED])。"""
    chain = _dmsh_chain()
    try:
        blob = host.read_bytes()
    except OSError:
        return False
    if chain and chain.encode('ascii') not in blob:
        return False
    if title_id and title_id.encode('ascii') not in blob:
        return False
    return True


def _ensure_mac_host(build_dir, title_id):
    """正常 IPA 构建不编 Mac 宿主(heap check / 捕获类才编):缺失**或链/游戏过期**时
    现场 make 再复制进来(make 的 game.stamp 机制保证 GAME/链变化必然重编)。
    首次编译约 1-2 分钟,输出落 <build>/logs/dmhost_build.log。"""
    if not title_id:
        raise LaunchError('尚未构建 (缺 dmhost)')
    host = build_dir / 'tools' / 'dmhost'
    if host.is_file() and os.access(str(host), os.X_OK) and _host_fresh(host, title_id):
        return host
    logf = build_dir / 'logs' / 'dmhost_build.log'
    try:
        logf.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    env = dict(os.environ)
    env['PATH'] = '/opt/homebrew/bin:/usr/local/bin:' + env.get('PATH', '')
    try:
        r = subprocess.run(
            ['make', '-C', str(REPO / 'dm' / 'host'), f'GAME={title_id}', 'dmhost'],
            cwd=str(REPO), env=env, capture_output=True, text=True,
            encoding='utf-8', errors='replace', timeout=600,
        )
    except subprocess.TimeoutExpired as e:
        raise LaunchError('编译 Mac 宿主超时 (10 分钟)', status=500) from e
    except OSError as e:
        raise LaunchError(f'编译 Mac 宿主失败: {e}', status=500) from e
    try:
        logf.write_text((r.stdout or '') + '\n--- stderr ---\n' + (r.stderr or ''),
                        encoding='utf-8', errors='replace')
    except OSError:
        pass
    src = REPO / 'dm' / 'host' / 'dmhost'
    if r.returncode != 0 or not src.is_file():
        tail = [l for l in ((r.stderr or '') + (r.stdout or '')).splitlines() if l.strip()][-8:]
        raise LaunchError('编译 Mac 宿主失败: ' + ' | '.join(tail)[:500], status=500)
    dst = build_dir / 'tools' / 'dmhost'
    try:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        os.chmod(dst, 0o755)
    except OSError as e:
        raise LaunchError(f'复制 dmhost 失败: {e}', status=500) from e
    return dst


def start_launch(cfg, folder):
    _, path, entry = _require_game(cfg, folder)
    build_info = entry.get('build')
    if not build_info:
        raise LaunchError('尚未构建 (缺 dmhost)')
    build_dir = Path(build_info['dir'])
    title_id = build_info.get('title_id') or _base_title_id(entry.get('title_ids') or []) or ''
    host = _ensure_mac_host(build_dir, title_id)  # 内部:新鲜秒回,缺失/链过期现场 make
    pair = _choose_launch_pair(build_dir)
    if not pair:
        raise LaunchError('尚未构建 (缺解包文件或重写模块)')
    ver, romfs_dir, patched = pair  # 同一版本配对的 RomFS 与重写模块

    msl = _choose_msl(build_dir)
    if msl is None:
        raise LaunchError('缺着色器库,请重新构建')

    run_dir = build_dir / 'frontend_run'
    save_dir = build_dir / 'save'
    temp_dir = run_dir / 'temp'
    try:
        run_dir.mkdir(parents=True, exist_ok=True)
        save_dir.mkdir(parents=True, exist_ok=True)
        temp_dir.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        raise LaunchError(f'无法创建运行目录: {e}', status=500) from e

    env = dict(os.environ)
    env.update({
        'DM_ROMFS': str(romfs_dir),
        'DM_SAVE': str(save_dir),
        'DM_TEMP': str(temp_dir),
        'DM_MSL_DIR': str(msl),
        'DM_WINDOW': '1',
        'DM_AUDIO': '1',
    })
    aoc_dir = build_dir / 'aoc'
    if aoc_dir.is_dir():
        env['DM_AOC_DIR'] = str(aoc_dir)  # 构建脚本解出的 DLC:<build>/aoc/<index>/
    if title_id:
        # 构建自己用的 profile 优先(derived/provisional 构建会重新生成 shader_map 到这里),
        # 仓库注册的 profile 只作回退;NVN 游戏没有 map 宿主会直接 MDIE,此时拒绝启动
        shmap = build_dir / 'profile' / title_id.upper() / 'shader_map.tsv'
        if not shmap.is_file():
            shmap = GAMES_DIR / title_id.upper() / 'shader_map.tsv'
        if shmap.is_file():
            env['DM_NVN_SHMAP'] = str(shmap)
        elif _msl_kind(build_dir) == 'nvn':
            raise LaunchError('缺 shader_map.tsv (NVN 游戏必需),请重新构建')
    extra = cfg.get('extra_env') or {}
    for k, v in extra.items():
        env[str(k)] = str(v)
    lang = (cfg.get('language') or '').strip()
    if lang:
        env['DM_LANG'] = lang

    # 在锁内占位(busy)后再 Popen:检查与启动之间不留窗口,并发第二次 POST 会拿到 409
    with STATE_LOCK:
        proc = LAUNCH.get('proc')
        if LAUNCH.get('busy') or (proc is not None and proc.poll() is None):
            raise LaunchError('已有游戏在运行')
        LAUNCH['busy'] = True

    launch_log = run_dir / 'launch.log'
    try:
        with open(launch_log, 'a', encoding='utf-8', errors='replace') as logf:
            logf.write(f'\n===== {time.strftime("%Y-%m-%d %H:%M:%S")} launch {folder} =====\n')
            logf.write(f'{host} {patched}\n')
            logf.flush()
            proc = subprocess.Popen(
                [str(host), str(patched)],
                cwd=str(run_dir),
                stdout=logf, stderr=subprocess.STDOUT,
                env=env,
            )
    except OSError as e:
        with STATE_LOCK:
            LAUNCH['busy'] = False
        raise LaunchError(f'启动失败: {e}', status=500) from e

    with STATE_LOCK:
        LAUNCH['proc'] = proc
        LAUNCH['folder'] = folder
        LAUNCH['busy'] = False
    return {'ok': True}


def stop_launch():
    with STATE_LOCK:
        proc = LAUNCH.get('proc')
    if proc is None or proc.poll() is not None:
        with STATE_LOCK:
            if LAUNCH.get('proc') is proc:
                LAUNCH['proc'] = None
        return {'ok': True}
    try:
        proc.terminate()
    except Exception:
        pass

    def killer():
        time.sleep(5)
        if proc.poll() is None:
            try:
                proc.kill()
            except Exception:
                pass
        try:
            proc.wait(timeout=10)  # 回收子进程,避免浏览器不再轮询时留僵尸
        except Exception:
            pass
        with STATE_LOCK:
            if LAUNCH.get('proc') is proc:
                LAUNCH['proc'] = None

    threading.Thread(target=killer, daemon=True).start()
    return {'ok': True}


def launch_status(cfg):
    with STATE_LOCK:
        proc = LAUNCH.get('proc')
        folder = LAUNCH.get('folder')
    running = bool(proc is not None and proc.poll() is None)
    tail = []
    if folder:
        try:
            _, _, entry = _require_game(cfg, folder)
            build_info = entry.get('build')
            if build_info:
                log = Path(build_info['dir']) / 'frontend_run' / 'launch.log'
                if log.is_file():
                    text = log.read_text(encoding='utf-8', errors='replace')
                    tail = text.splitlines()[-80:]
        except (KeyError, ValueError):
            pass
    return {'running': running, 'folder': folder if running else None, 'tail': tail}


# ---------------------------------------------------------------- http

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'nxnative-frontend/1.0'

    def log_message(self, fmt, *args):
        try:
            LOGS_DIR.mkdir(parents=True, exist_ok=True)
            line = '%s - %s\n' % (time.strftime('%Y-%m-%d %H:%M:%S'), fmt % args)
            with open(LOGS_DIR / 'server.log', 'a', encoding='utf-8', errors='replace') as f:
                f.write(line)
        except Exception:
            pass

    # ---- helpers

    def _send_json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_error_json(self, status, message):
        self._send_json({'error': message}, status=status)

    def _read_json_body(self):
        length = int(self.headers.get('Content-Length') or 0)
        if length <= 0:
            return {}
        if length > 1_000_000:
            raise ValueError('请求体过大')
        raw = self.rfile.read(length)
        if not raw:
            return {}
        data = json.loads(raw.decode('utf-8'))
        if data is None:
            return {}
        if not isinstance(data, dict):
            raise ValueError('请求体必须是 JSON 对象')
        return data

    def _send_bytes(self, data, ctype):
        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _query(self):
        _, _, qs = self.path.partition('?')
        return {k: (v[0] if v else '') for k, v in urllib.parse.parse_qs(qs, keep_blank_values=True).items()}

    # ---- routes

    def do_GET(self):
        try:
            self._route_get()
        except Exception as e:  # noqa: BLE001 - 单请求失败不拖垮线程
            try:
                self._send_error_json(500, f'服务器内部错误: {e}')
            except Exception:
                pass

    def do_PUT(self):
        try:
            self._route_put()
        except Exception as e:  # noqa: BLE001
            try:
                self._send_error_json(500, f'服务器内部错误: {e}')
            except Exception:
                pass

    def do_POST(self):
        try:
            self._route_post()
        except Exception as e:  # noqa: BLE001
            try:
                self._send_error_json(500, f'服务器内部错误: {e}')
            except Exception:
                pass

    def _route_get(self):
        path = self.path.split('?', 1)[0]
        if path == '/' or path == '/index.html':
            return self._serve_static('index.html')
        if path.startswith('/static/'):
            name = path[len('/static/'):]
            return self._serve_static(name)
        if path == '/api/status':
            return self._send_json(api_status(load_config()))
        if path == '/api/config':
            cfg = load_config()
            out = dict(cfg)
            out['config_error'] = CONFIG_ERROR  # 损坏时前端 toast 警告(保存会覆盖原文件)
            return self._send_json(out)
        if path == '/api/games':
            return self._send_json(scan_games(load_config()))
        if path == '/api/build/status':
            with STATE_LOCK:
                # building 标志是唯一闸门(与 start_build 的准入一致);proc 在线程 Popen 后才存在
                building = bool(BUILD.get('building'))
                folder = BUILD.get('folder') if building else None
            return self._send_json({'building': building, 'folder': folder, 'events': _snapshot_events(200)})
        if path == '/api/build/events':
            return self._sse_events()
        if path == '/api/build/log':
            return self._build_log()
        if path == '/api/launch/status':
            return self._send_json(launch_status(load_config()))
        self._send_error_json(404, '未找到该接口')

    def _serve_static(self, name):
        if not name or '/' in name or '\\' in name or '..' in name or not SAFE_NAME_RE.match(name):
            return self._send_error_json(404, '未找到文件')
        fp = (STATIC_DIR / name).resolve()
        try:
            fp.relative_to(STATIC_DIR.resolve())
        except ValueError:
            return self._send_error_json(404, '未找到文件')
        if not fp.is_file():
            return self._send_error_json(404, '未找到文件')
        data = fp.read_bytes()
        ctype = MIME.get(fp.suffix.lower(), 'application/octet-stream')
        return self._send_bytes(data, ctype)

    def _build_log(self):
        q = self._query()
        folder = q.get('folder', '')
        try:
            cfg = load_config()
            _require_game(cfg, folder)
        except (KeyError, ValueError):
            return self._send_error_json(400, 'folder 必须匹配已扫描的游戏')
        log_path = _log_filename(folder)
        if not log_path.is_file():
            return self._send_bytes(b'', 'text/plain; charset=utf-8')
        try:
            text = log_path.read_text(encoding='utf-8', errors='replace')
        except OSError:
            text = ''
        if len(text) > 4000:
            text = text[-4000:]
        return self._send_bytes(text.encode('utf-8'), 'text/plain; charset=utf-8')

    def _sse_events(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(b': ping\n\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            return
        with EVENT_COND:
            # 构建中连接:从 0 回放缓冲里本次构建的事件——堵住「POST 返回到 SSE 建立」
            # 之间预检/补装 say 被漏掉的窗口(缓冲已在 start_build 清空,只含本次构建)
            last = 0 if BUILD.get('building') else EVENT_SEQ
        while True:
            batch = []
            with EVENT_COND:
                if EVENT_SEQ <= last:
                    EVENT_COND.wait(15)
                for seq, ev in EVENTS:
                    if seq > last:
                        batch.append(ev)
                        last = seq
            if not batch:
                try:
                    self.wfile.write(b': ping\n\n')
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, OSError):
                    return
                continue
            try:
                for ev in batch:
                    data = json.dumps(ev, ensure_ascii=False)
                    self.wfile.write(f'data: {data}\n\n'.encode('utf-8'))
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                return

    def _route_put(self):
        path = self.path.split('?', 1)[0]
        if path == '/api/config':
            try:
                body = self._read_json_body()
            except (ValueError, json.JSONDecodeError) as e:
                return self._send_error_json(400, f'请求体不是合法 JSON: {e}')
            cfg = _coerce_config(body)
            try:
                cfg = save_config(cfg)
            except OSError as e:
                return self._send_error_json(500, f'写入配置失败: {e}')
            return self._send_json(cfg)
        self._send_error_json(404, '未找到该接口')

    def _route_post(self):
        path = self.path.split('?', 1)[0]
        if path == '/api/build':
            try:
                body = self._read_json_body()
            except (ValueError, json.JSONDecodeError) as e:
                return self._send_error_json(400, f'请求体不是合法 JSON: {e}')
            folder = body.get('folder')
            if not isinstance(folder, str) or not folder:
                return self._send_error_json(400, '缺少 folder')
            try:
                result = start_build(load_config(), folder)
            except KeyError:
                return self._send_error_json(404, '未找到该游戏文件夹')
            except FileExistsError as e:
                return self._send_error_json(409, str(e))
            except ValueError as e:
                return self._send_error_json(400, str(e))
            return self._send_json(result, status=202)
        if path == '/api/build/cancel':
            return self._send_json(cancel_build())
        if path == '/api/launch':
            try:
                body = self._read_json_body()
            except (ValueError, json.JSONDecodeError) as e:
                return self._send_error_json(400, f'请求体不是合法 JSON: {e}')
            folder = body.get('folder')
            if not isinstance(folder, str) or not folder:
                return self._send_error_json(400, '缺少 folder')
            try:
                result = start_launch(load_config(), folder)
            except KeyError:
                return self._send_error_json(404, '未找到该游戏文件夹')
            except ValueError as e:
                return self._send_error_json(400, str(e))
            except LaunchError as e:
                return self._send_error_json(e.status, str(e))
            return self._send_json(result)
        if path == '/api/launch/stop':
            return self._send_json(stop_launch())
        self._send_error_json(404, '未找到该接口')


class FrontendServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        """跳过 HTTPServer.server_bind 里的 socket.getfqdn():本机反向 DNS 解析
        实测卡 35 秒(启动慢/smoke 超时的根因),纯回环服务不需要 FQDN。"""
        TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


def main(argv=None):
    parser = argparse.ArgumentParser(description='nxnative 游戏库前端后端')
    env_port = os.environ.get('PORT')
    default_port = 8765
    if env_port:
        try:
            default_port = int(env_port)
        except ValueError:
            pass
    parser.add_argument('--port', type=int, default=default_port, help='监听端口(默认 8765,可用环境变量 PORT 覆盖)')
    parser.add_argument('--no-open', action='store_true', help='启动后不自动打开浏览器')
    args = parser.parse_args(argv)

    if not CONFIG_PATH.is_file():
        save_config(default_config())

    LOGS_DIR.mkdir(parents=True, exist_ok=True)

    server = FrontendServer(('127.0.0.1', args.port), Handler)
    url = f'http://127.0.0.1:{args.port}/'
    print(f'前端后端已启动: {url}', flush=True)
    if not args.no_open:
        threading.Timer(0.3, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n正在退出…', flush=True)
    finally:
        with STATE_LOCK:
            for key in ('proc',):
                p = BUILD.get(key)
                if p is not None and p.poll() is None:
                    try:
                        p.terminate()
                    except Exception:
                        pass
                p = LAUNCH.get(key)
                if p is not None and p.poll() is None:
                    try:
                        p.terminate()
                    except Exception:
                        pass
        server.server_close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
