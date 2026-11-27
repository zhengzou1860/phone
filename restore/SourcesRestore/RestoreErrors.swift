import Foundation

enum RestoreError: LocalizedError {
    case cancelled
    case unreadableImage
    case missingVideoTrack
    case invalidDimensions
    case filterFailed(String)
    case exportFailed(String)
    case photoPermissionDenied
    case modelNotInstalled
    case modelLoadFailed(String)
    case inferenceFailed(String)
    case fileOperation(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "已停止处理"
        case .unreadableImage: return "无法读取这张照片"
        case .missingVideoTrack: return "视频里没有可处理的画面"
        case .invalidDimensions: return "照片或视频尺寸无效"
        case .filterFailed(let message): return "画面处理失败：\(message)"
        case .exportFailed(let message): return "视频导出失败：\(message)"
        case .photoPermissionDenied: return "没有相册写入权限，请在系统设置中允许"
        case .modelNotInstalled: return "AI 模型尚未下载，请先在「设置 → AI 模型」中下载"
        case .modelLoadFailed(let message): return "AI 模型加载失败：\(message)"
        case .inferenceFailed(let message): return "AI 推理失败：\(message)"
        case .fileOperation(let message): return message
        }
    }
}

enum RestorePreflightError: LocalizedError {
    case invalidDimensions
    case invalidDuration
    case videoTooLong
    case resolutionTooLarge(isVideo: Bool)
    case insufficientSpace(required: Int64, available: Int64)
    case aiSourceTooLarge
    case aiOutputTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            return "图片或视频尺寸无效"
        case .invalidDuration:
            return "无法确认视频时长，请重新选择"
        case .videoTooLong:
            return "视频超过 15 分钟，请先分段再导入"
        case .resolutionTooLarge(let isVideo):
            return isVideo ? "视频超过 4K 或 12MP 限制，请先降低分辨率或分段处理" : "照片分辨率过大，请先缩小后再导入"
        case .insufficientSpace(let required, let available):
            return "可用空间不足：预计需要 \(RestoreMath.formatBytes(Int(required)))，当前只有 \(RestoreMath.formatBytes(Int(available)))"
        case .aiSourceTooLarge:
            return "AI 修复支持最长边 8192 px、最多 40MP 的原片；当前照片请先缩小"
        case .aiOutputTooLarge:
            return "AI 超分输出超过 32MP，请降低放大倍数"
        }
    }
}
