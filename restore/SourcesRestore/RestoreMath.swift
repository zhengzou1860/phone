import Foundation

struct RestoreMath {
    static func evenSize(width: Int, height: Int) -> (width: Int, height: Int) {
        (max(2, width & ~1), max(2, height & ~1))
    }

    static func fittedSize(width: Int, height: Int, scale: Double, maxLongEdge: Int) -> (width: Int, height: Int) {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        let sourceLong = max(safeWidth, safeHeight)
        let capScale = Double(maxLongEdge) / Double(sourceLong)
        let actualScale = min(max(1, scale), capScale)
        let result = evenSize(
            width: Int((Double(safeWidth) * actualScale).rounded()),
            height: Int((Double(safeHeight) * actualScale).rounded())
        )
        let correctedLong = max(result.width, result.height)
        if correctedLong <= maxLongEdge || sourceLong == 0 { return result }
        let ratio = Double(maxLongEdge) / Double(correctedLong)
        return evenSize(
            width: Int((Double(result.width) * ratio).rounded()),
            height: Int((Double(result.height) * ratio).rounded())
        )
    }

    static func actualScale(width: Int, height: Int, requested: Double, maxLongEdge: Int) -> Double {
        let size = fittedSize(width: width, height: height, scale: requested, maxLongEdge: maxLongEdge)
        return Double(max(size.width, size.height)) / Double(max(width, height, 1))
    }

    static func estimatedMemoryMB(width: Int, height: Int) -> Double {
        Double(max(0, width) * max(0, height) * 8) / 1_048_576
    }

    static func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func timestampName(prefix: String, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(prefix)_\(formatter.string(from: Date())).\(ext)"
    }
}

enum RestorePreflight {
    static let maximumVideoDuration: TimeInterval = 15 * 60
    static let maximumVideoLongEdge = 4096
    static let maximumVideoPixels = 12_000_000
    static let maximumImageLongEdge = 16_384
    static let maximumImagePixels = 100_000_000
    static let safetyBytes: Int64 = 512 * 1024 * 1024

    static func validate(width: Int, height: Int, duration: Double, isVideo: Bool) throws {
        guard width > 0, height > 0 else { throw RestorePreflightError.invalidDimensions }
        let longEdge = max(width, height)
        let pixels = Double(width) * Double(height)
        if isVideo {
            guard duration.isFinite, duration > 0 else { throw RestorePreflightError.invalidDuration }
            guard duration <= maximumVideoDuration else { throw RestorePreflightError.videoTooLong }
            guard longEdge <= maximumVideoLongEdge, pixels <= Double(maximumVideoPixels) else {
                throw RestorePreflightError.resolutionTooLarge(isVideo: true)
            }
        } else if longEdge > maximumImageLongEdge || pixels > Double(maximumImagePixels) {
            throw RestorePreflightError.resolutionTooLarge(isVideo: false)
        }
    }

    static func estimatedOutputBytes(
        sourceBytes: Int64,
        sourceWidth: Int,
        sourceHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> Int64 {
        let sourcePixels = Double(max(1, sourceWidth)) * Double(max(1, sourceHeight))
        let outputPixels = Double(max(1, outputWidth)) * Double(max(1, outputHeight))
        let pixelRatio = outputPixels / sourcePixels
        let estimate = ceil(Double(max(1, sourceBytes)) * pixelRatio * 1.25)
        let maximum = Int64.max / 2
        guard estimate.isFinite, estimate < Double(maximum) else { return maximum }
        return Int64(estimate)
    }

    static func requiredImportBytes(sourceBytes: Int64) -> Int64 {
        withSafetyMargin(max(0, sourceBytes))
    }

    static func requiredExportBytes(
        sourceBytes: Int64,
        sourceWidth: Int,
        sourceHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> Int64 {
        withSafetyMargin(estimatedOutputBytes(
            sourceBytes: sourceBytes,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight
        ))
    }

    static func validateSpace(required: Int64, available: Int64) throws {
        guard available >= required else { throw RestorePreflightError.insufficientSpace(required: required, available: available) }
    }

    private static func withSafetyMargin(_ bytes: Int64) -> Int64 {
        let maximum = Int64.max - safetyBytes
        return bytes > maximum ? Int64.max : bytes + safetyBytes
    }
}
