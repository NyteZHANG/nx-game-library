import SwiftUI
import AppKit
import CryptoKit
import Network
import UniformTypeIdentifiers

// MARK: - Apple 设计系统色板(依据 awesome-design-md/design-md/apple/DESIGN.md)
// 全部为**动态色**:亮暗随系统自动切换(light = apple/DESIGN.md 的 parchment 体系,dark = 暗面镜像)。
// 交互一律 Action Blue(#0066cc 亮 / #2997ff 暗),全系统唯一强调色;
// 阴影全系统只有一处——产品图(游戏封面)之下。

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
    /// 随外观解析的动态色
    private init(light: UInt32, dark: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { c in
            let isDark = c.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            let base = NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
            return base.withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        }))
    }
    /// 画布:parchment #F5F5F7 ↔ ink #1D1D1F
    static let nxCanvas = Color(light: 0xF5F5F7, dark: 0x1D1D1F)
    /// 卡面:white ↔ #272729
    static let nxTile = Color(light: 0xFFFFFF, dark: 0x272729)
    /// 唯一交互色(Action Blue ↔ Sky Link Blue)
    static let nxAccent = Color(light: 0x0066CC, dark: 0x2997FF)
    /// 主文字:ink ↔ white
    static let nxText = Color(light: 0x1D1D1F, dark: 0xFFFFFF)
    /// 次级文字
    static let nxMuted = Color(light: 0x6E6E73, dark: 0xCCCCCC)
    /// 三级文字
    static let nxDim = Color(light: 0x86868B, dark: 0x7A7A7A)
    /// 发丝线:黑 8% ↔ 白 8%
    static let nxHairline = Color(light: 0x000000, dark: 0xFFFFFF, darkAlpha: 0.08, lightAlpha: 0.08)
    /// 圆钮/芯片底
    static let nxChip = Color(light: 0x000000, dark: 0xFFFFFF, darkAlpha: 0.10, lightAlpha: 0.06)
    /// 键帽底
    static let nxKeycap = Color(light: 0x000000, dark: 0xFFFFFF, darkAlpha: 0.12, lightAlpha: 0.08)
    /// 封面占位底
    static let nxPlaceholder = Color(light: 0xE8E8ED, dark: 0x3A3A3C)
}

// MARK: - 按下微交互(全系统统一 scale(0.95))

struct NXPressStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 主操作:蓝色胶囊(button-primary)
struct NXPrimaryLabel: View {
    let title: String
    var systemImage: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let s = systemImage { Image(systemName: s).font(.system(size: 12, weight: .semibold)) }
            Text(title).font(.system(size: 14, weight: .semibold)).tracking(-0.224)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color.nxAccent))
    }
}

/// 次操作:幽灵胶囊(1px 蓝描边 + 蓝字)
struct NXGhostLabel: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 14)).tracking(-0.224)
            .foregroundColor(.nxAccent)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Capsule().stroke(Color.nxAccent, lineWidth: 1)
            )
    }
}

// MARK: - 模型(逻辑与上一版一致)

final class LibraryModel: ObservableObject {
    @Published var games: [Game] = []
    @Published var cfg: AppConfig
    @Published var selectedID: String?
    @Published var runningFolder: String?
    /// 现在时刻(每 2s 拨一次,驱动"本次游玩"实时计时)
    @Published var now = Date()
    @Published var launchingFolder: String?
    @Published var alertMessage: String?
    @Published var showSettings = false
    @Published var showEditProfile = false
    @Published var importing = false
    /// 构建中(驱动卡片转圈与底栏状态)
    @Published var buildingFolder: String?
    /// 构建进度面板数据(nil = 无构建)
    @Published var buildProgress: BuildProgress?

    struct BuildProgress {
        var folder: String
        var title: String
        var k = 0, n = 0
        var stage = ""
        var step = ""
        var frac: Double? = nil
        var eta: String = ""
        var say: String = ""
        var errSay: String = ""   // 真实报错留底([RED] 等),失败时展示
        var finished = false
        var ok = false
        var summary = ""
    }

    private var sseTask: Task<Void, Never>?

    private var timer: Timer?

    init() {
        cfg = Config.load()
        refresh()
        selectedID = games.first(where: { $0.playable })?.id ?? games.first?.id
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let running = Launcher.shared.runningFolder
            if self.runningFolder != nil && running == nil {
                self.refresh() // 游戏刚退出:时长已入账,重扫拿新数字
            }
            self.runningFolder = running
            self.now = Date()
        }
    }

    var selectedGame: Game? { games.first { $0.id == selectedID } }

    /// 卡片显示的累计时长:运行中的游戏叠上本局已玩时间
    func livePlaytime(_ g: Game) -> Double {
        if runningFolder == g.folder, let s = Launcher.shared.sessionStart {
            return g.playtimeSeconds + now.timeIntervalSince(s)
        }
        return g.playtimeSeconds
    }

    /// 头像图片(文件不存在/未设置 → nil,界面回退占位)
    var profileAvatarImage: NSImage? {
        guard let url = Config.avatarURL(filename: cfg.profileAvatar) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// 保存编辑资料;返回中文错误信息(nil = 成功)
    @discardableResult
    func saveProfile(name: String, currentAvatar: String, pendingSource: URL?) -> String? {
        var newAvatar = currentAvatar
        if let src = pendingSource {
            do {
                newAvatar = try Config.importAvatar(from: src)
            } catch {
                return "头像导入失败(无法拷入应用数据目录):\(error.localizedDescription)"
            }
        }
        let oldAvatar = cfg.profileAvatar
        var c = cfg
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = "玩家" }
        if trimmed.count > 12 { trimmed = String(trimmed.prefix(12)) }
        c.profileName = trimmed
        c.profileAvatar = newAvatar
        cfg = c
        Config.save(cfg)
        if oldAvatar != newAvatar && !oldAvatar.isEmpty {
            Config.deleteAvatar(filename: oldAvatar)
        }
        return nil
    }

    func refresh() {
        games = GameScanner.scan(cfg: cfg)
        if let sel = selectedID, !games.contains(where: { $0.id == sel }) {
            selectedID = games.first?.id
        }
        runningFolder = Launcher.shared.runningFolder
    }

    func moveSelection(_ direction: Int) {
        guard !games.isEmpty else { return }
        let idx = games.firstIndex { $0.id == selectedID } ?? 0
        let next = max(0, min(games.count - 1, idx + direction))
        withAnimation(.easeOut(duration: 0.15)) { selectedID = games[next].id }
    }

    /// 单击=选中,再点/回车=启动
    func activate(_ game: Game) {
        if selectedID == game.id {
            launch(game)
        } else {
            withAnimation(.easeOut(duration: 0.15)) { selectedID = game.id }
        }
    }

    func launch(_ game: Game) {
        guard game.playable else {
            // 未构建/引擎更新后失效 → 不再干提示,直接开始构建(建完自动开玩)
            startBuild(game)
            return
        }
        launchingFolder = game.folder
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                _ = try Launcher.shared.launch(game: game, cfg: self.cfg, wait: false)
                DispatchQueue.main.async {
                    self.launchingFolder = nil
                    self.runningFolder = game.folder
                }
            } catch {
                DispatchQueue.main.async {
                    self.launchingFolder = nil
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func stop() { Launcher.shared.stop() }

    func saveSettings() {
        Config.save(cfg)
        refresh()
    }

    // MARK: - 构建(app 内完成,不跳浏览器)

    /// 构建入口:确保本地 server 派生 → POST /api/build → 订阅 SSE 进度
    func startBuild(_ game: Game) {
        guard buildingFolder == nil else {
            alertMessage = "已有构建在进行(«\(buildProgress?.title ?? "")»)"
            return
        }
        guard !cfg.library.isEmpty else {
            alertMessage = "先在设置里配置游戏库路径"
            return
        }
        buildingFolder = game.folder
        buildProgress = BuildProgress(folder: game.folder, title: game.displayName)
        ensureServer { [weak self] ok in
            guard let self else { return }
            guard ok else {
                DispatchQueue.main.async {
                    self.buildingFolder = nil
                    self.buildProgress = nil
                    self.alertMessage = "无法启动本地构建服务(检查前端目录与 Python 环境)"
                }
                return
            }
            self.postBuild(folder: game.folder)
        }
    }

    private func postBuild(folder: String) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8765/api/build")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["folder": folder])
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            if let err {
                self.failBuild("提交构建失败:\(err.localizedDescription)")
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 || code == 202 {
                self.subscribeBuildEvents()
                return
            }
            // server 的业务错误(如未配置 prod.keys、已有构建)在 body 的 error 字段
            var msg = "构建服务拒绝(HTTP \(code))"
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let e = obj["error"] as? String {
                msg = e
            }
            self.failBuild(msg)
        }.resume()
    }

    /// SSE:/api/build/events —— 与网页前端同一事件流
    private func subscribeBuildEvents() {
        sseTask?.cancel()
        sseTask = Task { [weak self] in
            guard let self else { return }
            var req = URLRequest(url: URL(string: "http://127.0.0.1:8765/api/build/events")!)
            req.timeoutInterval = 60 * 60
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    self.failBuild("进度流连接失败(HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))")
                    return
                }
                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    self.handleBuildEvent(String(line.dropFirst(6)))
                }
            } catch is CancellationError {
                return
            } catch {
                if self.buildingFolder != nil {
                    self.failBuild("进度流中断:\(error.localizedDescription)")
                }
            }
        }
    }

    private func handleBuildEvent(_ json: String) {
        guard let data = json.data(using: .utf8),
              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = ev["ev"] as? String ?? ""
        DispatchQueue.main.async {
            guard var bp = self.buildProgress else { return }
            switch type {
            case "stage":
                bp.k = ev["k"] as? Int ?? bp.k
                bp.n = ev["n"] as? Int ?? bp.n
                bp.stage = ev["name"] as? String ?? bp.stage
                bp.step = ev["step"] as? String ?? ""
                bp.frac = nil
                bp.eta = ""
            case "progress":
                if let f = ev["frac"] as? NSNumber { bp.frac = f.doubleValue }
                if let s = ev["step"] as? String, !s.isEmpty { bp.step = s }
                bp.eta = Self.fmtETA(ev["eta"])
            case "step":
                bp.step = ev["step"] as? String ?? bp.step
            case "say":
                let msg = ev["msg"] as? String ?? ""
                if !msg.isEmpty { bp.say = msg }
                // 真实报错留底:失败时拼进摘要,避免面板只剩「退出码 1」
                if msg.contains("[RED]") || msg.contains("构建启动失败") {
                    bp.errSay = msg
                }
                // 构建收尾:server 会推「构建进程结束,退出码 N」
                if let r = msg.range(of: "构建进程结束,退出码 ") {
                    let tail = msg[r.upperBound...]
                    let code = tail.prefix(while: { $0.isNumber })
                    if bp.finished && !bp.ok {
                        // 用户已取消或前面已判定失败:保留原摘要,不覆盖
                    } else {
                        bp.finished = true
                        bp.ok = (code == "0")
                        if bp.ok {
                            bp.summary = "构建完成,正在启动游戏…"
                        } else {
                            bp.summary = "构建失败(退出码 \(code.isEmpty ? "?" : String(code)))"
                            if !bp.errSay.isEmpty { bp.summary += "\n" + bp.errSay }
                        }
                    }
                }
            case "stage_end":
                if ev["ok"] as? Bool == false {
                    let s = (ev["summary"] as? String).map { "✗ \($0)" } ?? bp.say
                    bp.say = s
                    bp.errSay = s
                }
            default:
                break
            }
            self.buildProgress = bp
            if bp.finished { self.finishBuild(ok: bp.ok) }
        }
    }

    private static func fmtETA(_ v: Any?) -> String {
        if let n = v as? NSNumber {
            let s = n.intValue
            return s > 0 ? (s >= 60 ? "约 \(s / 60) 分 \(s % 60) 秒" : "约 \(s) 秒") : ""
        }
        if let s = v as? String, !s.isEmpty, s != "<null>" { return "约 \(s)" }
        return ""
    }

    /// 构建进程结束:清理现场;成功则刷新扫描并自动启动该游戏
    private func finishBuild(ok: Bool) {
        sseTask?.cancel(); sseTask = nil
        let folder = buildProgress?.folder
        buildingFolder = nil
        refresh()
        guard ok, let f = folder, let g = games.first(where: { $0.folder == f }) else { return }
        if g.playable {
            launch(g)   // 建完直接开玩(用户按 ▶ 的原始意图)
        } else {
            var bp = buildProgress
            bp?.summary = "构建完成但未达可启动状态,请查看日志"
            bp?.ok = false
            buildProgress = bp
        }
    }

    private func failBuild(_ message: String) {
        sseTask?.cancel(); sseTask = nil
        buildingFolder = nil
        var bp = buildProgress
        bp?.finished = true
        bp?.ok = false
        bp?.summary = message
        buildProgress = bp
        alertMessage = message
    }

    /// 取消构建(server 会 SIGTERM 构建进程)
    func cancelBuild() {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8765/api/build/cancel")!)
        req.httpMethod = "POST"
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.failBuild("已取消构建")
            }
        }.resume()
    }

    /// 关闭进度面板(构建状态已结束或用户收起)
    func dismissBuildPanel() {
        buildProgress = nil
    }

    // MARK: - 导入(NSP/XCI → 游戏库)

    /// 入口:顶栏导入按钮(选择器)与窗口拖放共用
    func importURLs(_ urls: [URL]) {
        guard !importing else { alertMessage = "正在导入,请稍候"; return }
        guard !cfg.library.isEmpty else { alertMessage = "先在设置里配置游戏库路径"; return }
        importing = true
        let cfgCopy = cfg
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let summary = Self.performImport(urls: urls, cfg: cfgCopy)
            DispatchQueue.main.async {
                self?.importing = false
                self?.alertMessage = summary
                self?.refresh()
            }
        }
    }

    /// 「导入」按钮:选 NSP/XCI 文件(可多选)或包含它们的文件夹
    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "nsp"),
                                     UTType(filenameExtension: "xci")].compactMap { $0 }
        panel.message = "选择游戏 NSP/XCI 文件,或包含它们的文件夹"
        panel.prompt = "导入"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importURLs(panel.urls)
    }

    /// 实际导入(后台线程):收集 → 解析 title ID 分类(本体/更新/DLC)→ 按游戏分组 → 复制 → 汇总
    static func performImport(urls: [URL], cfg: AppConfig) -> String {
        let lib = (cfg.library as NSString).expandingTildeInPath
        var isLibDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: lib, isDirectory: &isLibDir), isLibDir.boolValue else {
            return "游戏库目录不存在:\(lib)"
        }
        let fm = FileManager.default

        // 1) 收集 nsp/xci(文件直收;文件夹递归收集,跳过隐藏项)
        var roms: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let en = fm.enumerator(at: u, includingPropertiesForKeys: nil) {
                    for case let f as URL in en
                    where !f.lastPathComponent.hasPrefix(".") {
                        let ext = f.pathExtension.lowercased()
                        if ext == "nsp" || ext == "xci" { roms.append(f) }
                    }
                }
            } else {
                let ext = u.pathExtension.lowercased()
                if ext == "nsp" || ext == "xci" { roms.append(u) }
            }
        }
        guard !roms.isEmpty else { return "所选内容里没有 NSP/XCI 文件" }

        // 2) 文件名解析: [16位titleID] → 尾号 8000=更新 / 0001=DLC / 其余000结尾=本体
        struct Item { let url: URL; let kind: String; let titleID: String }
        var items: [Item] = []
        var unknown: [String] = []
        for f in roms {
            let name = f.lastPathComponent as NSString
            let full = NSRange(location: 0, length: name.length)
            guard let m = GameScanner.titleRE.firstMatch(in: f.lastPathComponent, range: full) else {
                unknown.append(f.lastPathComponent); continue
            }
            let raw = (name.substring(with: m.range(at: 1))).uppercased()
            let kind: String
            if raw.hasSuffix("8000") { kind = "update" }
            else if raw.hasSuffix("0001") { kind = "dlc" }
            else if raw.hasSuffix("000") { kind = "base" }
            else { unknown.append(f.lastPathComponent); continue }
            items.append(Item(url: f, kind: kind, titleID: raw))
        }
        guard !items.isEmpty else {
            let hint = "文件名需含 [16位title ID],如 DARK SOULS [01004AB00A260000][v0].nsp"
            return "无法识别任何文件。\n\(hint)" +
                   (unknown.isEmpty ? "" : "\n例如:" + unknown.prefix(2).joined(separator: "、"))
        }

        // 3) 按游戏分组(本体 title ID = 去掉尾 4 位)
        var groups: [String: [Item]] = [:]
        for it in items { groups[String(it.titleID.dropLast(4)), default: []].append(it) }
        let names = GameScanner.readProfileNames(repo: URL(fileURLWithPath: cfg.repo))

        var report: [String] = []
        for (base, list) in groups.sorted(by: { $0.key < $1.key }) {
            let fromName = list.first { $0.kind == "base" }?.url.lastPathComponent ?? base
            var safe = (names[base] ?? cleanImportName(from: fromName))
                .replacingOccurrences(of: "/", with: "-")
            safe = String(safe.prefix(40)).trimmingCharacters(in: .whitespaces)
            if safe.isEmpty { safe = base }
            let dest = URL(fileURLWithPath: lib).appendingPathComponent(safe, isDirectory: true)
            do {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            } catch {
                report.append("《\(safe)》创建文件夹失败:\(error.localizedDescription)")
                continue
            }
            var b = 0, u = 0, d = 0, same = 0
            for it in list {
                let target = dest.appendingPathComponent(it.url.lastPathComponent)
                if fm.fileExists(atPath: target.path) {
                    let a = (try? fm.attributesOfItem(atPath: target.path))?[.size] as? Int
                    let s = (try? fm.attributesOfItem(atPath: it.url.path))?[.size] as? Int
                    if a != nil && a == s { same += 1; continue }
                    try? fm.removeItem(at: target)
                }
                do {
                    try fm.copyItem(at: it.url, to: target)
                    switch it.kind {
                    case "base": b += 1
                    case "update": u += 1
                    default: d += 1
                    }
                } catch {
                    report.append("\(it.url.lastPathComponent) 复制失败:\(error.localizedDescription)")
                }
            }
            var line = "《\(safe)》→ 游戏库/\(safe)  本体×\(b) 更新×\(u) DLC×\(d)"
            if same > 0 { line += ",同文件跳过×\(same)" }
            report.append(line)
        }
        var msg = "导入完成:\n" + report.joined(separator: "\n")
        if !unknown.isEmpty {
            msg += "\n无法识别(文件名需含 [title ID]):" + unknown.prefix(3).joined(separator: "、")
            if unknown.count > 3 { msg += " 等共\(unknown.count)个" }
        }
        msg += "\n\n新游戏为「未构建」状态,点「构建新游戏」开始打包。"
        return msg
    }

    /// 文件夹名兜底:去掉扩展名与 [title ID]/[vN]/[UPD] 标签
    private static func cleanImportName(from filename: String) -> String {
        var s = filename
        for ext in ["nsp", "xci"] where s.lowercased().hasSuffix(".\(ext)") {
            s = String(s.dropLast(ext.count + 1))
        }
        s = s.replacingOccurrences(of: #"\s*\[[0-9A-Fa-f]{16}\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\[v\d+\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\[UPD\]"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 确保本地构建 server 在跑:端口已通直接用;否则拉起(venv 优先),轮询端口最多 10 秒
    func ensureServer(_ done: @escaping (Bool) -> Void) {
        isPortOpen(port: 8765) { [weak self] open in
            guard let self else { done(false); return }
            if open { done(true); return }
            let venvPy = URL(fileURLWithPath: self.cfg.frontend)
                .appendingPathComponent(".venv/bin/python")
            let py = FileManager.default.isExecutableFile(atPath: venvPy.path)
                ? venvPy.path : "python3"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: py)
            p.arguments = ["server.py", "--no-open"]
            p.currentDirectoryURL = URL(fileURLWithPath: self.cfg.frontend)
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            // 轮询端口
            var tries = 0
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { t in
                tries += 1
                self.isPortOpen(port: 8765) { up in
                    if up || tries >= 25 {
                        t.invalidate()
                        done(up)
                    }
                }
            }
        }
    }

    /// 打开本次构建的完整日志(网页控制台的唯一独有价值,已整合进 app)
    func openBuildLog() {
        guard let folder = buildProgress?.folder else { return }
        let name = Self.buildLogName(folder: folder)
        let logsDir = URL(fileURLWithPath: cfg.frontend).appendingPathComponent("logs")
        let file = logsDir.appendingPathComponent(name)
        // 日志不存在(如从未构建过)则退回打开日志目录
        NSWorkspace.shared.open(
            FileManager.default.fileExists(atPath: file.path) ? file : logsDir)
    }

    /// 与 server.py `_log_filename` 逐字一致:ASCII 安全名保留,其余(如全中文文件夹名)用 utf-8 sha1 前 12 位
    static func buildLogName(folder: String) -> String {
        let safe = folder
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        if !safe.isEmpty && safe == folder { return "build_\(safe).log" }
        let hex = Insecure.SHA1.hash(data: Data(folder.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "build_" + hex.prefix(12) + ".log"
    }

    private func isPortOpen(port: UInt16, completion: @escaping (Bool) -> Void) {
        let conn = NWConnection(host: NWEndpoint.Host("127.0.0.1"),
                                port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let done = { (ok: Bool) in conn.cancel(); completion(ok) }
        conn.stateUpdateHandler = { s in
            switch s {
            case .ready: done(true)
            case .failed, .cancelled: done(false)
            default: break
            }
        }
        conn.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { done(false) }
    }
}

// MARK: - 组件

/// 圆形图标按钮(button-icon-circular:白 10% 芯片,44pt 触达,按下缩 0.95)
struct NXCircleButton: View {
    let system: String
    var help: String = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.nxMuted)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
                .background(Circle().fill(Color.nxChip))
        }
        .buttonStyle(NXPressStyle())
        .help(help)
    }
}

/// 按键提示(安静的 12px 辅助文字 + 平片键帽)
struct NXKeyHint: View {
    let key: String
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.nxMuted)
                .frame(minWidth: 17, minHeight: 17)
                .background(Circle().fill(Color.nxKeycap))
            Text(text)
                .font(.system(size: 12)).tracking(-0.12)
                .foregroundColor(.nxDim)
        }
    }
}

/// 游戏卡(store-utility-card 暗面版:18px 圆角 + 发丝描边;
/// 封面是"产品图"——全系统唯一允许的投影就在这里)
struct GameTile: View {
    let game: Game
    let selected: Bool
    let running: Bool
    let launching: Bool
    let playtimeText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.nxPlaceholder)
                if let icon = game.iconPath, let img = NSImage(contentsOfFile: icon) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.nxDim)
                }
                if launching {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.black.opacity(0.5))
                        ProgressView().tint(.white)
                    }
                }
            }
            .frame(width: 172, height: 172)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) {
                if running {
                    Circle()
                        .fill(Color.green) // 语义状态色(同 macOS 指示灯),非品牌强调色
                        .frame(width: 9, height: 9)
                        .padding(7)
                        .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1).padding(7))
                }
            }
            // 系统唯一投影:产品图落于表面
            .shadow(color: .black.opacity(0.22), radius: 15, x: 1.5, y: 2.5)

            Text(game.displayName)
                .font(.system(size: 14, weight: .semibold)).tracking(-0.224)
                .foregroundColor(.nxText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 172, alignment: .leading)
            HStack(spacing: 8) {
                if !playtimeText.isEmpty {
                    Text(playtimeText)
                        .font(.system(size: 12)).tracking(-0.12)
                        .foregroundColor(.nxDim)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 172)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.nxTile)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(selected ? Color.nxAccent : Color.nxHairline,
                        lineWidth: selected ? 2 : 1)
        )
        .scaleEffect(selected ? 1.03 : 1.0)
    }
}

// MARK: - 构建进度面板(悬浮卡,app 内完成构建)

struct BuildProgressPanel: View {
    @EnvironmentObject var model: LibraryModel

    var body: some View {
        if let bp = model.buildProgress {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if !bp.finished {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: bp.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(bp.ok ? .nxAccent : .red)
                    }
                    Text(bp.finished ? "《\(bp.title)》" : "正在构建《\(bp.title)》")
                        .font(.system(size: 13, weight: .semibold)).tracking(-0.224)
                        .foregroundColor(.nxText)
                        .lineLimit(1)
                    Spacer()
                }

                if !bp.finished || bp.frac != nil {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: bp.frac)
                            .tint(.nxAccent)
                        HStack {
                            if bp.n > 0 {
                                Text("\(bp.k)/\(bp.n) · \(bp.stage)")
                                    .font(.system(size: 11)).tracking(-0.12)
                                    .foregroundColor(.nxMuted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if !bp.eta.isEmpty {
                                Text(bp.eta)
                                    .font(.system(size: 11)).tracking(-0.12)
                                    .foregroundColor(.nxDim)
                            }
                        }
                        if !bp.step.isEmpty {
                            Text(bp.step)
                                .font(.system(size: 11)).tracking(-0.12)
                                .foregroundColor(.nxDim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                if !bp.say.isEmpty {
                    Text(bp.say)
                        .font(.system(size: 11, design: .monospaced)).tracking(-0.12)
                        .foregroundColor(.nxDim)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                if !bp.summary.isEmpty {
                    Text(bp.summary)
                        .font(.system(size: 11, weight: .semibold)).tracking(-0.12)
                        .foregroundColor(bp.ok ? .nxAccent : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    if !bp.finished {
                        Button { model.cancelBuild() } label: {
                            Text("取消构建")
                                .font(.system(size: 12)).tracking(-0.12)
                                .foregroundColor(.nxMuted)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.nxChip))
                        }
                        .buttonStyle(NXPressStyle())
                    } else {
                        Button { model.dismissBuildPanel() } label: {
                            Text("关闭")
                                .font(.system(size: 12, weight: .semibold)).tracking(-0.12)
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.nxAccent))
                        }
                        .buttonStyle(NXPressStyle())
                    }
                    // 完整构建日志(原网页控制台的独有价值)
                    Button { model.openBuildLog() } label: {
                        Text("日志")
                            .font(.system(size: 12)).tracking(-0.12)
                            .foregroundColor(.nxMuted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.nxChip))
                    }
                    .buttonStyle(NXPressStyle())
                    .help("打开完整构建日志")
                    Spacer()
                }
            }
            .padding(16)
            .frame(width: 440)
            .background(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.nxHairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 8)
            .padding(20)
        }
    }
}

// MARK: - 主界面

struct LibraryView: View {
    @EnvironmentObject var model: LibraryModel
    @FocusState private var focusedID: String?
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { geo in
                if model.games.isEmpty {
                    emptyState
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 24) {
                            ForEach(model.games) { g in
                                Button {
                                    model.activate(g)
                                } label: {
                                    GameTile(game: g,
                                             selected: model.selectedID == g.id,
                                             running: model.runningFolder == g.folder,
                                             launching: model.launchingFolder == g.folder
                                                 || model.buildingFolder == g.folder,
                                             playtimeText: PlaytimeStore.format(model.livePlaytime(g)))
                                }
                                .buttonStyle(NXPressStyle())
                                .focusable()
                                .focused($focusedID, equals: g.id)
                            }
                        }
                        .padding(.horizontal, 48)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                    .onChange(of: focusedID) { newFocus in
                        if let f = newFocus {
                            withAnimation(.easeOut(duration: 0.15)) { model.selectedID = f }
                        }
                    }
                }
            }
            bottomBar
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color.nxCanvas.ignoresSafeArea())
        .onAppear {
            if let sel = model.selectedID { focusedID = sel }
        }
        .onExitCommand { focusedID = model.selectedID }
        .onMoveCommand { dir in
            switch dir {
            case .left: model.moveSelection(-1)
            case .right: model.moveSelection(1)
            default: break
            }
            focusedID = model.selectedID
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
            }
            group.notify(queue: .main) {
                if !urls.isEmpty { model.importURLs(urls) }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.nxAccent.opacity(0.08))
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.nxAccent,
                                      style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 30, weight: .light))
                        Text("松手导入游戏到游戏库")
                            .font(.system(size: 15, weight: .semibold)).tracking(-0.224)
                    }
                    .foregroundColor(.nxAccent)
                }
                .padding(10)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            BuildProgressPanel().environmentObject(model)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environmentObject(model)
        }
        .sheet(isPresented: $model.showEditProfile) {
            ProfileEditView().environmentObject(model)
        }
        .alert(model.alertMessage ?? "", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        }
    }

    /// 工具条(隐藏标题栏模式):材质随系统亮暗,左侧让出红绿灯位;标题栏与工具条融为一条原生 chrome
    private var topBar: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 62, height: 1)   // 红绿灯避让
            Button { model.showEditProfile = true } label: {
                HStack(spacing: 7) {
                    profileAvatar
                        .frame(width: 24, height: 24)
                    Text(model.cfg.profileName)
                        .font(.system(size: 13, weight: .semibold)).tracking(-0.224)
                        .foregroundColor(.nxText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 110, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Capsule())
                .background(Capsule().fill(Color.nxChip))
            }
            .buttonStyle(NXPressStyle())
            .help("编辑资料")

            Spacer()
            if model.importing {
                ProgressView().controlSize(.mini).frame(width: 32, height: 32)
            } else {
                NXCircleButton(system: "square.and.arrow.down", help: "导入游戏(NSP/XCI 或文件夹)") {
                    model.presentImportPanel()
                }
            }
            NXCircleButton(system: "arrow.clockwise", help: "刷新") { model.refresh() }
            NXCircleButton(system: "gearshape", help: "设置") { model.showSettings = true }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.nxHairline).frame(height: 1) }
    }

    /// 头像:照片或安静的灰芯片占位(无渐变——系统禁装饰性渐变)
    @ViewBuilder private var profileAvatar: some View {
        if let img = model.profileAvatarImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.nxChip)
                .overlay(Image(systemName: "person.fill").font(.system(size: 11)).foregroundColor(.nxMuted))
        }
    }

    private var sessionTimeText: String {
        guard model.runningFolder != nil,
              let s = Launcher.shared.sessionStart else { return "" }
        let secs = PlaytimeStore.format(model.now.timeIntervalSince(s))
        return secs.isEmpty ? "" : " · 本次 \(secs)"
    }

    /// 底栏(sub-nav-frosted 的暗面版:材质 + 发丝上缘)
    private var bottomBar: some View {
        HStack {
            if let g = model.selectedGame, model.runningFolder == g.folder {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("正在运行「\(g.displayName)」" + sessionTimeText)
                        .font(.system(size: 12)).tracking(-0.12)
                        .foregroundColor(.nxMuted)
                }
            } else if let g = model.selectedGame, model.buildingFolder == g.folder,
                      let bp = model.buildProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在构建「\(g.displayName)」" +
                         (bp.n > 0 ? " · \(bp.k)/\(bp.n) \(bp.stage)" : "") +
                         (bp.frac.map { String(format: " · %.0f%%", $0 * 100) } ?? ""))
                        .font(.system(size: 12)).tracking(-0.12)
                        .foregroundColor(.nxMuted)
                }
            } else if let g = model.selectedGame, model.launchingFolder == g.folder {
                Text("正在启动…")
                    .font(.system(size: 12)).tracking(-0.12)
                    .foregroundColor(.nxMuted)
            } else if let g = model.selectedGame {
                Text(g.path)
                    .font(.system(size: 11)).tracking(-0.12)
                    .foregroundColor(.nxDim.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.runningFolder != nil {
                Button { model.stop() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill").font(.system(size: 10, weight: .semibold))
                        Text("停止").font(.system(size: 13, weight: .semibold)).tracking(-0.224)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.nxAccent))
                }
                .buttonStyle(NXPressStyle())
                .help("停止游戏")
            }
            NXKeyHint(key: "↵", text: "选择/开始")
            NXKeyHint(key: "←→", text: "移动")
            NXKeyHint(key: "⌘Q", text: "退出")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Color.nxHairline).frame(height: 1) }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundColor(.nxDim)
            Text("游戏库是空的")
                .font(.system(size: 24, weight: .light)).tracking(0.196)
                .foregroundColor(.nxText)
            Text("在设置里检查游戏库路径;把游戏文件夹放进库后点刷新")
                .font(.system(size: 17)).tracking(-0.374)
                .foregroundColor(.nxMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    // nxnative 引擎更新
    @State private var localInfoStr: String?
    @State private var checking = false
    @State private var pulling = false
    @State private var updateMsg: String?
    @State private var updateIsError = false
    @State private var updateIsAccent = false
    @State private var upstreamSha: String?

    enum Tone { case info, accent, error }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置")
                .font(.system(size: 21, weight: .semibold)).tracking(-0.23)
                .foregroundColor(.nxText)
            Group {
                field("游戏库路径", text: $model.cfg.library)
                field("nxnative 仓库", text: $model.cfg.repo)
                field("网页前端目录", text: $model.cfg.frontend)
            }
            HStack {
                Text("游戏语言")
                    .font(.system(size: 12)).tracking(-0.12)
                    .foregroundColor(.nxDim)
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: $model.cfg.language) {
                    Text("默认(英文)").tag("")
                    ForEach(["en-US", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "pt", "ru"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .labelsHidden()
            }
            Text("语言在下次启动游戏时生效,无需重新构建")
                .font(.system(size: 11)).tracking(-0.12)
                .foregroundColor(.nxDim)

            Divider().overlay(Color.nxHairline)

            // —— nxnative 引擎:版本与更新 ——
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("nxnative 引擎")
                        .font(.system(size: 12, weight: .semibold)).tracking(-0.12)
                        .foregroundColor(.nxText)
                    Spacer()
                    Button { checkUpdate() } label: {
                        HStack(spacing: 6) {
                            if checking {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text(checking ? "检查中…" : "检查更新")
                                .font(.system(size: 12)).tracking(-0.12)
                        }
                        .foregroundColor(.nxAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().stroke(Color.nxAccent, lineWidth: 1))
                    }
                    .buttonStyle(NXPressStyle())
                    .disabled(checking || pulling || localInfoStr == nil)
                }
                if let local = localInfoStr {
                    Text("当前 \(local)")
                        .font(.system(size: 11)).tracking(-0.12)
                        .foregroundColor(.nxDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("此安装非 git 克隆,无法检查更新")
                        .font(.system(size: 11)).tracking(-0.12)
                        .foregroundColor(.nxDim)
                }
                if let m = updateMsg {
                    Text(m)
                        .font(.system(size: 11)).tracking(-0.12)
                        .foregroundColor(updateIsError ? .red : (updateIsAccent ? .nxAccent : .nxDim))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let up = upstreamSha {
                    HStack {
                        Spacer()
                        Button { doUpdate() } label: {
                            HStack(spacing: 5) {
                                if pulling { ProgressView().controlSize(.mini) } else {
                                    Image(systemName: "arrow.down.circle").font(.system(size: 11, weight: .semibold))
                                }
                                Text(pulling ? "更新中…" : "更新")
                                    .font(.system(size: 12, weight: .semibold)).tracking(-0.12)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.nxAccent))
                        }
                        .buttonStyle(NXPressStyle())
                        .disabled(pulling)
                        Button { upstreamSha = nil; updateMsg = nil } label: {
                            Text("暂不").font(.system(size: 12)).tracking(-0.12)
                                .foregroundColor(.nxMuted)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.nxChip))
                        }
                        .buttonStyle(NXPressStyle())
                        .disabled(pulling)
                    }
                }
            }

            HStack {
                Spacer()
                Button { dismiss() } label: { NXGhostLabel(title: "取消") }
                    .buttonStyle(NXPressStyle())
                Button {
                    model.saveSettings()
                    dismiss()
                } label: { NXPrimaryLabel(title: "保存") }
                    .buttonStyle(NXPressStyle())
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Color.nxCanvas)
        .onAppear { refreshLocalInfo() }
        .onChange(of: model.cfg.repo) { _ in refreshLocalInfo() }
    }

    private func refreshLocalInfo() {
        let repo = model.cfg.repo
        DispatchQueue.global(qos: .userInitiated).async {
            let info = repo.isEmpty ? nil : NxUpdate.localInfo(repo: repo)
            DispatchQueue.main.async { localInfoStr = info }
        }
    }

    /// 检查更新:本地 HEAD ↔ 上游(git ls-remote,无 API 配额限制)
    private func checkUpdate() {
        let repo = model.cfg.repo
        checking = true
        updateMsg = nil
        upstreamSha = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let local = repo.isEmpty ? nil : NxUpdate.localInfo(repo: repo)
            let up = NxUpdate.upstreamHead(repo: repo)
            DispatchQueue.main.async {
                checking = false
                localInfoStr = local
                switch up {
                case .success(let sha):
                    if let l = local, l.hasPrefix(sha) {
                        updateMsg = "已是最新(上游同为 \(sha))"
                        updateIsError = false; updateIsAccent = false
                    } else {
                        upstreamSha = sha
                        updateMsg = "发现新版本:上游 HEAD \(sha)(本地 \((local ?? "未知").prefix(7)))"
                        updateIsError = false; updateIsAccent = true
                    }
                case .failure(let e):
                    updateMsg = e.message
                    updateIsError = true; updateIsAccent = false
                }
            }
        }
    }

    /// 用户确认后执行快进更新;提示重新构建(引擎更新不触及已构建产物)
    private func doUpdate() {
        let repo = model.cfg.repo
        pulling = true
        updateMsg = "正在更新…"
        updateIsError = false; updateIsAccent = false
        DispatchQueue.global(qos: .userInitiated).async {
            let r = NxUpdate.pull(repo: repo)
            DispatchQueue.main.async {
                pulling = false
                switch r {
                case .success(let info):
                    upstreamSha = nil
                    localInfoStr = info
                    updateMsg = "已更新。已构建的游戏如需吃到引擎修复,请在网页前端重新构建对应游戏。"
                    updateIsAccent = true; updateIsError = false
                case .failure(let e):
                    updateMsg = e.message
                    updateIsError = true; updateIsAccent = false
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12)).tracking(-0.12)
                .foregroundColor(.nxDim)
                .frame(width: 90, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
        }
    }
}

// MARK: - 编辑资料

struct ProfileEditView: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var avatarFile = ""
    @State private var pendingSource: URL?
    @State private var pendingImage: NSImage?
    @State private var saveError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑资料")
                .font(.system(size: 21, weight: .semibold)).tracking(-0.23)
                .foregroundColor(.nxText)

            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 8) {
                    avatarPreview
                        .frame(width: 72, height: 72)
                    Text("头像")
                        .font(.system(size: 11)).tracking(-0.12)
                        .foregroundColor(.nxDim)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text("名字")
                            .font(.system(size: 12)).tracking(-0.12)
                            .foregroundColor(.nxDim)
                            .frame(width: 40, alignment: .leading)
                        TextField("玩家", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .frame(maxWidth: 220)
                        Text("\(name.count)/12")
                            .font(.system(size: 11)).tracking(-0.12)
                            .foregroundColor(name.count >= 12 ? .nxAccent : .nxDim)
                    }
                    HStack(spacing: 10) {
                        Button { pickAvatar() } label: { NXGhostLabel(title: "更换头像") }
                            .buttonStyle(NXPressStyle())
                        Button {
                            avatarFile = ""
                            pendingSource = nil
                            pendingImage = nil
                            saveError = ""
                        } label: { NXGhostLabel(title: "移除头像") }
                            .buttonStyle(NXPressStyle())
                            .disabled(avatarFile.isEmpty && pendingSource == nil)
                            .opacity(avatarFile.isEmpty && pendingSource == nil ? 0.4 : 1)
                    }
                    Text("支持 png / jpg,保存时拷入应用数据目录")
                        .font(.system(size: 11)).tracking(-0.12)
                        .foregroundColor(.nxDim)
                }
            }

            if !saveError.isEmpty {
                Text(saveError)
                    .font(.system(size: 11)).tracking(-0.12)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button { dismiss() } label: { NXGhostLabel(title: "取消") }
                    .buttonStyle(NXPressStyle())
                Button {
                    if let err = model.saveProfile(name: name,
                                                   currentAvatar: avatarFile,
                                                   pendingSource: pendingSource) {
                        saveError = err
                    } else {
                        dismiss()
                    }
                } label: { NXPrimaryLabel(title: "保存") }
                    .buttonStyle(NXPressStyle())
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Color.nxCanvas)
        .onAppear {
            name = model.cfg.profileName
            avatarFile = model.cfg.profileAvatar
            pendingSource = nil
            pendingImage = nil
            saveError = ""
        }
        .onChange(of: name) { v in
            if v.count > 12 { name = String(v.prefix(12)) }
        }
    }

    @ViewBuilder private var avatarPreview: some View {
        if let img = pendingImage {
            previewCircle(img)
        } else if !avatarFile.isEmpty,
                  let url = Config.avatarURL(filename: avatarFile),
                  let img = NSImage(contentsOf: url) {
            previewCircle(img)
        } else {
            Circle()
                .fill(Color.nxChip)
                .overlay(Image(systemName: "person.fill").font(.system(size: 26)).foregroundColor(.nxMuted))
        }
    }

    private func previewCircle(_ img: NSImage) -> some View {
        Image(nsImage: img)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .clipShape(Circle())
    }

    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "选择头像图片(png / jpg)"
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingSource = url
        pendingImage = NSImage(contentsOf: url)
        saveError = ""
    }
}

// MARK: - App 入口

/// 入口不在这里:main.swift 先处理 CLI(--list-games/--launch/--stop),GUI 路径再调 LibraryApp.main()
struct LibraryApp: App {
    @StateObject private var model = LibraryModel()
    var body: some Scene {
        WindowGroup("NX 游戏库") {
            LibraryView().environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar) // 原生 chrome:标题栏与材质工具条融为一体,亮暗随系统
        .defaultSize(width: 1080, height: 640)
    }
}
