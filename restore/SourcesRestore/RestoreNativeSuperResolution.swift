import Foundation
import VideoToolbox

@available(iOS 26.0, macOS 26.0, *)
enum RestoreNativeSuperResolution {
    static var isSupported: Bool { VTSuperResolutionScalerConfiguration.isSupported }

    static var statusSummary: String {
        let scales = VTSuperResolutionScalerConfiguration.supportedScaleFactors
            .map(String.init)
            .sorted()
            .joined(separator: "/")
        let lowLatency = VTLowLatencySuperResolutionScalerConfiguration.isSupported
        return "高质量=\(isSupported) · 低延迟=\(lowLatency) · 高质量倍率=\(scales.isEmpty ? "未知" : scales)"
    }
}
