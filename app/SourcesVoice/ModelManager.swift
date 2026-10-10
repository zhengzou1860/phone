import Foundation
import SwiftUI

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
        state = .downloading
        progress = 0
        progressText = "正在连接 GitHub…"

        let urlStr = "https://github.com/\(Self.repo)/releases/download/\(Self.releaseTag)/\(Self.zipName)"
        guard let url = URL(string: urlStr) else {
            state = .failed("URL 非法: \(urlStr)")
            return
        }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let error = error {
                    self.state = .failed("下载失败: \(error.localizedDescription)")
                    return
                }
                guard let data = data, !data.isEmpty else {
                    self.state = .failed("下载返回空数据")
                    return
                }
                self.progressText = "下载完成 \(data.count / 1_048_576) MB，正在解压…"
                self.progress = 1.0
                self.extract(data: data)
            }
        }
        task.resume()

        observeProgress(task)
    }

    private func observeProgress(_ task: URLSessionDataTask) {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let received = task.countOfBytesReceived
            let total = task.countOfBytesExpectedToReceive
            if total > 0 {
                Task { @MainActor in
                    self.progress = Double(received) / Double(total)
                    self.progressText = "下载中 \(received / 1_048_576) / \(total / 1_048_576) MB"
                }
            }
            if task.state == .completed { timer.invalidate() }
        }
    }

    private func extract(data: Data) {
        let dir = modelDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmpZip = FileManager.default.temporaryDirectory.appendingPathComponent(Self.zipName)
        do {
            try data.write(to: tmpZip)
            try extractZip(zipURL: tmpZip, to: dir)
            try? FileManager.default.removeItem(at: tmpZip)

            let marker = dir.appendingPathComponent(".ready")
            try? Data("ok".utf8).write(to: marker)

            state = .downloaded(modelDir: dir)
            progressText = "模型就绪"
        } catch {
            state = .failed("解压失败: \(error.localizedDescription)")
        }
    }

    private func extractZip(zipURL: URL, to dir: URL) throws {
        #if canImport(UIKit)
        // iOS 没有 unzip 命令，用 NSTask 也不行
        // 用 CoreFoundation 的 zip 或者自己解析
        // 简单方案：用 `ditto` 命令（iOS 上有）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, dir.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "zip", code: Int(process.terminationStatus))
        }
        #endif
    }

    private func modelDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("voice_models")
    }
}
