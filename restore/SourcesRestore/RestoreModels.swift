import Foundation
import CoreGraphics
import AVFoundation
import ImageIO

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

    func settings(scale: Double, superResolutionModel: RestoreModelID = .realESRGAN) -> RestorationSettings {
        switch self {
        case .smart: return RestorationSettings(preset: self, mode: .preferred, superResolutionModel: superResolutionModel, scale: scale, denoise: 0.28, sharpen: 0.52, color: 0.12, restoreFaces: false)
        case .portrait: return RestorationSettings(preset: self, mode: .preferred, superResolutionModel: superResolutionModel, scale: scale, denoise: 0.18, sharpen: 0.30, color: 0.08, restoreFaces: false)
        case .archive: return RestorationSettings(preset: self, mode: .preferred, superResolutionModel: superResolutionModel, scale: scale, denoise: 0.55, sharpen: 0.42, color: 0.34, restoreFaces: false)
        }
    }
}

enum RestoreProcessingMode: String, Codable, CaseIterable, Identifiable {
    case native
    case systemSuperResolution
    case superResolution

    static var preferred: RestoreProcessingMode {
        if #available(iOS 26.0, macOS 26.0, *), RestoreNativeSuperResolution.isSupported {
            return .systemSuperResolution
        }
        return .native
    }

    static func available(_ mode: RestoreProcessingMode, for kind: MediaKind) -> Bool {
        if mode == .systemSuperResolution {
            guard #available(iOS 26.0, macOS 26.0, *) else { return false }
            return RestoreNativeSuperResolution.isSupported
        }
        if mode == .superResolution { return kind == .image }
        return true
    }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .native: return "原生增强"
        case .systemSuperResolution: return "苹果 AI 超分"
        case .superResolution: return "本地 AI 智能超分"
        }
    }
    var subtitle: String {
        switch self {
        case .native: return "无需模型，改善噪点和色彩"
        case .systemSuperResolution: return "系统图像/视频模型恢复细节，不支持时回退内置模型"
        case .superResolution: return "按所选模型生成细节，再按输出上限缩放"
        }
    }
    var systemImage: String {
        switch self {
        case .native: return "slider.horizontal.3"
        case .systemSuperResolution: return "wand.and.sparkles"
        case .superResolution: return "sparkles"
        }
    }
    var maximumOutputLongEdge: Int { self == .superResolution ? 6144 : 4096 }
    var isAI: Bool { self == .superResolution }
    var usesCoreMLFallback: Bool { self == .systemSuperResolution }
}

struct RestorationSettings: Equatable, Codable {
    var preset: RestorePreset = .smart
    var mode: RestoreProcessingMode = .preferred
    var superResolutionModel: RestoreModelID = .realESRGAN
    var scale: Double = 2
    var denoise: Double = 0.28
    var sharpen: Double = 0.52
    var color: Double = 0.12
    var restoreFaces: Bool = false

    var model: RestoreModelID? {
        switch mode {
        case .native, .systemSuperResolution: return nil
        case .superResolution: return superResolutionModel
        }
    }

    var summary: String {
        switch mode {
        case .native:
            let scaleText = scale == scale.rounded() ? String(Int(scale)) : String(format: "%.1f", scale)
            return "\(preset.title) · \(scaleText)× · 降噪 \(Int(denoise * 100))% · 锐化 \(Int(sharpen * 100))%"
        case .systemSuperResolution:
            let scaleText = scale == scale.rounded() ? String(Int(scale)) : String(format: "%.1f", scale)
            return "苹果 AI 超分 · 输出 \(scaleText)×\(restoreFaces ? " · 人脸补全" : "")"
        case .superResolution:
            let scaleText = scale == scale.rounded() ? String(Int(scale)) : String(format: "%.1f", scale)
            let spec = RestoreModelCatalog.spec(for: superResolutionModel)
            let factor = spec?.upscaleFactor.map { "\($0)×" } ?? "多倍"
            return "AI 超分 · \(spec?.name ?? "本地模型") \(factor) · 输出 \(scaleText)×\(restoreFaces ? " · 人脸补全" : "")"
        }
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
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw RestoreError.unreadableImage
        }
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        let swapsDimensions = [3, 4, 7, 8].contains(orientation)
        return ImageGeometry(
            width: swapsDimensions ? height : width,
            height: swapsDimensions ? width : height
        )
    }
}
