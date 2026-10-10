import Foundation
import SwiftUI
import Combine

@MainActor
final class ModelManager: ObservableObject {
    @Published var state: State = .checking {
        didSet { VoiceJournal.line("state→\(describe(state))") }
    }
    @Published var progress: Double = 0
    @Published var progressText: String = ""

    enum State {
        case checking
        case notDownloaded
        case downloading
        case downloaded(modelDir: URL)
        case failed(String)
    }

    static let releaseTag = "voice-models"
    static let zipName = "models-fp16.zip"
    static let repo = "zhengzou1860/phone"
    static let downloadURL = "https://github.com/\(repo)/releases/download/\(releaseTag)/\(zipName)"

    private var bridge: DownloadBridge?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    var modelDir: URL? {
        if case .downloaded(let url) = state { return url }
        return nil
    }

    private func describe(_ s: State) -> String {
        switch s {
        case .checking: return "checking"
        case .notDownloaded: return "notDownloaded"
        case .downloading: return "downloading \(Int(progress * 100))%"
        case .downloaded: return "downloaded"
        case .failed(let m): return "failed: \(m)"
        }
    }

    func check() {
        let dir = modelDirectory()
        let marker = dir.appendingPathComponent(".ready")
        let zip = dir.appendingPathComponent(Self.zipName)
        // 真就绪的信号 = 至少解出一个具体 onnx，别信旧版 .ready
        let probe = dir.appendingPathComponent("dit_state_0.onnx")
        VoiceJournal.line("check() dir=\(dir.path)")
        if FileManager.default.fileExists(atPath: probe.path) {
            state = .downloaded(modelDir: dir)
            progressText = "模型已就绪"
        } else if FileManager.default.fileExists(atPath: zip.path) {
            // 有 zip 没 onnx ⇒ 上次下载完但解压失败/中断/被旧版跳过 ⇒ 本地续解
            state = .downloading
            progress = 1.0
            progressText = "重新解压已下载的 zip…"
            VoiceJournal.line("本地续解 \(Self.zipName)")
            do {
                try ZipExtractor.extractAll(zipURL: zip, to: dir)
                try? Data("ok".utf8).write(to: marker)
                try? FileManager.default.removeItem(at: zip)
                state = .downloaded(modelDir: dir)
                progressText = "模型就绪（本地 zip 已解出）"
            } catch {
                state = .failed("解压失败: \(error.localizedDescription)")
            }
        } else {
            state = .notDownloaded
        }
    }

    func download() {
        guard case .notDownloaded = state else { return }
        guard let url = URL(string: Self.downloadURL) else {
            state = .failed("URL 非法")
            return
        }

        state = .downloading
        progress = 0
        progressText = "正在连接 GitHub…"
        VoiceJournal.line("开始下载 \(Self.downloadURL)")

        // background session 的 identifier 必须固定，不能用 UUID——挂了/被系统回收后再开
        // 找不到同 id 的 session 就丢进度。
        let cfg = URLSessionConfiguration.background(withIdentifier: "voice.model.main")
        cfg.timeoutIntervalForResource = 3600
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true

        let bridge = DownloadBridge(destDir: modelDirectory(), zipName: Self.zipName)
        self.bridge = bridge
        bridge.onProgress = { [weak self] received, total in
            Task { @MainActor in
                guard let self = self else { return }
                if total > 0 {
                    self.progress = Double(received) / Double(total)
                    self.progressText = "下载中 \(received / 1_048_576) / \(total / 1_048_576) MB"
                } else {
                    self.progressText = "下载中 \(received / 1_048_576) MB"
                }
            }
        }
        bridge.onFinish = { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                switch result {
                case .success(let payload):
                    VoiceJournal.line("下载完成 \(payload.bytes / 1_048_576) MB → \(payload.url.lastPathComponent)")
                    self.handleDownloaded(destURL: payload.url, bytes: payload.bytes)
                case .failure(let err):
                    let ns = err as NSError
                    VoiceJournal.line("下载失败 domain=\(ns.domain) code=\(ns.code) \(err.localizedDescription)")
                    self.state = .failed("下载失败(\(ns.code)): \(err.localizedDescription)")
                }
            }
        }

        let session = URLSession(configuration: cfg, delegate: bridge, delegateQueue: nil)
        self.session = session
        let t = session.downloadTask(with: url)
        t.resume()
        self.task = t
    }

    private func handleDownloaded(destURL: URL, bytes: Int64) {
        let dir = modelDirectory()
        progress = 1.0
        progressText = "解压中…"
        VoiceJournal.line("开始解压")
        do {
            try ZipExtractor.extractAll(zipURL: destURL, to: dir)
            let marker = dir.appendingPathComponent(".ready")
            try? Data("ok".utf8).write(to: marker)
            try? FileManager.default.removeItem(at: destURL)
            state = .downloaded(modelDir: dir)
            progressText = "模型就绪（\(bytes / 1_048_576) MB zip 已解出）"
            VoiceJournal.line("解压完成，zip 已删")
        } catch {
            VoiceJournal.line("解压失败 \(error.localizedDescription)")
            state = .failed("解压失败: \(error.localizedDescription)")
        }
    }

    private func modelDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("voice_models")
    }
}

/// 单独一个类做 delegate，避免 @MainActor 与 URLSession 回调线程冲突。
/// 关键：didFinishDownloadingTo 里的临时 location **在方法返回后 iOS 会立刻删掉**，
/// 必须在这个回调里同步 move 到 Documents，别交给 MainActor Task 排队。
private final class DownloadBridge: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Int64, Int64) -> Void)?
    var onFinish: ((Result<DownloadedPayload, Error>) -> Void)?

    struct DownloadedPayload {
        let url: URL
        let bytes: Int64
    }

    private let destDir: URL
    private let zipName: String

    init(destDir: URL, zipName: String) {
        self.destDir = destDir
        self.zipName = zipName
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let dest = destDir.appendingPathComponent(zipName)
            try? FileManager.default.removeItem(at: dest)
            // 优先 copy 再删（move 跨 volume 会失败），Documents 和 tmp 同 volume 但保险起见
            try FileManager.default.copyItem(at: location, to: dest)
            try? FileManager.default.removeItem(at: location)
            let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            onFinish?(.success(DownloadedPayload(url: dest, bytes: bytes)))
        } catch {
            onFinish?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let err = error {
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
