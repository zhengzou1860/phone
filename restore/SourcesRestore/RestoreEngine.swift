import Foundation
import CoreImage
import AVFoundation
import UIKit

enum RestoreEngine {
    static func restoreImage(
        from url: URL,
        settings: RestorationSettings,
        maxLongEdge: Int = 4096,
        progress: @escaping @Sendable (Double, String) async -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        await progress(0.08, "读取照片")
        guard let image = UIImage(contentsOfFile: url.path), let cgImage = image.cgImage else {
            throw RestoreError.unreadableImage
        }
        let source = CIImage(cgImage: cgImage)
            .oriented(forExifOrientation: image.imageOrientation.exifOrientation)
        let target = RestoreMath.fittedSize(
            width: Int(source.extent.width),
            height: Int(source.extent.height),
            scale: settings.scale,
            maxLongEdge: maxLongEdge
        )
        guard target.width > 0, target.height > 0 else { throw RestoreError.invalidDimensions }

        await progress(0.28, "降噪与色彩修复")
        let enhanced = enhance(source, settings: settings)
        let output = scaled(enhanced, to: CGSize(width: target.width, height: target.height))

        try Task.checkCancellation()
        await progress(0.72, "生成高清照片")
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let rendered = context.createCGImage(output, from: output.extent) else {
            throw RestoreError.filterFailed("系统无法渲染修复结果")
        }
        guard let data = UIImage(cgImage: rendered, scale: 1, orientation: .up).jpegData(compressionQuality: 0.94) else {
            throw RestoreError.fileOperation("照片编码失败")
        }
        try Task.checkCancellation()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(RestoreMath.timestampName(prefix: "restore", ext: "jpg"))
        try data.write(to: outputURL, options: .atomic)
        await progress(1, "照片修复完成")
        return outputURL
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

        let composition = AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
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
                "CIEdgePreserveUpsampleFilter",
                parameters: ["inputScaleFactor": scale]
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
        var image = source.clampingToExtent()
        if settings.denoise > 0.001 {
            image = image.applyingFilter(
                "CINoiseReduction",
                parameters: [
                    kCIInputNoiseLevelKey: 0.008 + settings.denoise * 0.06,
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
