import Foundation
import AVFoundation
import SwiftUI

@MainActor
final class RestoreProcessor: ObservableObject {
    @Published private(set) var isProcessing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var phase = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var completedAsset: RestoredAsset?

    private let store: RestoreStore
    private var workTask: Task<Void, Never>?
    private var exportSession: AVAssetExportSession?

    init(store: RestoreStore) {
        self.store = store
    }

    func start(media: ImportedMedia, settings: RestorationSettings) {
        guard !isProcessing else { return }
        isProcessing = true
        progress = 0
        phase = "准备处理"
        errorMessage = nil
        completedAsset = nil
        UIApplication.shared.isIdleTimerDisabled = true

        workTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var temporaryOutput: URL?
            do {
                if media.kind == .image {
                    temporaryOutput = try await RestoreEngine.restoreImage(
                        from: media.url,
                        settings: settings,
                        progress: { [weak self] value, text in
                            await MainActor.run {
                                self?.progress = value
                                self?.phase = text
                            }
                        }
                    )
                }
                if media.kind == .video {
                    temporaryOutput = try await RestoreEngine.restoreVideo(
                        from: media.url,
                        settings: settings,
                        progress: { [weak self] value, text in
                            await MainActor.run {
                                self?.progress = value
                                self?.phase = text
                            }
                        },
                        sessionHandler: { [weak self] session in
                            await MainActor.run { self?.exportSession = session }
                        }
                    )
                }
                guard let temporaryOutput else { throw RestoreError.fileOperation("没有生成结果文件") }
                let maxEdge = media.kind == .image ? 4096 : 3840
                let output = RestoreMath.fittedSize(
                    width: media.width,
                    height: media.height,
                    scale: settings.scale,
                    maxLongEdge: maxEdge
                )
                let actualScale = RestoreMath.actualScale(
                    width: media.width,
                    height: media.height,
                    requested: settings.scale,
                    maxLongEdge: maxEdge
                )
                let extensionName = media.kind == .image ? "jpg" : "mov"
                let filename = try await self.store.persistResult(
                    from: temporaryOutput,
                    id: media.id,
                    ext: extensionName
                )
                let bytes = (try? FileManager.default.attributesOfItem(
                    atPath: self.store.resultURL(filename: filename).path
                )[.size] as? Int) ?? 0
                let record = RestoredAsset(
                    id: media.id,
                    kindRaw: media.kind.rawValue,
                    title: media.displayName,
                    sourceFilename: media.url.lastPathComponent,
                    resultFilename: filename,
                    createdAt: Date(),
                    summary: "\(settings.summary) · 实际 \(String(format: "%.2f", actualScale))×",
                    sourceWidth: media.width,
                    sourceHeight: media.height,
                    outputWidth: output.width,
                    outputHeight: output.height,
                    duration: media.duration,
                    resultBytes: bytes
                )
                await self.finish(record: record)
            } catch {
                if let temporaryOutput { try? FileManager.default.removeItem(at: temporaryOutput) }
                await self.finish(error: error)
            }
        }
    }

    func cancel() {
        workTask?.cancel()
        exportSession?.cancelExport()
        phase = "正在停止"
    }

    func clearError() {
        errorMessage = nil
    }

    private func finish(record: RestoredAsset) {
        isProcessing = false
        progress = 1
        phase = "修复完成"
        exportSession = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if store.register(record) {
            completedAsset = record
        } else {
            try? FileManager.default.removeItem(at: store.resultURL(for: record))
            errorMessage = "结果已生成，但历史记录写入失败"
        }
    }

    private func finish(error: Error) {
        isProcessing = false
        exportSession = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if Task.isCancelled || error is CancellationError {
            phase = "已停止"
            return
        }
        if let restoreError = error as? RestoreError, case .cancelled = restoreError {
            phase = "已停止"
            return
        }
        errorMessage = error.localizedDescription
    }
}
