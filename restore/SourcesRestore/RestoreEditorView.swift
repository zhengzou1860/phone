import SwiftUI

struct RestoreEditorView: View {
    let media: ImportedMedia
    @ObservedObject var processor: RestoreProcessor

    @Environment(\.dismiss) private var dismiss
    @State private var settings = RestorePreset.smart.settings(scale: 2)
    @State private var showAdvanced = false
    @State private var availableBytes: Int64?

    private var maxEdge: Int { media.kind == .image ? 4096 : 3840 }
    private var output: (width: Int, height: Int) {
        RestoreMath.fittedSize(width: media.width, height: media.height, scale: settings.scale, maxLongEdge: maxEdge)
    }
    private var estimatedOutputBytes: Int64 {
        RestorePreflight.estimatedOutputBytes(
            sourceBytes: Int64(media.byteCount),
            sourceWidth: media.width,
            sourceHeight: media.height,
            outputWidth: output.width,
            outputHeight: output.height
        )
    }
    private var requiredBytes: Int64 {
        RestorePreflight.requiredExportBytes(
            sourceBytes: Int64(media.byteCount),
            sourceWidth: media.width,
            sourceHeight: media.height,
            outputWidth: output.width,
            outputHeight: output.height
        )
    }
    private var hasInsufficientSpace: Bool {
        availableBytes.map { $0 < requiredBytes } ?? false
    }
    private var actualScale: Double {
        RestoreMath.actualScale(width: media.width, height: media.height, requested: settings.scale, maxLongEdge: maxEdge)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceSection
                    presetSection
                    scaleSection
                    outputSection
                    advancedSection
                    disclosure
                    startButton
                }
                .padding(18)
                .padding(.bottom, 30)
            }
            .background(RestoreTheme.background.ignoresSafeArea())
            .navigationTitle(media.kind == .image ? "修复照片" : "修复视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        processor.cancel()
                        dismiss()
                    }
                    .disabled(processor.isProcessing)
                }
            }
            .interactiveDismissDisabled(processor.isProcessing)
            .overlay {
                if processor.isProcessing {
                    ProcessingOverlay(progress: processor.progress, phase: processor.phase) {
                        processor.cancel()
                    }
                }
            }
            .alert("处理失败", isPresented: Binding(
                get: { processor.errorMessage != nil },
                set: { if !$0 { processor.clearError() } }
            )) {
                Button("知道了", role: .cancel) { processor.clearError() }
            } message: {
                Text(processor.errorMessage ?? "")
            }
        }
        .tint(RestoreTheme.cyan)
        .task(id: settings.scale) {
            let values = try? media.url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            availableBytes = values?.volumeAvailableCapacityForImportantUsage
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RestoreMediaPreview(kind: media.kind, url: media.url)
                .frame(height: media.kind == .image ? 310 : 220)
            HStack {
                Text(media.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(media.kind == .image
                     ? "\(media.width) × \(media.height)"
                     : "\(media.width) × \(media.height) · \(String(format: "%.1f", media.duration)) 秒")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RestoreTheme.secondary)
            }
            if media.kind == .video {
                Text("限长 15 分钟 · 最高 4K · 流式逐帧处理")
                    .font(.caption2)
                    .foregroundStyle(RestoreTheme.secondary)
            }
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("修复风格").font(.headline)
            HStack(spacing: 9) {
                ForEach(RestorePreset.allCases) { preset in
                    Button {
                        settings = preset.settings(scale: settings.scale)
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Image(systemName: icon(for: preset))
                                    .font(.headline)
                                Spacer()
                                if settings.preset == preset {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(RestoreTheme.cyan)
                                }
                            }
                            Text(preset.title)
                                .font(.caption.weight(.bold))
                                .lineLimit(1)
                            Text(preset.subtitle)
                                .font(.caption2)
                                .foregroundStyle(RestoreTheme.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .foregroundStyle(.white)
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                        .background(
                            settings.preset == preset ? RestoreTheme.cyan.opacity(0.12) : RestoreTheme.card,
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(settings.preset == preset ? RestoreTheme.cyan.opacity(0.52) : RestoreTheme.stroke)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var scaleSection: some View {
        RestoreCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("输出尺寸").font(.subheadline.weight(.bold))
                    Spacer()
                    Text("实际 \(String(format: "%.2f", actualScale))×")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(RestoreTheme.cyan)
                }
                Picker("放大倍数", selection: $settings.scale) {
                    Text("原尺寸").tag(1.0)
                    Text("1.5×").tag(1.5)
                    Text("2×").tag(2.0)
                }
                .pickerStyle(.segmented)
                Text("\(media.width) × \(media.height)  →  \(output.width) × \(output.height)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RestoreTheme.secondary)
            }
        }
    }

    private var outputSection: some View {
        RestoreCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("长边上限 \(maxEdge) px", systemImage: "memorychip")
                    Spacer()
                    Label("估算 \(String(format: "%.0f", RestoreMath.estimatedMemoryMB(width: output.width, height: output.height))) MB", systemImage: "internaldrive")
                }
                HStack {
                    Text("预计输出 \(RestoreMath.formatBytes(Int(estimatedOutputBytes)))")
                    Spacer()
                    Text("需可用 \(RestoreMath.formatBytes(Int(requiredBytes)))")
                }
                HStack {
                    Text(availableBytes.map { "当前可用 \(RestoreMath.formatBytes(Int($0)))" } ?? "正在检查可用空间…")
                    Spacer()
                    if hasInsufficientSpace {
                        Label("空间不足", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Text("按原片体积和像素比估算，已预留 512 MB 安全空间。")
                    .font(.caption2)
                    .foregroundStyle(RestoreTheme.secondary)
            }
            .font(.caption2)
            .foregroundStyle(RestoreTheme.secondary)
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(spacing: 16) {
                slider(title: "降噪", value: $settings.denoise, left: "保留纹理", right: "更干净")
                slider(title: "锐化", value: $settings.sharpen, left: "自然", right: "更清晰")
                slider(title: "色彩", value: $settings.color, left: "原色", right: "更鲜明")
            }
            .padding(.top, 16)
        } label: {
            HStack {
                Image(systemName: "slider.horizontal.3")
                Text("高级调整")
                Spacer()
                Text(settings.summary)
                    .font(.caption2).foregroundStyle(RestoreTheme.secondary)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
        }
        .tint(RestoreTheme.cyan)
        .padding(16)
        .background(RestoreTheme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func slider(title: String, value: Binding<Double>, left: String, right: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%").font(.caption.monospacedDigit()).foregroundStyle(RestoreTheme.secondary)
            }
            Slider(value: value, in: 0...1)
            HStack {
                Text(left).font(.caption2)
                Spacer()
                Text(right).font(.caption2)
            }
            .foregroundStyle(RestoreTheme.secondary)
        }
    }

    private var disclosure: some View {
        Label {
            Text("本版本使用系统原生降噪、色彩、锐化和边缘保留放大。它可以改善观感，但不能凭空恢复已经丢失的细节；视频处理速度取决于时长和分辨率。")
                .font(.caption)
                .foregroundStyle(RestoreTheme.secondary)
        } icon: {
            Image(systemName: "info.circle").foregroundStyle(RestoreTheme.cyan)
        }
        .padding(.horizontal, 4)
    }

    private var startButton: some View {
        Button {
            processor.start(media: media, settings: settings)
        } label: {
            HStack {
                Image(systemName: "sparkles")
                Text(media.kind == .image ? "开始修复照片" : "开始修复视频")
                Spacer()
                Image(systemName: "arrow.right")
            }
            .font(.headline)
            .foregroundStyle(.black)
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .background(
                LinearGradient(colors: [RestoreTheme.cyan, RestoreTheme.violet], startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .disabled(processor.isProcessing || hasInsufficientSpace)
    }

    private func icon(for preset: RestorePreset) -> String {
        switch preset {
        case .smart: return "sparkles"
        case .portrait: return "person.crop.circle"
        case .archive: return "camera.filters"
        }
    }
}
