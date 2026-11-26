import Foundation
import CoreGraphics
import AVFoundation
import UIKit

enum MediaKind: String, Codable, CaseIterable, Identifiable {
    case image
    case video

    var id: String { rawValue }
    var title: String { self == .image ? "照片" : "视频" }
    var systemName: String { self == .image ? "photo.on.rectangle" : "video.fill" }
}

enum RestorePreset: String, Codable, CaseIterable, Identifiable {
    case smart
    case portrait
    case archive

    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: return "智能清晰"
        case .portrait: return "人像柔护"
        case .archive: return "老照片"
        }
    }

    var subtitle: String {
        switch self {
        case .smart: return "适度降噪，增强边缘"
        case .portrait: return "轻锐化，保留自然肤色"
        case .archive: return "提亮暗部，恢复色彩"
        }
    }

    func settings(scale: Double) -> RestorationSettings {
        switch self {
        case .smart: return RestorationSettings(preset: self, scale: scale, denoise: 0.28, sharpen: 0.52, color: 0.12)
        case .portrait: return RestorationSettings(preset: self, scale: scale, denoise: 0.18, sharpen: 0.30, color: 0.08)
        case .archive: return RestorationSettings(preset: self, scale: scale, denoise: 0.55, sharpen: 0.42, color: 0.34)
        }
    }
}

struct RestorationSettings: Equatable {
    var preset: RestorePreset = .smart
    var scale: Double = 2
    var denoise: Double = 0.28
    var sharpen: Double = 0.52
    var color: Double = 0.12

    var summary: String {
        let scaleText = scale == scale.rounded() ? String(Int(scale)) : String(format: "%.1f", scale)
        return "\(preset.title) · \(scaleText)× · 降噪 \(Int(denoise * 100))% · 锐化 \(Int(sharpen * 100))%"
    }
}

struct ImportedMedia: Identifiable {
    let id: UUID
    let url: URL
    let kind: MediaKind
    let originalName: String
    let byteCount: Int
    let width: Int
    let height: Int
    let duration: Double

    var displayName: String {
        let base = (originalName as NSString).deletingPathExtension
        return base.isEmpty ? url.lastPathComponent : base
    }
}

struct RestoredAsset: Identifiable, Codable {
    let id: UUID
    let kindRaw: String
    let title: String
    let sourceFilename: String
    let resultFilename: String
    let createdAt: Date
    let summary: String
    let sourceWidth: Int
    let sourceHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let duration: Double
    let resultBytes: Int

    var kind: MediaKind { kindRaw == MediaKind.video.rawValue ? .video : .image }

    enum CodingKeys: String, CodingKey {
        case id, kindRaw, title, createdAt, summary, duration
        case sourceFilename, resultFilename, sourceWidth, sourceHeight
        case outputWidth, outputHeight, resultBytes
    }
}

enum RestoreError: LocalizedError {
    case cancelled
    case unreadableImage
    case missingVideoTrack
    case invalidDimensions
    case filterFailed(String)
    case exportFailed(String)
    case photoPermissionDenied
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
        case .fileOperation(let message): return message
        }
    }
}

struct VideoGeometry {
    let width: Int
    let height: Int
    let duration: Double
    let frameDuration: CMTime

    static func load(_ url: URL) async throws -> VideoGeometry {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw RestoreError.missingVideoTrack }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let frameDuration = try await track.load(.minFrameDuration)
        let nominal = try await track.load(.nominalFrameRate)
        let upright = natural.applying(transform)
        let width = Int(abs(upright.width).rounded())
        let height = Int(abs(upright.height).rounded())
        let validFrame = CMTimeCompare(frameDuration, .invalid) != 0 && frameDuration > .zero
        let fallbackFrames = nominal > 0 ? nominal : 30
        return VideoGeometry(
            width: width,
            height: height,
            duration: max(0, CMTimeGetSeconds(duration)),
            frameDuration: validFrame ? frameDuration : CMTime(value: 1, timescale: Int32(fallbackFrames.rounded()))
        )
    }
}

struct ImageGeometry {
    let width: Int
    let height: Int

    static func load(_ url: URL) throws -> ImageGeometry {
        guard let image = UIImage(contentsOfFile: url.path), let cgImage = image.cgImage else {
            throw RestoreError.unreadableImage
        }
        switch image.imageOrientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            return ImageGeometry(width: cgImage.height, height: cgImage.width)
        default:
            return ImageGeometry(width: cgImage.width, height: cgImage.height)
        }
    }
}
