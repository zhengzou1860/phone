import SwiftUI

// MARK: - 入口
//
// 整晚挂在后台，最怕的不是报错，是当场没写下「死因」。AVFoundation 抛的是 OC 异常，
// Swift 的 do/catch 抓不住，进程直接没了——这个钩子是唯一能在断气前把栈塞进磁盘日志的地方。
@main
struct SnoreApp: App {
    init() {
        NSSetUncaughtExceptionHandler { ex in
            SnoreJournal.line("未捕获异常 \(ex.name.rawValue)｜\(ex.reason ?? "-")")
            for f in ex.callStackSymbols.prefix(8) { SnoreJournal.line("  栈 \(f)") }
        }
    }

    var body: some Scene {
        WindowGroup {
            SnoreRootView()
        }
    }
}
