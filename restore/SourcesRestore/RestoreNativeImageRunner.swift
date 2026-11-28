import Foundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import VideoToolbox

@available(iOS 26.0, *)
enum RestoreNativeImageRunner {
    private static let maximumInputWidth = 1920
    private static let maximumInputHeight = 1080
    private static let overlap = 64

    static func restore(
        source: CGImage,
        outputWidth: Int,
        outputHeight: Int,
        progressEnd: Double = 0.92,
        progress: @escaping @Sendable (Double, String) async -> Void
    ) async throws -> RestorePixelCanvas {
        try Task.checkCancellation()
        let tiles = RestoreNativeMath.tilePlan(
            width: source.width,
            height: source.height,
            maximumWidth: maximumInputWidth,
            maximumHeight: maximumInputHeight,
            overlap: overlap
        )
        guard !tiles.isEmpty else { throw RestoreError.invalidDimensions }
        let canvas = try RestorePixelCanvas(width: outputWidth, height: outputHeight)
        let weights = try RestoreBlendWeights(width: outputWidth, height: outputHeight)
        let context = CIContext(options: [.cacheIntermediates: false])
        var processors: [CGSize: VTFrameProcessor] = [:]
        var configurations: [CGSize: VTSuperResolutionScalerConfiguration] = [:]
        defer { processors.values.forEach { $0.endSession() } }
        RestoreJournal.line("系统 AI 超分：\(source.width)×\(source.height)，\(tiles.count) 块，输出 \(outputWidth)×\(outputHeight)")

        for (index, tile) in tiles.enumerated() {
            try Task.checkCancellation()
            let size = CGSize(width: tile.width, height: tile.height)
            let configuration: VTSuperResolutionScalerConfiguration
            if let existing = configurations[size] {
                configuration = existing
            } else {
                guard let created = makeConfiguration(width: tile.width, height: tile.height) else {
                    throw RestoreError.inferenceFailed("苹果 AI 超分不支持 \(tile.width)×\(tile.height) 的 2× 处理")
                }
                configurations[size] = created
                configuration = created
                try await prepare(configuration, progress: progress)
            }
            let processor: VTFrameProcessor
            if let existing = processors[size] {
                processor = existing
            } else {
                let created = VTFrameProcessor()
                await progress(0.16, "加载苹果图像超分模型")
                do {
                    try created.startSession(configuration: configuration)
                } catch {
                    throw RestoreError.inferenceFailed("苹果图像超分启动失败：\(error.localizedDescription)")
                }
                processors[size] = created
                RestoreJournal.line("系统 AI 超分会话已启动：\(tile.width)×\(tile.height) · \(configuration.configurationModelStatus)")
            }
            let input = try sourceTile(source, tile: tile)
            let output = try await process(processor: processor, configuration: configuration, input: input, context: context)
            try blend(output, tile: tile, sourceWidth: source.width, sourceHeight: source.height, canvas: canvas, weights: weights, factor: configuration.scaleFactor)
            let value = 0.2 + Double(index + 1) / Double(tiles.count) * (progressEnd - 0.2)
            await progress(value, "苹果 AI 超分 \(index + 1)/\(tiles.count) 块")
        }
        return canvas
    }

    private static func makeConfiguration(width: Int, height: Int) -> VTSuperResolutionScalerConfiguration? {
        guard VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(2) else { return nil }
        return VTSuperResolutionScalerConfiguration(
            frameWidth: width,
            frameHeight: height,
            scaleFactor: 2,
            inputType: .image,
            usePrecomputedFlow: false,
            qualityPrioritization: .normal,
            revision: VTSuperResolutionScalerConfiguration.defaultRevision
        )
    }

    private static func prepare(
        _ configuration: VTSuperResolutionScalerConfiguration,
        progress: @escaping @Sendable (Double, String) async -> Void
    ) async throws {
        switch configuration.configurationModelStatus {
        case .ready:
            return
        case .downloadRequired:
            await progress(0.06, "准备下载苹果超分模型")
            async let download: Void = { try await configuration.downloadConfigurationModel() }()
            var reported = false
            while configuration.configurationModelStatus == .downloading || !reported {
                reported = true
                try Task.checkCancellation()
                let percentage = Int(max(0, min(1, configuration.configurationModelPercentageAvailable)) * 100)
                await progress(0.06 + Double(percentage) / 100 * 0.08, "下载苹果超分模型 \(percentage)%")
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            try await download.value
        case .downloading:
            while configuration.configurationModelStatus == .downloading {
                try Task.checkCancellation()
                let percentage = Int(max(0, min(1, configuration.configurationModelPercentageAvailable)) * 100)
                await progress(0.06 + Double(percentage) / 100 * 0.08, "下载苹果超分模型 \(percentage)%")
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        @unknown default:
            throw RestoreError.inferenceFailed("苹果超分模型状态未知")
        }
        guard configuration.configurationModelStatus == .ready else {
            throw RestoreError.inferenceFailed("苹果超分模型尚未就绪")
        }
    }

    private static func process(
        processor: VTFrameProcessor,
        configuration: VTSuperResolutionScalerConfiguration,
        input: CGImage,
        context: CIContext
    ) async throws -> CGImage {
        guard let format = configuration.supportedPixelFormats.contains(kCVPixelFormatType_32BGRA)
            ? kCVPixelFormatType_32BGRA : configuration.supportedPixelFormats.first else {
            throw RestoreError.inferenceFailed("苹果图像超分没有可用像素格式")
        }
        let source = try pixelBuffer(width: input.width, height: input.height, format: format, attributes: configuration.sourcePixelBufferAttributes)
        let destination = try pixelBuffer(
            width: input.width * configuration.scaleFactor,
            height: input.height * configuration.scaleFactor,
            format: format,
            attributes: configuration.destinationPixelBufferAttributes
        )
        try render(input, to: source, context: context)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: .zero),
              let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: .zero),
              let parameters = VTSuperResolutionScalerParameters(
                sourceFrame: sourceFrame,
                previousFrame: nil,
                previousOutputFrame: nil,
                opticalFlow: nil,
                submissionMode: .random,
                destinationFrame: destinationFrame
              ) else {
            throw RestoreError.inferenceFailed("无法创建苹果图像超分参数")
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                processor.process(parameters: parameters) { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch {
            throw RestoreError.inferenceFailed("苹果图像超分推理失败：\(error.localizedDescription)")
        }
        return try image(destination)
    }

    private static func sourceTile(_ source: CGImage, tile: RestoreNativeTile) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: tile.width,
            height: tile.height,
            bitsPerComponent: 8,
            bytesPerRow: tile.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RestoreError.inferenceFailed("无法创建系统超分输入块") }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: tile.width, height: tile.height))
        guard let cropped = source.cropping(to: CGRect(x: tile.originX, y: tile.originY, width: tile.validWidth, height: tile.validHeight)) else {
            throw RestoreError.inferenceFailed("无法裁切系统超分输入块")
        }
        let y = CGFloat(tile.height - tile.validHeight)
        context.draw(cropped, in: CGRect(x: 0, y: y, width: tile.validWidth, height: tile.validHeight))
        let paddingWidth = tile.width - tile.validWidth
        let paddingHeight = tile.height - tile.validHeight
        if paddingWidth > 0, let edge = cropped.cropping(to: CGRect(x: tile.validWidth - 1, y: 0, width: 1, height: tile.validHeight)) {
            context.draw(edge, in: CGRect(x: tile.validWidth, y: y, width: paddingWidth, height: tile.validHeight))
        }
        if paddingHeight > 0, let edge = cropped.cropping(to: CGRect(x: 0, y: tile.validHeight - 1, width: tile.validWidth, height: 1)) {
            context.draw(edge, in: CGRect(x: 0, y: 0, width: tile.validWidth, height: paddingHeight))
        }
        if paddingWidth > 0, paddingHeight > 0,
           let corner = cropped.cropping(to: CGRect(x: tile.validWidth - 1, y: tile.validHeight - 1, width: 1, height: 1)) {
            context.draw(corner, in: CGRect(x: tile.validWidth, y: 0, width: paddingWidth, height: paddingHeight))
        }
        guard let result = context.makeImage() else { throw RestoreError.inferenceFailed("无法读取系统超分输入块") }
        return result
    }

    private static func pixelBuffer(
        width: Int,
        height: Int,
        format: OSType,
        attributes: [String: any Sendable]
    ) throws -> CVPixelBuffer {
        var values = attributes
        values[kCVPixelBufferWidthKey as String] = width
        values[kCVPixelBufferHeightKey as String] = height
        values[kCVPixelBufferPixelFormatTypeKey as String] = NSNumber(value: format)
        values[kCVPixelBufferCGImageCompatibilityKey as String] = true
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, values as CFDictionary, &buffer)
        guard status == noErr, let buffer else {
            throw RestoreError.inferenceFailed("无法分配系统超分像素缓冲（\(status)）")
        }
        return buffer
    }

    private static func render(_ image: CGImage, to buffer: CVPixelBuffer, context: CIContext) throws {
        let status = CVPixelBufferLockBaseAddress(buffer, [])
        guard status == noErr else {
            throw RestoreError.inferenceFailed("无法锁定系统超分输入缓冲（\(status)）")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        context.render(CIImage(cgImage: image), to: buffer)
    }

    private static func image(_ buffer: CVPixelBuffer) throws -> CGImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var result: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(buffer, nil, &result)
        guard status == noErr, let result else {
            throw RestoreError.inferenceFailed("无法读取系统超分结果（\(status)）")
        }
        return result
    }

    private static func blend(
        _ prediction: CGImage,
        tile: RestoreNativeTile,
        sourceWidth: Int,
        sourceHeight: Int,
        canvas: RestorePixelCanvas,
        weights: RestoreBlendWeights,
        factor: Int
    ) throws {
        let cropX = (tile.width - tile.validWidth) * factor
        let cropY = (tile.height - tile.validHeight) * factor
        guard let cropped = prediction.cropping(to: CGRect(
            x: cropX,
            y: cropY,
            width: tile.validWidth * factor,
            height: tile.validHeight * factor
        )) else { throw RestoreError.inferenceFailed("系统超分输出尺寸无效") }
        let scaleX = Double(canvas.width) / Double(sourceWidth)
        let scaleY = Double(canvas.height) / Double(sourceHeight)
        let outputOriginX = Int((Double(tile.originX) * scaleX).rounded(.down))
        let outputOriginY = Int((Double(tile.originY) * scaleY).rounded(.down))
        let outputEndX = Int((Double(tile.originX + tile.validWidth) * scaleX).rounded(.up))
        let outputEndY = Int((Double(tile.originY + tile.validHeight) * scaleY).rounded(.up))
        let scaled = try RestorePixelCanvas(width: max(1, outputEndX - outputOriginX), height: max(1, outputEndY - outputOriginY))
        scaled.context.interpolationQuality = .high
        scaled.context.draw(cropped, in: CGRect(x: 0, y: 0, width: scaled.width, height: scaled.height))
        let destination = canvas.data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let pixels = scaled.data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        for y in 0..<scaled.height {
            let globalY = outputOriginY + y
            guard globalY >= 0, globalY < canvas.height else { continue }
            let vertical = RestoreAIMath.featherWeight(
                pixel: globalY,
                origin: outputOriginY,
                size: scaled.height,
                sourceOrigin: tile.originY,
                sourceSize: tile.validHeight,
                sourceImageSize: sourceHeight,
                halo: Double(max(1, tile.overlapTop)) * scaleY,
                haloRight: Double(max(1, tile.overlapBottom)) * scaleY
            )
            for x in 0..<scaled.width {
                let globalX = outputOriginX + x
                guard globalX >= 0, globalX < canvas.width else { continue }
                let horizontal = RestoreAIMath.featherWeight(
                    pixel: globalX,
                    origin: outputOriginX,
                    size: scaled.width,
                    sourceOrigin: tile.originX,
                    sourceSize: tile.validWidth,
                    sourceImageSize: sourceWidth,
                    halo: Double(max(1, tile.overlapLeft)) * scaleX,
                    haloRight: Double(max(1, tile.overlapRight)) * scaleX
                )
                let alpha = weights.blendWeight(pixelX: globalX, pixelY: globalY, weight: UInt16((min(horizontal, vertical) * 4095).rounded()))
                guard alpha > 0 else { continue }
                let sourceIndex = y * scaled.bytesPerRow + x * 4
                let destinationIndex = globalY * canvas.bytesPerRow + globalX * 4
                for channel in 0..<3 {
                    let value = Double(pixels[sourceIndex + channel]) * alpha + Double(destination[destinationIndex + channel]) * (1 - alpha)
                    destination[destinationIndex + channel] = UInt8(max(0, min(255, value.rounded())))
                }
                destination[destinationIndex + 3] = 255
            }
        }
    }
}
