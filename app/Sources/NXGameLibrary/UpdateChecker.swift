import Foundation

/// nxnative 引擎版本检测与更新。
/// 传输策略(踩坑结论):
/// - 不用 GitHub API(无认证 60 次/时,共享出口 IP 秒 403),用 git 协议:ls-remote 读上游 HEAD
/// - 强制 HTTP/1.1:HTTP/2 多路复用在被重置的链路上更容易整包中断
/// - 按操作给超时:ls-remote 30s;pull 要传整个包,给 300s(此前统一 20s,慢网络下是
///   自己 SIGTERM 掉 fetch-pack,报出来的正是 "unexpected disconnect")
/// - 拉取失败自动重试(网络瞬断常见),仍失败才把 git 尾部错误交给 UI
enum NxUpdate {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func gitOnce(_ repo: String, _ args: [String], timeout: Double) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // -c 必须在子命令之前;-C 同为全局选项,顺序无碍
        p.arguments = ["git", "-C", repo, "-c", "http.version=HTTP/1.1"] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        var timedOut = false
        let killer = DispatchWorkItem { if p.isRunning { p.terminate(); timedOut = true } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (timedOut ? -2 : p.terminationStatus, out)
    }

    /// 带重试的 git 调用(仅网络型操作重试;本地 log 不重试)
    private static func git(_ repo: String, _ args: [String],
                            timeout: Double, retries: Int = 0) -> (Int32, String) {
        var last: (Int32, String) = (-1, "")
        for attempt in 0...retries {
            last = gitOnce(repo, args, timeout: timeout)
            if last.0 == 0 { return last }
            if attempt < retries { Thread.sleep(forTimeInterval: 2) }
        }
        return last
    }

    /// 网络型失败的统一提示(带重试指引)
    private static func netHint(_ out: String) -> String {
        if out.contains("disconnect") || out.contains("early EOF") || out.contains("reset") {
            return "。到 GitHub 的连接被重置,已自动重试仍失败——可稍后再点一次,或挂代理后更新"
        }
        return ""
    }

    /// 本地 HEAD(短 sha · 日期 · 主题);非 git 安装返回 nil
    static func localInfo(repo: String) -> String? {
        let (rc, out) = git(repo, ["log", "-1", "--format=%h · %cs · %s"], timeout: 10)
        guard rc == 0 else { return nil }
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// 上游 HEAD 短 sha(走 git 协议)
    static func upstreamHead(repo: String) -> Result<String, Failure> {
        let (rc, out) = git(repo, ["ls-remote", "origin", "HEAD"],
                            timeout: 30, retries: 1)
        guard rc == 0 else {
            let base = rc == -2 ? "连接上游超时(网络到 GitHub 不通?)"
                                : "查询失败: \(out.prefix(120))"
            return .failure(Failure(message: base + netHint(out)))
        }
        let sha = out.split(separator: "\t").first.map(String.init) ?? ""
        guard sha.count >= 7 else { return .failure(Failure(message: "上游响应异常")) }
        return .success(String(sha.prefix(7)))
    }

    /// 快进更新(git pull --ff-only);300 秒超时 + 3 次尝试,脏工作区/分歧会失败并带出原因
    static func pull(repo: String) -> Result<String, Failure> {
        let (rc, out) = git(repo, ["pull", "--ff-only"],
                            timeout: 300, retries: 2)
        guard rc == 0 else {
            let tail = out.split(separator: "\n").suffix(4).joined(separator: " · ")
            return .failure(Failure(message: "更新失败: \(tail.prefix(300))" + netHint(out)))
        }
        return .success(localInfo(repo: repo) ?? "已更新")
    }
}
