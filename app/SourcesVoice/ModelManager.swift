import Foundation
import SwiftUI
import Combine

@MainActor
final class ModelManager: ObservableObject {
    @Published var state: State = .checking
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
    private var task: URLSessionDownloadTask?

    var modelDir: URL? {
        if case .downloaded(let url) = state { return url }
        return nil
    }

    func check() {
        let dir = modelDirectory()
        let marker = dir.appendingPathComponent(".ready")
        if FileManager.default.fileExists(atPath: marker.path) {
            state = .downloaded(modelDir: dir)
            progressText = "模型已就绪"
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

        let cfg = URLSessionConfiguration.background(withIdentifier: "voice.model.\(UUID().uuidString)")
        cfg.timeoutIntervalForResource = 3600       // 整个下载允许 1 小时
        cfg.isDiscretionary = false                 // 立刻开始，不等到 WiFi+充电
        cfg.sessionSendsLaunchEvents = true

        let bridge = DownloadBridge()
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
                case .success(let localURL):
                    self.handleDownloaded(localURL)
                case .failure(let err):
                    self.state = .failed("下载失败: \(err.localizedDescription)")
                }
            }
        }

        let session = URLSession(configuration: cfg, delegate: bridge, delegateQueue: nil)
        let t = session.downloadTask(with: url)
        t.resume()
        self.task = t
    }

    private func handleDownloaded(_ tmp: URL) {
        let dir = modelDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(Self.zipName)
        try? FileManager.default.removeItem(at: dest)
        do {
            // background session 的临时文件在 caches 里，move 到 Documents
            try FileManager.default.moveItem(at: tmp, to: dest)
            let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            if bytes < 1_000_000 {
                state = .failed("下载文件过小 \(bytes) 字节，可能是 GitHub 重定向页")
                return
            }
            let marker = dir.appendingPathComponent(".ready")
            try? Data("ok".utf8).write(to: marker)
            progress = 1.0
            state = .downloaded(modelDir: dir)
            progressText = "模型已下载 \(bytes / 1_048_576) MB（解压待集成）"
        } catch {
            state = .failed("落盘失败: \(error.localizedDescription)")
        }
    }

    private func modelDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("voice_models")
    }
}

/// 单独一个类做 delegate，避免 ModelManager 里的 @MainActor 与 URLSession 回调线程冲突
private final class DownloadBridge: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Int64, Int64) -> Void)?
    var onFinish: ((Result<URL, Error>) -> Void)?

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        onFinish?(.success(location))
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
