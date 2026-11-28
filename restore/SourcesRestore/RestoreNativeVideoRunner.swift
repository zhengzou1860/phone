import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import VideoToolbox

@available(iOS 26.0, *)
enum RestoreNativeVideoRunner {
    private static let maximumInputWidth = 1440
    private static let maximumInputHeight = 1080
    private static let scaleFactor = 2

    static func restore(
        from url: URL,
        outputWidth: Int,
        outputHeight: Int,
        progress: @escaping @Sendable (Double, String) async -> Void,
        onStarted: @escaping @Sendable (@escaping @Sendable () -> Void) async -> Void
    ) async throws -> URL {
        let state = CancellationState()
        do {
            return try await withTaskCancellationHandler {
                try await run(
                    from: url,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight,
                    progress: progress,
                    onStarted: onStarted,
                    state: state
                )
            } onCancel: {
                state.cancel()
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                RestoreJournal.line("系统 AI 视频超分已停止")
            } else {
                RestoreJournal.line("系统 AI 视频超分失败：\(error.localizedDescription)")
            }
            throw error
        }
    }

    private static func run(
        from url: URL,
        outputWidth: Int,
        outputHeight: Int,
        progress: @escaping @Sendable (Double, String) async -> Void,
        onStarted: @escaping @Sendable (@escaping @Sendable () -> Void) async -> Void,
        state: CancellationState
    ) async throws -> URL {
        try Task.checkCancellation()
        guard outputWidth > 0, outputHeight > 0 else {
            throw RestoreError.exportFailed("输出视频尺寸无效")
        }
        await progress(0, "读取视频轨道")
        let asset = AVURLAsset(url: url)
        let geometry: VideoGeometry
        do {
            geometry = try await VideoGeometry.load(url)
        } catch {
            try state.checkCancellation()
            throw exportError("无法读取视频信息", error)
        }
        guard geometry.width > 0, geometry.height > 0 else {
            throw RestoreError.exportFailed("视频画面尺寸无效")
        }
        let videoTracks: [AVAssetTrack]
        let videoTrack: AVAssetTrack
        let audioTracks: [AVAssetTrack]
        let preferredTransform: CGAffineTransform
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = videoTracks.first else {
                throw RestoreError.exportFailed("视频里没有可处理的画面")
            }
            videoTrack = track
            preferredTransform = try await videoTrack.load(.preferredTransform)
        } catch {
            try state.checkCancellation()
            throw exportError("无法读取视频或音频轨道", error)
        }
        let inputSize = fittedSize(
            from: CGSize(width: geometry.width, height: geometry.height),
            to: CGSize(width: maximumInputWidth, height: maximumInputHeight)
        )
        let inputWidth = max(1, Int(inputSize.width))
        let inputHeight = max(1, Int(inputSize.height))
        let outputSize = CGSize(width: outputWidth, height: outputHeight)

        guard VTSuperResolutionScalerConfiguration.isSupported,
              VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(scaleFactor),
              let configuration = VTSuperResolutionScalerConfiguration(
                frameWidth: inputWidth,
                frameHeight: inputHeight,
                scaleFactor: scaleFactor,
                inputType: .video,
                usePrecomputedFlow: false,
                qualityPrioritization: .normal,
                revision: VTSuperResolutionScalerConfiguration.defaultRevision
              ),
              !configuration.supportedPixelFormats.isEmpty else {
            throw RestoreError.inferenceFailed("当前设备不支持 \(inputWidth)×\(inputHeight) 的苹果视频超分")
        }
        let sourceFormat = preferredPixelFormat(configuration.supportedPixelFormats)
        let destinationFormat = preferredPixelFormat(configuration.supportedPixelFormats)
        try await prepare(configuration, progress: progress)
        try state.checkCancellation()

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            RestoreMath.timestampName(prefix: "native_video_\(UUID().uuidString.prefix(8))", ext: "mov")
        )
        try? FileManager.default.removeItem(at: outputURL)
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: outputURL) }
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw exportError("无法创建视频读取器", error)
        }
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        guard reader.canAdd(videoOutput) else {
            throw RestoreError.exportFailed("无法读取 BGRA 视频帧")
        }
        reader.add(videoOutput)

        let audioOutput: AVAssetReaderTrackOutput?
        let audioInput: AVAssetWriterInput?
        if let audioTrack = audioTracks.first {
            let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            guard reader.canAdd(readerOutput) else {
                throw RestoreError.exportFailed("无法读取原始音频")
            }
            reader.add(readerOutput)
            audioOutput = readerOutput
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        } else {
            audioOutput = nil
            audioInput = nil
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let frameRate = geometry.frameDuration.value > 0
            ? Double(geometry.frameDuration.timescale) / Double(geometry.frameDuration.value)
            : 30
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                "Codec": AVVideoCodecType.hevc,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: estimatedBitRate(width: outputWidth, height: outputHeight, frameRate: frameRate),
                    AVVideoExpectedSourceFrameRateKey: frameRate
                ]
            ]
        )
        videoInput.transform = CGAffineTransform.identity
        guard writer.canAdd(videoInput) else {
            throw RestoreError.exportFailed("无法创建视频输出轨道")
        }
        writer.add(videoInput)
        if let audioInput {
            guard writer.canAdd(audioInput) else {
                throw RestoreError.exportFailed("无法创建原始音频输出轨道")
            }
            writer.add(audioInput)
        }
        state.install(reader: reader, writer: writer)
        await onStarted { state.cancel() }
        try state.checkCancellation()

        let processor = VTFrameProcessor()
        var sessionStarted = false
        defer {
            if sessionStarted { processor.endSession() }
            reader.cancelReading()
            if !completed { writer.cancelWriting() }
        }
        do {
            try writer.startWriting()
            writer.startSession(atSourceTime: .zero)
        } catch {
            throw exportError("无法开始写入视频", error)
        }
        do {
            try processor.startSession(configuration: configuration)
            sessionStarted = true
        } catch {
            throw inferenceError("苹果视频超分会话启动失败", error)
        }
        guard reader.startReading() else {
            throw exportError("无法开始读取视频", reader.error)
        }
        RestoreJournal.line(
            "系统 AI 视频超分：原片 \(geometry.width)×\(geometry.height)，原生输入 \(inputWidth)×\(inputHeight)，输出 \(outputWidth)×\(outputHeight)，音频 \(audioOutput == nil ? "无" : "透传")"
        )
        await progress(0.08, "苹果 AI 视频超分已启动")

        let context = CIContext(options: [.cacheIntermediates: false])
        let estimatedFrameCount = max(0, geometry.duration) * frameRate
        guard estimatedFrameCount.isFinite, estimatedFrameCount < Double(Int.max) else {
            throw RestoreError.exportFailed("视频时长或帧率无效")
        }
        let estimatedFrames = max(1, Int(estimatedFrameCount.rounded(.up)))
        var previousFrame: VTFrameProcessorFrame?
        var previousOutputFrame: VTFrameProcessorFrame?
        var pendingAudio: CMSampleBuffer?
        var processedFrames = 0

        while reader.status == .reading {
            try state.checkCancellation()
            if let sampleBuffer = videoOutput.copyNextSampleBuffer() {
                let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let inputBuffer = try nativeInputBuffer(
                    from: sampleBuffer,
                    width: inputWidth,
                    height: inputHeight,
                    geometry: geometry,
                    preferredTransform: preferredTransform,
                    format: sourceFormat,
                    attributes: configuration.sourcePixelBufferAttributes,
                    context: context
                )
                let result = try await process(
                    processor: processor,
                    configuration: configuration,
                    input: inputBuffer,
                    presentationTimeStamp: presentationTimeStamp,
                    previousFrame: previousFrame,
                    previousOutputFrame: previousOutputFrame,
                    destinationFormat: destinationFormat,
                    state: state
                )
                let writerSample = try writerSampleBuffer(
                    from: result.output,
                    source: sampleBuffer,
                    outputSize: outputSize,
                    context: context
                )
                try await append(writerSample, to: videoInput, writer: writer, state: state)
                try await appendAudio(
                    through: presentationTimeStamp,
                    output: audioOutput,
                    input: audioInput,
                    writer: writer,
                    state: state,
                    pending: &pendingAudio
                )
                previousFrame = result.sourceFrame
                previousOutputFrame = result.outputFrame
                processedFrames += 1
                let value = min(0.98, 0.08 + Double(processedFrames) / Double(estimatedFrames) * 0.90)
                await progress(value, "苹果 AI 超分 \(processedFrames)/\(estimatedFrames) 帧")
            } else {
                try await appendAudio(
                    through: nil,
                    output: audioOutput,
                    input: audioInput,
                    writer: writer,
                    state: state,
                    pending: &pendingAudio
                )
                switch reader.status {
                case .completed:
                    break
                case .failed:
                    throw exportError("视频读取失败", reader.error)
                case .cancelled:
                    throw CancellationError()
                default:
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
            }
        }
        guard reader.status == .completed else {
            if reader.status == .failed { throw exportError("视频读取失败", reader.error) }
            throw CancellationError()
        }
        try state.checkCancellation()
        try await appendAudio(
            through: nil,
            output: audioOutput,
            input: audioInput,
            writer: writer,
            state: state,
            pending: &pendingAudio
        )
        guard processedFrames > 0 else {
            throw RestoreError.exportFailed("没有解码到可处理的视频帧")
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        try state.checkCancellation()
        guard writer.status == .completed else {
            if writer.status == .cancelled { throw CancellationError() }
            throw exportError("视频导出未完成", writer.error)
        }
        await progress(1, "视频修复完成")
        try state.checkCancellation()
        completed = true
        return outputURL
    }

    private static func prepare(
        _ configuration: VTSuperResolutionScalerConfiguration,
        progress: @escaping @Sendable (Double, String) async -> Void
    ) async throws {
        switch configuration.configurationModelStatus {
        case .ready:
            return
        case .downloadRequired:
            await progress(0.01, "准备下载苹果视频超分模型")
            async let download: Void = configuration.downloadConfigurationModel()
            var reported = false
            while configuration.configurationModelStatus == .downloading || !reported {
                reported = true
                try Task.checkCancellation()
                await reportDownload(configuration, progress: progress)
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            do {
                try await download
            } catch {
                try Task.checkCancellation()
                throw inferenceError("苹果视频超分模型下载失败", error)
            }
        case .downloading:
            while configuration.configurationModelStatus == .downloading {
                try Task.checkCancellation()
                await reportDownload(configuration, progress: progress)
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        @unknown default:
            throw RestoreError.inferenceFailed("苹果视频超分模型状态未知")
        }
        guard configuration.configurationModelStatus == .ready else {
            throw RestoreError.inferenceFailed("苹果视频超分模型尚未就绪")
        }
    }

    private static func reportDownload(
        _ configuration: VTSuperResolutionScalerConfiguration,
        progress: @escaping @Sendable (Double, String) async -> Void
    ) async {
        let fraction = max(0, min(1, configuration.configurationModelPercentageAvailable))
        let percentage = Int((fraction * 100).rounded(.down))
        await progress(0.01 + Double(percentage) / 100 * 0.05, "下载苹果视频超分模型 \(percentage)%")
    }

    private static func process(
        processor: VTFrameProcessor,
        configuration: VTSuperResolutionScalerConfiguration,
        input: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        previousFrame: VTFrameProcessorFrame?,
        previousOutputFrame: VTFrameProcessorFrame?,
        destinationFormat: OSType,
        state: CancellationState
    ) async throws -> (sourceFrame: VTFrameProcessorFrame, output: CVPixelBuffer, outputFrame: VTFrameProcessorFrame) {
        try state.checkCancellation()
        let destination = try pixelBuffer(
            width: configuration.frameWidth * scaleFactor,
            height: configuration.frameHeight * scaleFactor,
            format: destinationFormat,
            attributes: configuration.destinationPixelBufferAttributes,
            forExport: false
        )
        guard let sourceFrame = VTFrameProcessorFrame(buffer: input, presentationTimeStamp: presentationTimeStamp),
              let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: presentationTimeStamp),
              let parameters = VTSuperResolutionScalerParameters(
                sourceFrame: sourceFrame,
                previousFrame: previousFrame,
                previousOutputFrame: previousOutputFrame,
                opticalFlow: nil,
                submissionMode: previousFrame == nil ? .random : .sequential,
                destinationFrame: destinationFrame
              ) else {
            throw RestoreError.inferenceFailed("无法创建苹果视频超分帧参数")
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                processor.process(parameters: parameters, completionHandler: { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        } catch {
            try state.checkCancellation()
            throw inferenceError("苹果视频超分逐帧处理失败", error)
        }
        try state.checkCancellation()
        return (sourceFrame, destination, destinationFrame)
    }

    private static func nativeInputBuffer(
        from sampleBuffer: CMSampleBuffer,
        width: Int,
        height: Int,
        geometry: VideoGeometry,
        preferredTransform: CGAffineTransform,
        format: OSType,
        attributes: [String: any Sendable],
        context: CIContext
    ) throws -> CVPixelBuffer {
        guard let decoded = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw RestoreError.exportFailed("视频帧没有图像缓冲")
        }
        let status = CVPixelBufferLockBaseAddress(decoded, .readOnly)
        guard status == noErr else {
            throw RestoreError.exportFailed("无法读取视频像素缓冲（\(status)）")
        }
        defer { CVPixelBufferUnlockBaseAddress(decoded, .readOnly) }
        let source = CIImage(cvPixelBuffer: decoded)
        let transformed = source.transformed(by: preferredTransform)
        let normalized = transformed.transformed(by: CGAffineTransform(
            translationX: -transformed.extent.minX,
            y: -transformed.extent.minY
        )).cropped(to: CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height))
        let input = try pixelBuffer(width: width, height: height, format: format, attributes: attributes, forExport: false)
        try render(aspectFit(normalized, in: CGSize(width: width, height: height)), to: input, context: context, forExport: false)
        return input
    }

    private static func writerSampleBuffer(
        from nativeOutput: CVPixelBuffer,
        source: CMSampleBuffer,
        outputSize: CGSize,
        context: CIContext
    ) throws -> CMSampleBuffer {
        let output = try pixelBuffer(
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            format: kCVPixelFormatType_32BGRA,
            attributes: nil,
            forExport: true
        )
        let status = CVPixelBufferLockBaseAddress(nativeOutput, .readOnly)
        guard status == noErr else {
            throw RestoreError.inferenceFailed("无法读取超分结果（\(status)）")
        }
        defer { CVPixelBufferUnlockBaseAddress(nativeOutput, .readOnly) }
        try render(
            aspectFit(CIImage(cvPixelBuffer: nativeOutput), in: outputSize),
            to: output,
            context: context,
            forExport: true
        )
        var formatDescription: CMFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: output,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw RestoreError.exportFailed("无法创建输出帧格式（\(formatStatus)）")
        }
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(source),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: output,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw RestoreError.exportFailed("无法创建输出视频帧（\(sampleStatus)）")
        }
        return sampleBuffer
    }

    private static func aspectFit(_ image: CIImage, in size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite else {
            return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        }
        let scale = min(size.width / extent.width, size.height / extent.height)
        var scaled = image
        if abs(scale - 1) > 0.0001 {
            scaled = image.applyingFilter(
                "CILanczosScaleTransform",
                parameters: ["inputScale": scale, "inputAspectRatio": 1.0]
            )
        }
        let fittedSize = CGSize(width: extent.width * scale, height: extent.height * scale)
        let normalized = scaled
            .cropped(to: CGRect(origin: scaled.extent.origin, size: fittedSize))
            .transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
            .transformed(by: CGAffineTransform(
                translationX: (size.width - fittedSize.width) / 2,
                y: (size.height - fittedSize.height) / 2
            ))
        let canvas = CGRect(origin: .zero, size: size)
        return CIImage(color: .black).cropped(to: canvas).composited(over: normalized.cropped(to: canvas))
    }

    private static func render(
        _ image: CIImage,
        to buffer: CVPixelBuffer,
        context: CIContext,
        forExport: Bool
    ) throws {
        let status = CVPixelBufferLockBaseAddress(buffer, [])
        guard status == noErr else {
            let message = "无法锁定\(forExport ? "输出" : "超分")像素缓冲（\(status)）"
            if forExport { throw RestoreError.exportFailed(message) }
            throw RestoreError.inferenceFailed(message)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        context.render(image, to: buffer)
    }

    private static func append(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput,
        writer: AVAssetWriter,
        state: CancellationState
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try state.checkCancellation()
            guard writer.status == .writing else {
                throw exportError("视频输出轨道不可用", writer.error)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try state.checkCancellation()
        guard input.append(sampleBuffer) else {
            throw exportError("无法追加媒体样本", writer.error)
        }
    }

    private static func appendAudio(
        through deadline: CMTime?,
        output: AVAssetReaderTrackOutput?,
        input: AVAssetWriterInput?,
        writer: AVAssetWriter,
        state: CancellationState,
        pending: inout CMSampleBuffer?
    ) async throws {
        guard let output, let input else {
            pending = nil
            return
        }
        while true {
            try state.checkCancellation()
            let sampleBuffer: CMSampleBuffer?
            if let queued = pending {
                sampleBuffer = queued
                pending = nil
            } else {
                sampleBuffer = output.copyNextSampleBuffer()
            }
            guard let sampleBuffer else { return }
            if let deadline, CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), deadline) > 0 {
                pending = sampleBuffer
                return
            }
            try await append(sampleBuffer, to: input, writer: writer, state: state)
        }
    }

    private static func fittedSize(from source: CGSize, to limit: CGSize) -> CGSize {
        let scale = min(1, min(limit.width / source.width, limit.height / source.height))
        return CGSize(
            width: max(1, (source.width * scale).rounded(.down)),
            height: max(1, (source.height * scale).rounded(.down))
        )
    }

    private static func preferredPixelFormat(_ formats: [OSType]) -> OSType {
        formats.contains(kCVPixelFormatType_32BGRA) ? kCVPixelFormatType_32BGRA : formats[0]
    }

    private static func pixelBuffer(
        width: Int,
        height: Int,
        format: OSType,
        attributes: [String: any Sendable]?,
        forExport: Bool
    ) throws -> CVPixelBuffer {
        var values = attributes ?? [:]
        values[kCVPixelBufferWidthKey as String] = width
        values[kCVPixelBufferHeightKey as String] = height
        values[kCVPixelBufferPixelFormatTypeKey as String] = NSNumber(value: format)
        values[kCVPixelBufferCGImageCompatibilityKey as String] = true
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, values as CFDictionary, &buffer)
        guard status == noErr, let buffer else {
            let message = "无法分配\(forExport ? "输出" : "超分")像素缓冲（\(status)）"
            if forExport { throw RestoreError.exportFailed(message) }
            throw RestoreError.inferenceFailed(message)
        }
        return buffer
    }

    private static func estimatedBitRate(width: Int, height: Int, frameRate: Double) -> Int {
        let bitsPerSecond = Double(width) * Double(height) * max(1, frameRate) * 0.15
        guard bitsPerSecond < Double(40_000_000) else { return 40_000_000 }
        return max(4_000_000, Int(bitsPerSecond))
    }

    private static func exportError(_ message: String, _ error: Error?) -> RestoreError {
        RestoreError.exportFailed(error.map { "\(message)：\($0.localizedDescription)" } ?? message)
    }

    private static func inferenceError(_ message: String, _ error: Error) -> RestoreError {
        RestoreError.inferenceFailed("\(message)：\(error.localizedDescription)")
    }

    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false
        private var reader: AVAssetReader?
        private var writer: AVAssetWriter?

        func install(reader: AVAssetReader, writer: AVAssetWriter) {
            lock.lock()
            self.reader = reader
            self.writer = writer
            let cancelled = isCancelled
            lock.unlock()
            if cancelled {
                reader.cancelReading()
                writer.cancelWriting()
            }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let reader = reader
            let writer = writer
            lock.unlock()
            reader?.cancelReading()
            writer?.cancelWriting()
        }

        func checkCancellation() throws {
            try Task.checkCancellation()
            lock.lock()
            let cancelled = isCancelled
            lock.unlock()
            if cancelled { throw CancellationError() }
        }
    }
}
