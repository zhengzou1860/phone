import Foundation
import UIKit

/// 整进程唯一的 background URLSession 持有者。
///
/// 为什么要从 ModelManager 里搬出来单独一个 singleton：background session 的下载事件
/// 是靠「系统重新拉起 app」交付的。拉起之后必须有人拿同一个 identifier 把 session 建起来，
/// 那批回调才会开始投递；原来这件事只有 ContentView 里的 ModelManager 在 download() 里做，
/// 进程被划掉再被系统拉起时根本没有 ModelManager，609 MB 就躺在系统临时目录里等着被删——
/// 手机上看到的就是「下完了但没有」。
final class ModelDownload: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelDownload()

    /// VoiceJournal.line 是「整读全文 + 整写全文」，两个线程同时写会互相盖掉行。
    /// delegate 回调不保证在主线程，所以这里的日志一律排回主线程，和 app 其余部分同一个口。
    private func log(_ text: String) {
        DispatchQueue.main.async { VoiceJournal.line(text) }
    }

    /// 必须固定，不能用 UUID：挂了/被系统回收后再开，找不到同 id 的 session 就丢进度。
    static let identifier = "voice.model.main"

    /// delegate 的回调不保证在主线程，所以这两个闭包只负责把消息扔出去，
    /// 谁在听由听的人自己切回主线程。
    var onProgress: ((Int64, Int64) -> Void)?
    var onFinish: ((Result<(url: URL, bytes: Int64), Error>) -> Void)?

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    /// 系统给的那声「这批事件我收完了」，必须调回去；不调它就认为还没处理完。
    private var pendingCompletion: (() -> Void)?

    private override init() { super.init() }

    /// 建（或复用）同 identifier 的 session。冷启、被系统后台拉起交付事件，都得先过这一步。
    @discardableResult
    func attach() -> URLSession {
        if let s = session { return s }
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        cfg.timeoutIntervalForResource = 3600
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        log("ModelDownload session 已建（" + Self.identifier + "）")
        return s
    }

    func start(url: URL) {
        liveDownloadTask { [weak self] live in
            guard let self = self else { return }
            if let t = live {
                self.log("已有在跑的任务，接手（已下 \(t.countOfBytesReceived) B）：再建一个 downloadTask 等于 609 MB 从头重下")
                self.task = t
                if t.state == .suspended { t.resume() }
                return
            }
            let s = self.attach()
            let t = s.downloadTask(with: url)
            t.resume()
            self.task = t
        }
    }

    /// 系统那边有没有还活着的下载任务。background session 被重新拉起时，没跑完的任务
    /// 会原样带回来（进度也在），这是唯一能看到它们的口子；界面据此决定「接手」还是「新开」。
    func liveDownloadTask(_ body: @escaping (URLSessionDownloadTask?) -> Void) {
        attach().getAllTasks { tasks in
            let live = tasks.compactMap { $0 as? URLSessionDownloadTask }
                .first { $0.state == .running || $0.state == .suspended }
            DispatchQueue.main.async { body(live) }
        }
    }

    /// AppDelegate 收到 handleEventsForBackgroundURLSession 时把 completionHandler 交进来。
    func takeOver(_ completionHandler: @escaping () -> Void) {
        pendingCompletion = completionHandler
        attach()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let done = self.pendingCompletion
            self.pendingCompletion = nil
            done?()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    /// 关键：这里的 location 在方法返回后 iOS 会立刻删掉，必须同步搬进 Documents，
    /// 别交给主线程排队。搬完文件就在磁盘上了，解压/校验留给前台的 check()。
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let destDir = ModelManager.modelDirectory()
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let dest = destDir.appendingPathComponent(ModelManager.zipName)
            try? FileManager.default.removeItem(at: dest)
            // copy 再删（move 跨 volume 会失败）；Documents 和 tmp 同 volume，但别赌
            try FileManager.default.copyItem(at: location, to: dest)
            try? FileManager.default.removeItem(at: location)
            let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            onFinish?(.success((url: dest, bytes: bytes)))
        } catch {
            onFinish?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let err = error {
            let ns = err as NSError
            log("下载中断 domain=" + ns.domain + " code=" + String(ns.code) + " " + err.localizedDescription)
            onFinish?(.failure(err))
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }
}

/// 只为一件事存在：让 background session 的事件在被系统拉起时有地方接。
final class VoiceAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = ModelDownload.shared.attach()
        // 没有 Mac 可看崩溃报告 ⇒ AVFoundation 那类 ObjC 异常在死之前先把原因落到磁盘日志。
        // 只写盘、不指望网络：进程当场死，发不出去了；下次「发到电脑」整份文件会带走。
        NSSetUncaughtExceptionHandler { ex in
            let frames = ex.callStackSymbols.prefix(6).joined(separator: " ‖ ")
            VoiceJournal.line("未捕获异常 \(ex.name.rawValue)：\(ex.reason ?? "无 reason")｜\(frames)")
        }
        return true
    }

    /// 0.1/23 有一趟死在 ② 的分配峰上（`② 内容编码` 之后就没声了）。要知道那是不是 jetsam：
    /// 被系统杀之前通常会先喊这一声，喊了就是水位问题，没喊就是我自己的 bug。
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        VoiceJournal.line("收到内存警告（余量 \(VoiceFacts.headroomMB()) MB）")
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        VoiceJournal.line("系统交付 background 事件：\(identifier)")
        ModelDownload.shared.takeOver(completionHandler)
    }
}
