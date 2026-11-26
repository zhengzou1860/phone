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
