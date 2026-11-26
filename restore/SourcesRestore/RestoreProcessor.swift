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
    private let models: RestoreModelManager
    private var workTask: Task<Void, Never>?
    private var exportSession: AVAssetExportSession?

    init(store: RestoreStore, models: RestoreModelManager) {
        self.store = store
        self.models = models
    }

    func start(media: ImportedMedia, settings: RestorationSettings) {
        guard !isProcessing else { return }
        var modelURL: URL?
        do {
            try RestorePreflight.validate(width: media.width, height: media.height, duration: media.duration, isVideo: media.kind == .video)
            if settings.mode.isAI {
                guard media.kind == .image, let id = settings.mode.model else {
                    throw RestoreError.fileOperation("当前 AI 模型仅支持照片")
                }
                try RestoreAIMath.validateSource(width: media.width, height: media.height)
                modelURL = try models.modelURL(for: id)
                if settings.mode == .inpainting {
                    guard let mask = settings.mask, !mask.isEmpty else { throw RestoreError.emptyMask }
                }
            }
            let preliminaryOutput = outputSize(for: media, settings: settings)
            if settings.mode.isAI {
                try RestoreAIMath.validateOutput(width: preliminaryOutput.width, height: preliminaryOutput.height, isSuperResolution: settings.mode == .superResolution)
            }
            guard FileManager.default.fileExists(atPath: media.url.path) else {
                throw RestoreError.fileOperation("要处理的原片已不存在")
            }
            let values = try media.url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            guard let available = values.volumeAvailableCapacityForImportantUsage else {
                throw RestoreError.fileOperation("无法读取可用空间")
            }
            let output = outputSize(for: media, settings: settings)
            let required = RestorePreflight.requiredExportBytes(
                sourceBytes: Int64(media.byteCount),
                sourceWidth: media.width,
                sourceHeight: media.height,
                outputWidth: output.width,
                outputHeight: output.height
            )
            try RestorePreflight.validateSpace(required: required, available: available)
            RestoreJournal.line("处理预检通过：预计需要 \(RestoreMath.formatBytes(Int(required))) 可用空间，当前 \(RestoreMath.formatBytes(Int(available)))")
        } catch {
            errorMessage = error.localizedDescription
            phase = "预检未通过"
            RestoreJournal.line("处理预检失败：\(error.localizedDescription)")
            return
        }
        isProcessing = true
        progress = 0
        phase = "准备处理"
        errorMessage = nil
        completedAsset = nil
        UIApplication.shared.isIdleTimerDisabled = true
        RestoreJournal.line("开始处理：\(media.kind.rawValue) \(media.width)×\(media.height) \(settings.summary)")

        workTask = Task.detached(priority: .userInitiated) { [weak self, modelURL] in
            guard let self else { return }
            var temporaryOutput: URL?
            do {
                if media.kind == .image {
                    temporaryOutput = try await RestoreEngine.restoreImage(
                        from: media.url,
                        settings: settings,
                        modelURL: modelURL,
                        maxLongEdge: settings.mode.maximumOutputLongEdge,
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
                let output = outputSize(for: media, settings: settings)
                let maxEdge = media.kind == .image ? settings.mode.maximumOutputLongEdge : 3840
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
                let resultPath = await self.store.resultURL(filename: filename).path
                let bytes = (try? FileManager.default.attributesOfItem(atPath: resultPath)[.size] as? Int) ?? 0
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

    nonisolated private func outputSize(for media: ImportedMedia, settings: RestorationSettings) -> (width: Int, height: Int) {
        RestoreMath.fittedSize(
            width: media.width,
            height: media.height,
            scale: settings.scale,
            maxLongEdge: media.kind == .image ? settings.mode.maximumOutputLongEdge : 3840
        )
    }

    func cancel() {
        workTask?.cancel()
        exportSession?.cancelExport()
        phase = "正在停止"
        RestoreJournal.line("用户停止处理")
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
            RestoreJournal.line("处理完成：\(record.kind.rawValue) 输出 \(record.outputWidth)×\(record.outputHeight) \(record.resultBytes) 字节")
        } else {
            try? FileManager.default.removeItem(at: store.resultURL(for: record))
            errorMessage = "结果已生成，但历史记录写入失败"
            RestoreJournal.line("处理完成但历史记录写入失败")
        }
    }

    private func finish(error: Error) {
        isProcessing = false
        exportSession = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if Task.isCancelled || error is CancellationError {
            phase = "已停止"
            RestoreJournal.line("处理已停止")
            return
        }
        if let restoreError = error as? RestoreError, case .cancelled = restoreError {
            phase = "已停止"
            RestoreJournal.line("处理已停止")
            return
        }
        errorMessage = error.localizedDescription
        RestoreJournal.line("处理失败：\(error.localizedDescription)")
    }
}
