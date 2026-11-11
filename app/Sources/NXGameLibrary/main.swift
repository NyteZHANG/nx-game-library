import Foundation
import AppKit

/// CLI(验证/脚本用)与 GUI 共用同一套扫描与启动逻辑:
///   --list-games            输出 JSON [{folder,title_id,name,playable}] 后退出
///   --launch <folder>       启动游戏(前台等退出,退出码透传)
///   --stop                  停止本 app 起的游戏(SIGTERM,5s 后 SIGKILL)
///   无参数                  启动 GUI

let usage = """
用法: NXGameLibrary [--list-games | --launch <文件夹> | --stop | --import <路径...> | --check-update | --help]
  --list-games        列出游戏库(JSON)
  --launch <文件夹>   启动指定游戏并等待退出
  --stop              停止正在运行的游戏
  --import <路径...>  导入 NSP/XCI 文件或文件夹到游戏库
  --check-update      检测本地与上游 nxnative 版本(git 协议)
  无参数              打开图形界面
"""

func stderrPrint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let args = CommandLine.arguments

if args.contains("--help") || args.contains("-h") {
    print(usage)
    exit(0)
} else if args.contains("--list-games") {
    let cfg = Config.load()
    let games = GameScanner.scan(cfg: cfg)
    let arr: [[String: Any]] = games.map { g in
        ["folder": g.folder,
         "title_id": g.build?.titleID ?? "",
         "name": g.displayName,
         "playable": g.playable,
         "playtime_seconds": g.playtimeSeconds]
    }
    if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
        exit(0)
    } else {
        stderrPrint("JSON 序列化失败")
        exit(1)
    }
} else if let i = args.firstIndex(of: "--launch") {
    guard i + 1 < args.count else {
        stderrPrint("--launch 需要文件夹名")
        exit(2)
    }
    let folder = args[i + 1]
    let cfg = Config.load()
    let games = GameScanner.scan(cfg: cfg)
    guard let game = games.first(where: { $0.folder == folder }) else {
        stderrPrint("游戏库里没有「\(folder)」")
        exit(2)
    }
    guard game.playable else {
        stderrPrint("「\(game.displayName)」尚未构建或缺运行文件")
        exit(2)
    }
    do {
        let p = try Launcher.shared.launch(game: game, cfg: cfg, wait: true)
        exit(p.terminationStatus)
    } catch {
        stderrPrint("启动失败: \(error.localizedDescription)")
        exit(1)
    }
} else if let i = args.firstIndex(of: "--import") {
    // --import <路径...>:把 NSP/XCI 文件或文件夹导入游戏库(打印汇总后退出)
    let paths = args[(i + 1)...].filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
    guard !paths.isEmpty else { stderrPrint("--import 需要至少一个路径"); exit(2) }
    let cfg = Config.load()
    print(LibraryModel.performImport(urls: paths, cfg: cfg))
    exit(0)
} else if args.contains("--check-update") {
    let cfg = Config.load()
    guard !cfg.repo.isEmpty else { stderrPrint("未配置 nxnative 仓库路径"); exit(2) }
    print("repo: \(cfg.repo)")
    guard let local = NxUpdate.localInfo(repo: cfg.repo) else {
        stderrPrint("local: 非 git 安装(或仓库不可读)")
        exit(2)
    }
    print("local:    \(local)")
    switch NxUpdate.upstreamHead(repo: cfg.repo) {
    case .success(let sha):
        print("upstream: \(sha)")
        if local.hasPrefix(sha) { print("status:   已是最新") }
        else { print("status:   有更新可用") }
        exit(0)
    case .failure(let e):
        stderrPrint("error: \(e.message)")
        exit(1)
    }
} else if args.contains("--stop") {
    Launcher.shared.stop()
    exit(0)
} else {
    // GUI 路径:亮暗完全随系统(动态色 token + 材质自动适配,不再强制外观)
    LibraryApp.main()
}
