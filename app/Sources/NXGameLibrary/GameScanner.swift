import Foundation

/// 与网页前端 server.py 的扫描/配对着色器逻辑逐字段一致(契约审查以 server.py 为准)。
struct BuildInfo: Codable {
    let dir: String
    let titleID: String
    let hasDmhost: Bool
    let playable: Bool
    let latestVersion: String?
}

struct Game: Identifiable, Codable {
    let folder: String
    let path: String
    let displayName: String
    let titleIDs: [String]
    let build: BuildInfo?
    /// 累计游玩秒数(playtime.json,与 lastPlayed 一起在扫描时读)
    var playtimeSeconds: Double = 0
    var lastPlayed: Date?

    var id: String { folder }
    var playable: Bool { build?.playable ?? false }
    var iconPath: String? { build.flatMap { b in
        guard let v = b.latestVersion else { return nil }
        let p = "\(b.dir)/extract/\(v)/icon.jpg"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    } }
}

enum GameScanner {
    static let titleRE = try! NSRegularExpression(pattern: "\\[([0-9A-Fa-f]{16})\\]")
    static let versionRE = try! NSRegularExpression(pattern: "\\[v(\\d+)\\]")

    static func scan(cfg: AppConfig) -> [Game] {
        let lib = (cfg.library as NSString).expandingTildeInPath
        let libURL = URL(fileURLWithPath: lib, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: libURL.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        let names = readProfileNames(repo: URL(fileURLWithPath: cfg.repo))
        var games: [Game] = []
        var entries: [(String, URL)] = []
        if hasGameContent(libURL) { entries.append((".", libURL)) }
        if let kids = try? FileManager.default.contentsOfDirectory(
            at: libURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) {
            for k in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var kd: ObjCBool = false
                guard FileManager.default.fileExists(atPath: k.path, isDirectory: &kd), kd.boolValue else { continue }
                if hasGameContent(k) { entries.append((k.lastPathComponent, k)) }
            }
        }
        for (folder, url) in entries {
            let titleIDs = scanTitleIDs(url)
            let base = baseTitleID(titleIDs)
            let display = (base.flatMap { names[$0] }) ?? (folder == "." ? libURL.lastPathComponent : folder)
            let build = findBuild(url, repo: URL(fileURLWithPath: cfg.repo))
            var game = Game(folder: folder, path: url.path, displayName: display,
                            titleIDs: titleIDs, build: build)
            if let b = build {
                let rec = PlaytimeStore.record(buildDir: b.dir)
                game.playtimeSeconds = rec.totalSeconds
                game.lastPlayed = rec.lastPlayed
            }
            games.append(game)
        }
        return games
    }

    /// 有 nsp/xci,或已有 *_build(无 NSP 的已构建游戏照常显示)即算游戏文件夹
    private static func hasGameContent(_ url: URL) -> Bool {
        guard let kids = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return false
        }
        for k in kids {
            let ext = k.pathExtension.lowercased()
            if ext == "nsp" || ext == "xci" { return true }
            var kd: ObjCBool = false
            if FileManager.default.fileExists(atPath: k.path, isDirectory: &kd), kd.boolValue,
               k.lastPathComponent.hasSuffix("_build") { return true }
        }
        return false
    }

    private static func scanTitleIDs(_ url: URL) -> [String] {
        var out: [String] = []
        guard let kids = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return out
        }
        for k in kids {
            var kd: ObjCBool = false
            guard FileManager.default.fileExists(atPath: k.path, isDirectory: &kd), !kd.boolValue else { continue }
            let name = k.lastPathComponent as NSString
            let full = NSRange(location: 0, length: name.length)
            for m in titleRE.matches(in: k.lastPathComponent, range: full) {
                let t = (name.substring(with: m.range(at: 1))).uppercased()
                if !out.contains(t) { out.append(t) }
            }
        }
        return out
    }

    private static func baseTitleID(_ ids: [String]) -> String? {
        for t in ids where t.lowercased().hasSuffix("000") { return t }
        return ids.first
    }

    /// server.py _find_build:最新 mtime 的 *_build;可启动 = 版本配对着色器库齐
    private static func findBuild(_ gamePath: URL, repo: URL) -> BuildInfo? {
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(at: gamePath, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        var best: URL?, bestMtime = Date.distantPast
        for k in kids {
            var kd: ObjCBool = false
            guard fm.fileExists(atPath: k.path, isDirectory: &kd), kd.boolValue,
                  k.lastPathComponent.hasSuffix("_build") else { continue }
            let m = (try? k.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if m > bestMtime { best = k; bestMtime = m }
        }
        guard let buildDir = best else { return nil }
        let titleID = String(buildDir.lastPathComponent.dropLast("_build".count)).uppercased()
        let dmhost = buildDir.appendingPathComponent("tools/dmhost")
        let hasDmhost = fm.isExecutableFile(atPath: dmhost.path)
        let pair = chooseLaunchPair(buildDir)
        let msl = chooseMsl(buildDir, repo: repo)
        let kind = mslKind(buildDir, repo: repo)
        var shmapOK = true
        if kind == "nvn" {
            shmapOK = findShmap(buildDir: buildDir, titleID: titleID, repo: repo) != nil
        }
        let playable = pair != nil && msl != nil && shmapOK
        var latestVer: String?
        let ex = buildDir.appendingPathComponent("extract")
        if let vers = try? fm.contentsOfDirectory(at: ex, includingPropertiesForKeys: nil) {
            var bestNum = Int.min
            for v in vers {
                var vd: ObjCBool = false
                guard fm.fileExists(atPath: v.path, isDirectory: &vd), vd.boolValue else { continue }
                // 旧布局 RomFS/ 目录,新布局 RomFS.img 镜像(DM_ROMFS 两者皆可)
                let hasRom = fm.fileExists(atPath: v.appendingPathComponent("RomFS").path)
                    || fm.fileExists(atPath: v.appendingPathComponent("RomFS.img").path)
                guard hasRom else { continue }
                let num = Int(v.lastPathComponent.dropFirst(1)) ?? -1
                if num > bestNum { bestNum = num; latestVer = v.lastPathComponent }
            }
        }
        return BuildInfo(dir: buildDir.path, titleID: titleID, hasDmhost: hasDmhost,
                         playable: playable, latestVersion: latestVer)
    }

    /// server.py _choose_launch_pair:同版本 extract/<ver>/(RomFS/ 或 RomFS.img) + patched_<ver>/ 完整配对,数值版本优先
    static func chooseLaunchPair(_ buildDir: URL) -> (ver: String, romfs: URL, patched: URL)? {
        let fm = FileManager.default
        let ex = buildDir.appendingPathComponent("extract")
        struct P { let ver: String; let romfs: URL; let patched: URL; let mtime: Date }
        var pairs: [P] = []
        guard let kids = try? fm.contentsOfDirectory(at: buildDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        for k in kids {
            var kd: ObjCBool = false
            guard fm.fileExists(atPath: k.path, isDirectory: &kd), kd.boolValue,
                  k.lastPathComponent.hasPrefix("patched_") else { continue }
            let ver = String(k.lastPathComponent.dropFirst("patched_".count))
            guard !ver.isEmpty else { continue }
            // 游戏文件:旧布局 RomFS/ 目录,新布局 RomFS.img 镜像(上游 hle_fs.c 两者皆可)
            let dir = ex.appendingPathComponent(ver)
            let romfsDir = dir.appendingPathComponent("RomFS")
            var rd: ObjCBool = false
            let romfs: URL
            if fm.fileExists(atPath: romfsDir.path, isDirectory: &rd), rd.boolValue {
                romfs = romfsDir
            } else {
                let img = dir.appendingPathComponent("RomFS.img")
                guard fm.fileExists(atPath: img.path) else { continue }
                romfs = img
            }
            let m = (try? k.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            pairs.append(P(ver: ver, romfs: romfs, patched: k, mtime: m))
        }
        guard !pairs.isEmpty else { return nil }
        let best = pairs.max { a, b in
            let na = Int(a.ver) ?? -1, nb = Int(b.ver) ?? -1
            if na != nb { return na < nb }
            return a.mtime < b.mtime
        }!
        return (best.ver, best.romfs, best.patched)
    }

    /// server.py _dmsh_chain
    static func dmshChain(repo: URL) -> String? {
        let p = repo.appendingPathComponent("dm/gfx/nvn/dmsh_chain.h")
        guard let text = try? String(contentsOf: p, encoding: .utf8) else { return nil }
        let re = try! NSRegularExpression(pattern: "#define\\s+DMSH_CHAIN\\s+\"([^\"]+)\"")
        let ns = text as NSString
        let r = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        return r.map { ns.substring(with: $0.range(at: 1)) }
    }

    /// server.py _msl_kind:nvn|vulkan|gl|nil
    static func mslKind(_ buildDir: URL, repo: URL) -> String? {
        let fm = FileManager.default
        let cache = buildDir.appendingPathComponent("shader/cache")
        var cd: ObjCBool = false
        if fm.fileExists(atPath: cache.path, isDirectory: &cd), cd.boolValue {
            if let chain = dmshChain(repo: repo) {
                var bd: ObjCBool = false
                if fm.fileExists(atPath: cache.appendingPathComponent("b-\(chain)").path, isDirectory: &bd), bd.boolValue {
                    return "nvn"
                }
            } else if let kids = try? fm.contentsOfDirectory(atPath: cache.path),
                      kids.contains(where: { $0.hasPrefix("b-") }) {
                return "nvn"
            }
        }
        let vk = buildDir.appendingPathComponent("shader/vk")
        if fm.fileExists(atPath: vk.appendingPathComponent("vk_shaders.tsv").path)
            || fm.fileExists(atPath: vk.appendingPathComponent("vk_shaders.metallib").path) {
            return "vulkan"
        }
        let gl = buildDir.appendingPathComponent("shader/gl")
        if fm.fileExists(atPath: gl.appendingPathComponent("gl_shaders.tsv").path)
            || fm.fileExists(atPath: gl.appendingPathComponent("gl_shaders.metallib").path) {
            return "gl"
        }
        return nil
    }

    /// server.py _choose_msl:返回宿主拼接段之前的父目录
    static func chooseMsl(_ buildDir: URL, repo: URL) -> URL? {
        switch mslKind(buildDir, repo: repo) {
        case "nvn": return buildDir.appendingPathComponent("shader/cache")
        case "vulkan", "gl": return buildDir.appendingPathComponent("shader")
        default: return nil
        }
    }

    static func findShmap(buildDir: URL, titleID: String, repo: URL) -> URL? {
        let local = buildDir.appendingPathComponent("profile/\(titleID)/shader_map.tsv")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let reg = repo.appendingPathComponent("dm/games/\(titleID)/shader_map.tsv")
        return FileManager.default.fileExists(atPath: reg.path) ? reg : nil
    }

    /// 读仓库 profile 的 name 键(game.tsv,TAB 分隔;无 python 依赖)
    static func readProfileNames(repo: URL) -> [String: String] {
        var out: [String: String] = [:]
        let dir = repo.appendingPathComponent("dm/games")
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return out }
        for id in ids {
            let tsv = dir.appendingPathComponent("\(id)/game.tsv")
            guard let text = try? String(contentsOf: tsv, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if line.hasPrefix("#") { continue }
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                if parts.count >= 2, parts[0] == "name" {
                    out[id.uppercased()] = String(parts[1])
                    break
                }
            }
        }
        return out
    }
}
