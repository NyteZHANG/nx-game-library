import Foundation

/// 游戏时长:存 <build>/playtime.json(跟游戏走,库放移动硬盘也不丢)
struct PlaytimeRecord: Codable {
    var totalSeconds: Double = 0
    var lastPlayed: Date?
}

enum PlaytimeStore {
    static func fileURL(buildDir: String) -> URL {
        URL(fileURLWithPath: buildDir).appendingPathComponent("playtime.json")
    }

    static func record(buildDir: String) -> PlaytimeRecord {
        guard let data = try? Data(contentsOf: fileURL(buildDir: buildDir)),
              let r = try? JSONDecoder().decode(PlaytimeRecord.self, from: data) else {
            return PlaytimeRecord()
        }
        return r
    }

    /// 一局结束(正常退出/被杀都会走到):累加并盖时间戳
    static func addSession(buildDir: String, seconds: Double, at end: Date = Date()) {
        guard seconds > 0 else { return }
        var r = record(buildDir: buildDir)
        r.totalSeconds += seconds
        r.lastPlayed = end
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(r) {
            try? data.write(to: fileURL(buildDir: buildDir), options: .atomic)
        }
    }

    /// 「12小时30分」「45分钟」「不到1分钟」;0 返回空串
    static func format(_ seconds: Double) -> String {
        let s = Int(seconds)
        guard s >= 60 else { return s > 0 ? "不到1分钟" : "" }
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)小时\(m)分" : "\(h)小时" }
        return "\(m)分钟"
    }
}
