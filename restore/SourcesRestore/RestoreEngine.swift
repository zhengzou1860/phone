import Foundation
import CoreImage
import ImageIO
import AVFoundation
import UIKit

enum RestoreEngine {
    static func restoreImage(
        from url: URL,
        settings: RestorationSettings,
        modelURL: URL? = nil,
        faceModelURL: URL? = nil,
        maxLongEdge: Int = 4096,
        progress: @escaping @Sendable (Double, String) async -> Void
    ) async throws -> URL {
        if settings.mode.isAI {
            return try await restoreAIImage(from: url, settings: settings, modelURL: modelURL, faceModelURL: faceModelURL, maxLongEdge: maxLongEdge, progress: progress)
        }
        RestoreJournal.line("照片处理：读取原片")
        try Task.checkCancellation()
        await progress(0.08, "读取照片")
        guard let image = UIImage(contentsOfFile: url.path), let cgImage = image.cgImage else {
            throw RestoreError.unreadableImage
        }
        let source = CIImage(cgImage: cgImage)
            .oriented(forExifOrientation: Int32(image.imageOrientation.exifOrientation.rawValue))
        let target = RestoreMath.fittedSize(
            width: Int(source.extent.width),
            height: Int(source.extent.height),
            scale: settings.scale,
            maxLongEdge: maxLongEdge
        )
        guard target.width > 0, target.height > 0 else { throw RestoreError.invalidDimensions }
        RestoreJournal.line("照片处理：原片 \(Int(source.extent.width))×\(Int(source.extent.height))，目标 \(target.width)×\(target.height)")

        await progress(0.28, "降噪与色彩修复")
        RestoreJournal.line("照片处理：应用降噪、色彩和锐化")
        let enhanced = enhance(source, settings: settings)
        RestoreJournal.line("照片处理：缩放图像")
        let output = scaled(enhanced, to: CGSize(width: target.width, height: target.height))

        try Task.checkCancellation()
        await progress(0.72, "生成高清照片")
        RestoreJournal.line("照片处理：CPU 渲染")
        let context = CIContext(options: [
            .cacheIntermediates: false,
            .useSoftwareRenderer: true
        ])
        guard let rendered = context.createCGImage(
            output,
            from: output.extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else {
            throw RestoreError.filterFailed("系统无法渲染修复结果")
        }
        RestoreJournal.line("照片处理：渲染完成，编码 JPEG")
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw RestoreError.fileOperation("照片编码失败")
        }
        CGImageDestinationAddImage(destination, rendered, [
            kCGImageDestinationLossyCompressionQuality: 0.94
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RestoreError.fileOperation("照片编码失败")
        }
        RestoreJournal.line("照片处理：JPEG 编码完成 \(data.length) 字节")
        try Task.checkCancellation()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(RestoreMath.timestampName(prefix: "restore", ext: "jpg"))
        try (data as Data).write(to: outputURL, options: Data.WritingOptions.atomic)
        RestoreJournal.line("照片处理：结果已写入临时文件")
        await progress(1, "照片修复完成")
        return outputURL
    }

    private static func restoreAIImage(
        from url: URL,
        settings: RestorationSettings,
        modelURL: URL?,
        faceModelURL: URL?,
        maxLongEdge: Int,
        progress: @escaping @Sendable (Double, String) async -> Void
    ) async throws -> URL {
        guard let modelURL else { throw RestoreError.modelNotInstalled }
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw RestoreError.modelNotInstalled }
        let geometry = try RestoreInferenceCore.geometry(url)
        try RestoreAIMath.validateSource(width: geometry.width, height: geometry.height)
        let target = RestoreMath.fittedSize(
            width: geometry.width,
            height: geometry.height,
            scale: settings.scale,
            maxLongEdge: maxLongEdge
        )
        try RestoreAIMath.validateOutput(width: target.width, height: target.height, isSuperResolution: settings.mode == .superResolution)
        try Task.checkCancellation()
        await progress(0.06, "加载本地 AI 模型")
        guard let spec = settings.model.flatMap({ RestoreModelCatalog.spec(for: $0) }) else { throw RestoreError.modelNotInstalled }
        RestoreJournal.line("照片 AI 处理：\(settings.mode.rawValue)，模型 \(spec.name) \(spec.technicalSummary)")
        switch settings.mode {
        case .superResolution:
            if settings.restoreFaces && faceModelURL == nil { throw RestoreError.modelNotInstalled }
            return try await RestoreSuperResolutionRunner.run(
                from: url,
                modelURL: modelURL,
                spec: spec,
                faceModelURL: settings.restoreFaces ? faceModelURL : nil,
                restoreFaces: settings.restoreFaces,
                outputWidth: target.width,
                outputHeight: target.height,
                progress: progress
            )
        case .inpainting:
            guard let mask = settings.mask, !mask.isEmpty else { throw RestoreError.emptyMask }
            return try await RestoreInpaintingRunner.run(
                from: url,
                modelURL: modelURL,
                spec: spec,
                mask: mask,
                outputWidth: target.width,
                outputHeight: target.height,
                progress: progress
            )
        case .native:
            throw RestoreError.fileOperation("修复模式无效")
        }
    }

    static func restoreVideo(
        from url: URL,
        settings: RestorationSettings,
        maxLongEdge: Int = 3840,
        progress: @escaping @Sendable (Double, String) async -> Void,
        sessionHandler: @escaping @Sendable (AVAssetExportSession) async -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        await progress(0.02, "读取视频轨道")
        let asset = AVURLAsset(url: url)
        let geometry = try await VideoGeometry.load(url)
        let target = RestoreMath.fittedSize(
            width: geometry.width,
            height: geometry.height,
            scale: settings.scale,
            maxLongEdge: maxLongEdge
        )
        guard target.width >= 2, target.height >= 2 else { throw RestoreError.invalidDimensions }

        let composition = AVMutableVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            let source = request.sourceImage.transformed(by: CGAffineTransform(
                translationX: -request.sourceImage.extent.minX,
                y: -request.sourceImage.extent.minY
            ))
            let enhanced = enhance(source, settings: settings)
            let output = scaled(enhanced, to: CGSize(width: target.width, height: target.height))
            request.finish(with: output, context: nil)
        })
        composition.renderSize = CGSize(width: target.width, height: target.height)
        composition.frameDuration = geometry.frameDuration

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(RestoreMath.timestampName(prefix: "restore", ext: "mov"))
        try? FileManager.default.removeItem(at: outputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw RestoreError.exportFailed("当前设备不支持此视频格式")
        }
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = true
        await sessionHandler(session)
        await progress(0.05, "逐帧修复中")
        session.exportAsynchronously {
            // AVAssetExportSession posts completion through the polling loop below.
        }
        while session.status == .waiting || session.status == .exporting {
            try Task.checkCancellation()
            let value = min(0.98, 0.05 + Double(session.progress) * 0.93)
            await progress(value, "逐帧修复 \(Int(session.progress * 100))%")
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try Task.checkCancellation()
        guard session.status == .completed else {
            let reason = session.error?.localizedDescription ?? "状态 \(session.status.rawValue)"
            throw RestoreError.exportFailed(reason)
        }
        await progress(1, "视频修复完成")
        return outputURL
    }

    private static func scaled(_ source: CIImage, to size: CGSize) -> CIImage {
        let extent = source.extent
        let scale = min(size.width / max(1, extent.width), size.height / max(1, extent.height))
        let target = CGRect(origin: .zero, size: size)
        if scale > 1.01 {
            let filtered = source.applyingFilter(
                "CILanczosScaleTransform",
                parameters: ["inputScale": scale, "inputAspectRatio": 1.0]
            )
            let normalized = filtered.transformed(by: CGAffineTransform(
                translationX: -filtered.extent.minX,
                y: -filtered.extent.minY
            ))
            let residual = min(size.width / max(1, normalized.extent.width), size.height / max(1, normalized.extent.height))
            return normalized
                .transformed(by: CGAffineTransform(scaleX: residual, y: residual))
                .cropped(to: target)
        }
        return source
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: target)
    }

    private static func enhance(_ source: CIImage, settings: RestorationSettings) -> CIImage {
        let originalExtent = source.extent
        var image = source.clampedToExtent()
        if settings.denoise > 0.001 {
            image = image.applyingFilter(
                "CINoiseReduction",
                parameters: [
                    "inputNoiseLevel": 0.008 + settings.denoise * 0.06,
                    kCIInputSharpnessKey: settings.sharpen * 0.3
                ]
            )
        }
        if settings.color > 0.001 {
            image = image.applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputSaturationKey: 1 + settings.color * 0.45,
                    kCIInputContrastKey: 1 + settings.color * 0.12,
                    kCIInputBrightnessKey: settings.color * 0.02
                ]
            )
        }
        if settings.sharpen > 0.001 {
            image = image.applyingFilter(
                "CIUnsharpMask",
                parameters: [
                    kCIInputRadiusKey: 1.2,
                    kCIInputIntensityKey: settings.sharpen * 1.6
                ]
            )
        }
        return image.cropped(to: originalExtent)
    }
}

private extension UIImage.Orientation {
    var exifOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
