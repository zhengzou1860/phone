import Foundation
import UIKit
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
        let dir = Self.modelDirectory()
        let fm = FileManager.default
        // 就绪的硬证据 = 校验过的标记 + 具体某个 onnx。旧版 .ready 不算，
        // 因为上一包 11/13 张图 ORT 连加载都过不了，只看"文件在不在"会把死包当就绪。
        let probe = dir.appendingPathComponent("dit_state_0.onnx")
        let marker = dir.appendingPathComponent(ModelManifest.marker)
        let zip = dir.appendingPathComponent(Self.zipName)
        VoiceJournal.line("check() dir=\(dir.path)")
        if fm.fileExists(atPath: probe.path), fm.fileExists(atPath: marker.path) {
            state = .downloaded(modelDir: dir)
            progressText = "模型已就绪（\(ModelManifest.parseCount(dir)) 个文件已逐条校验）"
            return
        }
        if fm.fileExists(atPath: zip.path) {
            startUnpack(zip: zip, dir: dir)
            return
        }
        if fm.fileExists(atPath: probe.path) {
            startVerify(dir: dir)
            return
        }
        state = .notDownloaded
    }

    /// 解压 + 校验都在后台线程：700 MB 的 inflate 放主线程会被系统当卡死杀掉。
    private func startUnpack(zip: URL, dir: URL) {
        state = .downloading
        progress = 0
        progressText = "解压中…（约 700 MB，别切走）"
        VoiceJournal.line("后台解压 \(zip.lastPathComponent)")
        Task.detached(priority: .userInitiated) {
            do {
                try ZipExtractor.extractAll(zipURL: zip, to: dir)
            } catch {
                await MainActor.run {
                    VoiceJournal.line("解压失败 \(error.localizedDescription)")
                    self.state = .failed("解压失败: \(error.localizedDescription)")
                }
                return
            }
            await self.finishVerify(dir: dir, zip: zip, stage: "解压后")
        }
    }

    private func startVerify(dir: URL) {
        state = .downloading
        progress = 1.0
        progressText = "校验模型完整性…"
        VoiceJournal.line("后台校验已有模型目录")
        Task { await self.finishVerify(dir: dir, zip: nil, stage: "校验") }
    }

    /// 校验通过就落 .verified-<version> 标记并删 zip；不过就删干净整个目录 ——
    /// 留着只会让每次 onAppear 再验一遍 700 MB。
    private func finishVerify(dir: URL, zip: URL?, stage: String) async {
        progressText = "\(stage)并校验中…（这步约 30~60 s）"
        let reason = await Task.detached(priority: .userInitiated) { () -> String? in
            ModelManifest.verify(dir: dir) { i, n, name in
                Task { @MainActor in
                    self.progress = Double(i) / Double(max(n, 1))
                    self.progressText = "\(stage)并校验 \(i)/\(n) \(name)"
                }
            }
        }.value
        if let reason = reason {
            VoiceJournal.line("模型校验不通过：\(reason)")
            let n = await Task.detached { ModelManifest.purge(dir: dir) }.value
            state = .failed("模型包不完整：\(reason)")
            progressText = "已清掉坏包（\(n) 项），需要重新下载"
            return
        }
        try? Data(ModelManifest.version.utf8)
            .write(to: dir.appendingPathComponent(ModelManifest.marker))
        if let zip = zip { try? FileManager.default.removeItem(at: zip) }
        VoiceJournal.line("模型校验通过（\(stage)），zip 已删")
        state = .downloaded(modelDir: dir)
        progress = 1.0
        progressText = "模型就绪（\(ModelManifest.parseCount(dir)) 个文件已逐条校验）"
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

        let d = ModelDownload.shared
        d.onProgress = { [weak self] received, total in
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
        d.onFinish = { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                switch result {
                case .success(let payload):
                    VoiceJournal.line("下载完成 \(payload.bytes / 1_048_576) MB → \(payload.url.lastPathComponent)")
                    // 解压这件 700 MB 的活不在后台干：系统给被拉起的那点时间根本不够 inflate 完，
                    // 半截文件反而要把整包重下。zip 已经在磁盘上了，回前台 check() 自己会接上。
                    if UIApplication.shared.applicationState != .active {
                        VoiceJournal.line("在后台下完的，解压等回前台")
                        self.progressText = "下载完成（回前台自动解压）"
                        return
                    }
                    self.handleDownloaded(destURL: payload.url)
                case .failure(let err):
                    let ns = err as NSError
                    VoiceJournal.line("下载失败 domain=\(ns.domain) code=\(ns.code) \(err.localizedDescription)")
                    self.state = .failed("下载失败(\(ns.code)): \(err.localizedDescription)")
                }
            }
        }
        d.start(url: url)
    }

    private func handleDownloaded(destURL: URL) {
        VoiceJournal.line("zip 已落盘 → 交给后台解压校验")
        startUnpack(zip: destURL, dir: Self.modelDirectory())
    }

    static func modelDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("voice_models")
    }
}
