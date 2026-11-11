import Foundation

/// 应用配置:~/Library/Application Support/NXGameLibrary/config.json
/// 首次运行若无配置,用默认值,并尝试从网页前端的 config.json 里继承 library / language。
struct AppConfig: Codable {
    var library: String
    var repo: String
    var frontend: String
    var language: String
    var extraEnv: [String: String]
    /// 用户资料:自定义名字(Switch 主页头像旁的名字)
    var profileName: String
    /// 头像文件名(存 Config.dir 下,如 "avatar.png";空 = 用渐变占位)
    var profileAvatar: String

    init(library: String, repo: String, frontend: String, language: String,
         extraEnv: [String: String],
         profileName: String = "玩家", profileAvatar: String = "") {
        self.library = library
        self.repo = repo
        self.frontend = frontend
        self.language = language
        self.extraEnv = extraEnv
        self.profileName = profileName
        self.profileAvatar = profileAvatar
    }

    static let `default` = AppConfig(
        library: "",
        repo: AppConfig.detectRepo() ?? "",
        frontend: AppConfig.detectFrontend() ?? "",
        language: "",
        extraEnv: [:]
    )

    // MARK: 路径探测(不硬编码本机路径;装在 /Applications 时通常探测不到,留空由设置页填)

    /// 可执行文件所在目录(dev: .build/release;装在 bundle: Contents/MacOS)
    private static var exeDir: URL {
        let path = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        return URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath()
    }

    /// 从可执行文件目录逐级向上找名为 name 的目录(如 ../../nxnative、../nxnative……)
    private static func detectSiblingDir(_ name: String, maxUp: Int = 6) -> String? {
        var dir = exeDir
        for _ in 0..<maxUp {
            let cand = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: cand.path, isDirectory: &isDir), isDir.boolValue {
                return cand.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }  // 到根了
            dir = parent
        }
        return nil
    }

    /// nxnative 仓库:前端同级的 nxnative 目录
    private static func detectRepo() -> String? { detectSiblingDir("nxnative") }

    /// 网页前端目录:向上找含 server.py 的目录
    private static func detectFrontend() -> String? {
        var dir = exeDir
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("server.py").path) {
                return dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// 旧 config.json 缺任何字段都不崩:一律用默认值兜底
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig.default
        library = try c.decodeIfPresent(String.self, forKey: .library) ?? d.library
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? d.repo
        frontend = try c.decodeIfPresent(String.self, forKey: .frontend) ?? d.frontend
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        extraEnv = try c.decodeIfPresent([String: String].self, forKey: .extraEnv) ?? d.extraEnv
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName) ?? d.profileName
        profileAvatar = try c.decodeIfPresent(String.self, forKey: .profileAvatar) ?? d.profileAvatar
        // 旧/手改 config 可能存了空名字或超长名字:兜底成默认值并截断,不崩不空白
        let pn = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        profileName = pn.isEmpty ? d.profileName : String(pn.prefix(12))
    }
}

enum Config {
    static let dir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NXGameLibrary", isDirectory: true)
    static var fileURL: URL { dir.appendingPathComponent("config.json") }
    static var pidFileURL: URL { dir.appendingPathComponent("run.pid") }

    static func load() -> AppConfig {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return cfg
        }
        // 首次运行:从网页前端的 config.json 继承游戏库与语言
        var cfg = AppConfig.default
        let feConfig = URL(fileURLWithPath: AppConfig.default.frontend)
            .appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: feConfig),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let lib = obj["library"] as? String, !lib.isEmpty { cfg.library = lib }
            if let lang = obj["language"] as? String { cfg.language = lang }
        }
        save(cfg)
        return cfg
    }

    static func save(_ cfg: AppConfig) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(cfg) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: 头像文件

    /// 拷贝用户选的图片到 Config.dir/avatar.<原扩展名>,返回存进 config 的文件名
    static func importAvatar(from source: URL) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let dest = dir.appendingPathComponent("avatar.\(ext)")
        // 同名先删(跨卷拷贝不覆盖)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)
        // 旧的 avatar.* 其他扩展名残留一并清掉,只留当前这个
        for item in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let name = item.lastPathComponent
            if name.hasPrefix("avatar."), name != dest.lastPathComponent {
                try? FileManager.default.removeItem(at: item)
            }
        }
        return dest.lastPathComponent
    }

    /// config 里的头像文件名 → 绝对 URL(不存在返回 nil)
    static func avatarURL(filename: String) -> URL? {
        guard !filename.isEmpty else { return nil }
        let url = dir.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 删除头像文件(仅限本 app 管理的 avatar.*)
    static func deleteAvatar(filename: String) {
        guard filename.hasPrefix("avatar.") else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(filename))
    }
}
