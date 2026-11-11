import Foundation

/// 与网页前端 server.py 的 start_launch / _ensure_mac_host / stop_launch 逐字段一致。
enum LaunchError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

final class Launcher {
    static let shared = Launcher()
    private let lock = NSLock()
    private(set) var process: Process?
    private(set) var runningFolder: String?
    /// 本局开始时间(UI 用:实时显示本次游玩时长)
    private(set) var sessionStart: Date?

    /// 启动游戏(阻塞等待可选);成功后把 PID 写入 run.pid
    func launch(game: Game, cfg: AppConfig, wait: Bool) throws -> Process {
        guard let build = game.build, let buildDir = URLOptional(build.dir) else {
            throw LaunchError.message("尚未构建")
        }
        guard let pair = GameScanner.chooseLaunchPair(buildDir) else {
            throw LaunchError.message("缺解包文件或重写模块,请重新构建")
        }
        let repo = URL(fileURLWithPath: cfg.repo)
        guard let msl = GameScanner.chooseMsl(buildDir, repo: repo) else {
            throw LaunchError.message("缺着色器库(Mac 宿主版),请重新构建")
        }
        let kind = GameScanner.mslKind(buildDir, repo: repo)
        var env = ProcessInfo.processInfo.environment
        var extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        if let path = env["PATH"] { extraPaths.append(path) }
        env["PATH"] = extraPaths.joined(separator: ":")

        let fm = FileManager.default
        let runDir = buildDir.appendingPathComponent("frontend_run")
        let saveDir = buildDir.appendingPathComponent("save")
        let tempDir = runDir.appendingPathComponent("temp")
        for d in [runDir, saveDir, tempDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }

        let host = try ensureMacHost(buildDir: buildDir, titleID: build.titleID, repo: repo, env: env)

        var shmap: String?
        if kind == "nvn" {
            guard let s = GameScanner.findShmap(buildDir: buildDir, titleID: build.titleID, repo: repo) else {
                throw LaunchError.message("缺 shader_map.tsv(NVN 游戏必需),请重新构建")
            }
            shmap = s.path
        }

        env["DM_ROMFS"] = pair.romfs.path
        env["DM_SAVE"] = saveDir.path
        env["DM_TEMP"] = tempDir.path
        env["DM_MSL_DIR"] = msl.path
        env["DM_WINDOW"] = "1"
        env["DM_AUDIO"] = "1"
        if let s = shmap { env["DM_NVN_SHMAP"] = s }
        let aoc = buildDir.appendingPathComponent("aoc")
        var ad: ObjCBool = false
        if fm.fileExists(atPath: aoc.path, isDirectory: &ad), ad.boolValue {
            env["DM_AOC_DIR"] = aoc.path
        }
        let lang = cfg.language.trimmingCharacters(in: .whitespaces)
        if !lang.isEmpty { env["DM_LANG"] = lang }
        for (k, v) in cfg.extraEnv { env[k] = v }

        lock.lock()
        if let p = process, p.isRunning { lock.unlock(); throw LaunchError.message("已有游戏在运行") }
        lock.unlock()

        let logURL = runDir.appendingPathComponent("launch.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        guard let logf = try? FileHandle(forWritingTo: logURL) else {
            throw LaunchError.message("无法写日志: \(logURL.path)")
        }
        defer { try? logf.close() }
        let stamp = "===== \(Date()) launch \(game.folder) =====\n\(host.path) \(pair.patched.path)\n"
        logf.write(stamp.data(using: .utf8)!)
        try logf.seekToEnd()

        let p = Process()
        let startedAt = Date()
        let bdPath = buildDir.path
        p.executableURL = host
        p.arguments = [pair.patched.path]
        p.currentDirectoryURL = runDir
        p.environment = env
        p.standardOutput = logf
        p.standardError = logf
        p.terminationHandler = { [weak self] proc in
            // 时长入账:正常退出、SIGTERM、崩溃、被杀都走 waitpid 回调,无遗漏
            PlaytimeStore.addSession(buildDir: bdPath,
                                     seconds: Date().timeIntervalSince(startedAt))
            try? FileManager.default.removeItem(at: Config.pidFileURL)
            self?.lock.lock()
            if self?.process === proc {
                self?.process = nil
                self?.runningFolder = nil
                self?.sessionStart = nil
            }
            self?.lock.unlock()
        }
        do {
            try p.run()
        } catch {
            throw LaunchError.message("启动失败: \(error.localizedDescription)")
        }
        lock.lock()
        process = p
        runningFolder = game.folder
        sessionStart = startedAt
        lock.unlock()
        try? "\(p.processIdentifier)".data(using: .utf8)!.write(to: Config.pidFileURL, options: .atomic)
        if wait {
            p.waitUntilExit()
        }
        return p
    }

    /// server.py stop_launch:SIGTERM,5 秒后 SIGKILL
    func stop() {
        lock.lock()
        let p = process
        lock.unlock()
        if let p, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        } else if let text = try? String(contentsOf: Config.pidFileURL, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespaces)), pid > 0 {
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: Config.pidFileURL)
        }
    }

    /// server.py _ensure_mac_host:dmhost 缺失**或链/游戏过期**时现场 make 再复制。
    /// 宿主把 DMSH_CHAIN 和游戏 ID 编译进自身:引擎 pull 后链已变,旧宿主会去找
    /// 不存在的 b-<旧链> 目录(启动即 [RED]),必须重编。
    private func ensureMacHost(buildDir: URL, titleID: String, repo: URL, env: [String: String]) throws -> URL {
        let fm = FileManager.default
        let host = buildDir.appendingPathComponent("tools/dmhost")
        if fm.isExecutableFile(atPath: host.path) {
            var fresh = true
            if let chain = GameScanner.dmshChain(repo: repo),
               let blob = try? Data(contentsOf: host) {
                if let cd = chain.data(using: .utf8), blob.range(of: cd) == nil { fresh = false }
                if let td = titleID.data(using: .utf8), blob.range(of: td) == nil { fresh = false }
            }
            if fresh { return host }
        }

        let logURL = buildDir.appendingPathComponent("logs/dmhost_build.log")
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        make.arguments = ["-C", repo.appendingPathComponent("dm/host").path, "GAME=\(titleID)", "dmhost"]
        make.currentDirectoryURL = repo
        make.environment = env
        let out = Pipe()
        make.standardOutput = out
        make.standardError = out
        do { try make.run() } catch {
            throw LaunchError.message("编译 Mac 宿主失败: \(error.localizedDescription)")
        }
        // 先读后等:管道缓冲 64KB,若先 waitUntilExit,make 输出一满就和读端互等,永远僵住
        let data = out.fileHandleForReading.readDataToEndOfFile()
        make.waitUntilExit()
        try? data.write(to: logURL)
        let src = repo.appendingPathComponent("dm/host/dmhost")
        guard make.terminationStatus == 0, fm.isExecutableFile(atPath: src.path) else {
            let tail = String(data: data, encoding: .utf8)?
                .split(separator: "\n").suffix(8).joined(separator: " | ") ?? ""
            throw LaunchError.message("编译 Mac 宿主失败(日志: \(logURL.path)): \(tail.prefix(400))")
        }
        try? fm.createDirectory(at: host.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            if fm.fileExists(atPath: host.path) { try fm.removeItem(at: host) }
            try fm.copyItem(at: src, to: host)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)
        } catch {
            throw LaunchError.message("复制 dmhost 失败: \(error.localizedDescription)")
        }
        return host
    }
}

private func URLOptional(_ s: String) -> URL? { URL(fileURLWithPath: s) }
