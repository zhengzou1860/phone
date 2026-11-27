import SwiftUI
import UIKit

struct RestoreEditorView: View {
    let media: ImportedMedia
    @ObservedObject var processor: RestoreProcessor
    @EnvironmentObject private var models: RestoreModelManager

    @Environment(\.dismiss) private var dismiss
    @State private var settings = RestorePreset.smart.settings(scale: 2)
    @State private var showAdvanced = false
    @State private var availableBytes: Int64?
    @State private var isCheckingSpace = false
    @State private var spaceCheckFailed = false

    private var maxEdge: Int { media.kind == .image ? settings.mode.maximumOutputLongEdge : 3840 }
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
    private var canStart: Bool {
        guard !processor.isProcessing, !isCheckingSpace, !hasInsufficientSpace, !spaceCheckFailed else { return false }
        guard !settings.mode.isAI else {
            guard let id = settings.model, models.isInstalled(id),
                  media.width <= RestoreAIMath.maximumSourceLongEdge,
                  Double(media.width) * Double(media.height) <= Double(RestoreAIMath.maximumSourcePixels) else { return false }
            if settings.mode == .superResolution, settings.restoreFaces, !models.isInstalled(.gfpgan) { return false }
            return true
        }
        return true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceSection
                    if media.kind == .image { modeSection }
                    if media.kind == .image && settings.mode == .native { presetSection }
                    if media.kind == .image && settings.mode == .superResolution { superResolutionModelSection }
                    scaleSection
                    if media.kind == .image && settings.mode.isAI { aiModelSection }
                    if media.kind == .image && settings.mode == .superResolution { faceRestorationSection }
                    outputSection
                    if settings.mode == .native { advancedSection }
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
                    ProcessingOverlay(
                        progress: processor.progress,
                        phase: processor.phase,
                        detail: media.kind == .video ? "视频会逐帧处理，请保持 App 在前台" : (settings.mode.isAI ? "照片按小块和人脸模型推理，请保持 App 在前台" : "正在本机生成高清照片")
                    ) {
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
        .task(id: "\(settings.mode.rawValue)-\(settings.scale)") { await refreshAvailableSpace() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAvailableSpace() }
        }
    }

    private func refreshAvailableSpace() async {
        isCheckingSpace = true
        spaceCheckFailed = false
        defer { isCheckingSpace = false }
        let values = try? media.url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage {
            availableBytes = available
        } else {
            availableBytes = nil
            spaceCheckFailed = true
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
                Text("限长 15 分钟 · 最高 4K / 12MP · 流式逐帧处理")
                    .font(.caption2)
                    .foregroundStyle(RestoreTheme.secondary)
            } else if settings.mode.isAI {
                Text("AI 原片限制：最长边 8192 px · 最多 40MP · 分块本机推理")
                    .font(.caption2)
                    .foregroundStyle(RestoreTheme.secondary)
            }
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("修复方式").font(.headline)
            ForEach(RestoreProcessingMode.allCases) { mode in
                Button {
                    settings.mode = mode
                    if mode == .native && settings.scale > 2 { settings.scale = 2 }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mode.systemImage)
                            .font(.headline)
                            .foregroundStyle(settings.mode == mode ? RestoreTheme.cyan : RestoreTheme.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mode.title).font(.subheadline.weight(.bold))
                            Text(mode.subtitle).font(.caption2).foregroundStyle(RestoreTheme.secondary)
                        }
                        Spacer()
                        Image(systemName: settings.mode == mode ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(settings.mode == mode ? RestoreTheme.cyan : RestoreTheme.secondary)
                    }
                    .padding(13)
                    .background(settings.mode == mode ? RestoreTheme.cyan.opacity(0.1) : RestoreTheme.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(settings.mode == mode ? RestoreTheme.cyan.opacity(0.45) : RestoreTheme.stroke)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("修复风格").font(.headline)
            HStack(spacing: 9) {
                ForEach(RestorePreset.allCases) { preset in
                    Button {
                        var updated = preset.settings(
                            scale: settings.scale,
                            superResolutionModel: settings.superResolutionModel
                        )
                        updated.mode = settings.mode
                        updated.restoreFaces = settings.restoreFaces
                        settings = updated
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

    private var superResolutionModelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("超分模型").font(.headline)
            HStack(spacing: 9) {
                ForEach([RestoreModelID.realESRGAN, .localSRFast], id: \.self) { id in
                    if let spec = RestoreModelCatalog.spec(for: id) {
                        Button {
                            settings.superResolutionModel = id
                            if settings.scale > 2 { settings.scale = 2 }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(spec.name).font(.caption.weight(.bold)).lineLimit(1)
                                    Spacer()
                                    if settings.superResolutionModel == id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(RestoreTheme.cyan)
                                    }
                                }
                                Text(id == .realESRGAN ? "2× 高画质 · 内置 \(RestoreMath.formatBytes(spec.totalByteCount)) · 较慢" : "4× 快速 · 需下载 · 更快")
                                    .font(.caption2)
                                    .foregroundStyle(RestoreTheme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(.white)
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                            .background(
                                settings.superResolutionModel == id ? RestoreTheme.cyan.opacity(0.12) : RestoreTheme.card,
                                in: RoundedRectangle(cornerRadius: 16)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(settings.superResolutionModel == id ? RestoreTheme.cyan.opacity(0.52) : RestoreTheme.stroke)
                            )
                        }
                        .buttonStyle(.plain)
                    }
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
                if settings.mode == .superResolution {
                    Picker("放大倍数", selection: $settings.scale) {
                        Text("1×").tag(1.0)
                        Text("1.5×").tag(1.5)
                        Text("2×").tag(2.0)
                        if RestoreModelCatalog.spec(for: settings.superResolutionModel)?.upscaleFactor == 4 {
                            Text("4×").tag(4.0)
                        }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Picker("放大倍数", selection: $settings.scale) {
                        Text("原尺寸").tag(1.0)
                        Text("1.5×").tag(1.5)
                        Text("2×").tag(2.0)
                    }
                    .pickerStyle(.segmented)
                }
                Text("\(media.width) × \(media.height)  →  \(output.width) × \(output.height)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RestoreTheme.secondary)
                if settings.mode == .superResolution, let spec = RestoreModelCatalog.spec(for: settings.superResolutionModel) {
                    let factor = spec.upscaleFactor.map { "\($0)" } ?? "多"
                    Text("模型先生成 \(factor) 倍细节，再缩放到所选输出尺寸；长边 6144 px、最多 32MP。")
                        .font(.caption2)
                        .foregroundStyle(RestoreTheme.secondary)
                }
            }
        }
    }

    @ViewBuilder private var aiModelSection: some View {
        if let id = settings.model, let spec = RestoreModelCatalog.spec(for: id) {
            let state = models.state(for: id)
            RestoreCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(spec.name, systemImage: "cpu")
                        Spacer()
                        if models.isInstalled(id) {
                            Label("已就绪", systemImage: "checkmark.circle.fill").foregroundStyle(RestoreTheme.green)
                        } else {
                            Label("需要模型", systemImage: "arrow.down.circle").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    Text(spec.isBundled ? "模型已内置并校验；照片推理不联网，不上传原片。" : "模型单独下载并校验；照片推理不联网，不上传原片。")
                        .font(.caption2)
                        .foregroundStyle(RestoreTheme.secondary)
                    switch state {
                    case .downloading(let progress):
                        ProgressView(value: progress.fraction).tint(RestoreTheme.cyan)
                        Text(progress.summary)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(RestoreTheme.secondary)
                        Button("取消下载") { models.cancelDownload(id) }.font(.caption2)
                    case .compiling:
                        ProgressView().controlSize(.small)
                    case .failed(let message):
                        Text(message).font(.caption2).foregroundStyle(.red)
                        if spec.isBundled {
                            Text("请重新安装 App 以恢复内置模型").font(.caption2.weight(.semibold))
                        } else {
                            Button("重试下载") { models.download(id) }.font(.caption2.weight(.semibold))
                        }
                    case .notInstalled:
                        Button("下载 \(RestoreMath.formatBytes(spec.totalByteCount)) 模型") { models.download(id) }
                            .font(.caption.weight(.semibold))
                    case .installed:
                        EmptyView()
                    }
                }
                .font(.caption)
            }
        }
    }

    private var faceRestorationSection: some View {
        RestoreCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $settings.restoreFaces) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("人脸细节补全", systemImage: "face.smiling")
                        Text("识别人脸并对齐，补全眼睛、皮肤和五官颗粒；羽化贴回，不改动背景。")
                            .font(.caption2)
                            .foregroundStyle(RestoreTheme.secondary)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .tint(RestoreTheme.cyan)
                if settings.restoreFaces, let spec = RestoreModelCatalog.spec(for: .gfpgan) {
                    let state = models.state(for: .gfpgan)
                    HStack {
                        Text(spec.name).font(.caption.weight(.semibold))
                        Spacer()
                        if models.isInstalled(.gfpgan) {
                            Label("已就绪", systemImage: "checkmark.circle.fill").foregroundStyle(RestoreTheme.green)
                        } else {
                            Label("需要模型", systemImage: "arrow.down.circle").foregroundStyle(.orange)
                        }
                    }
                    switch state {
                    case .downloading(let progress):
                        ProgressView(value: progress.fraction).tint(RestoreTheme.cyan)
                        Text(progress.summary)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(RestoreTheme.secondary)
                        Button("取消下载") { models.cancelDownload(.gfpgan) }.font(.caption2)
                    case .compiling:
                        ProgressView().controlSize(.small)
                    case .failed(let message):
                        Text(message).font(.caption2).foregroundStyle(.red)
                        Button("重试下载") { models.download(.gfpgan) }.font(.caption2.weight(.semibold))
                    case .notInstalled:
                        Button("下载 \(RestoreMath.formatBytes(spec.totalByteCount)) 人脸模型") { models.download(.gfpgan) }
                            .font(.caption.weight(.semibold))
                        Text("首次下载约 322 MiB，优先使用加速线路；页面会显示已收字节、速度和当前线路，中断时自动回退。建议连接 Wi-Fi 并保持 App 在前台，校验后完全离线推理。")
                            .font(.caption2)
                            .foregroundStyle(RestoreTheme.secondary)
                    case .installed:
                        Text("人脸模型已校验，可在飞行模式下处理。")
                            .font(.caption2)
                            .foregroundStyle(RestoreTheme.secondary)
                    }
                }
            }
            .font(.caption)
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
                    if isCheckingSpace {
                        Text("正在检查可用空间…")
                    } else if let availableBytes {
                        Text("当前可用 \(RestoreMath.formatBytes(Int(availableBytes)))")
                    } else {
                        Text("无法检查可用空间")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if hasInsufficientSpace {
                        Label("空间不足", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if spaceCheckFailed {
                        Button("重试") { Task { await refreshAvailableSpace() } }
                            .font(.caption2.weight(.semibold))
                    }
                }
                Text("按原片体积、像素比和 25% 压缩余量估算，已预留 512 MB 安全空间。")
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
            Text(disclosureText)
                .font(.caption)
                .foregroundStyle(RestoreTheme.secondary)
        } icon: {
            Image(systemName: "info.circle").foregroundStyle(RestoreTheme.cyan)
        }
        .padding(.horizontal, 4)
    }

    private var disclosureText: String {
        switch settings.mode {
        case .native:
            return "原生增强使用系统降噪、色彩、锐化和边缘保留放大。它不生成新细节；视频处理速度取决于时长和分辨率。"
        case .superResolution:
            if let spec = RestoreModelCatalog.spec(for: settings.superResolutionModel) {
                let factor = spec.upscaleFactor.map { "\($0) 倍" } ?? "多倍"
                let faceText = settings.restoreFaces ? " 人脸使用 GFPGAN 512px 对齐补全并羽化贴回。" : ""
                return "AI 超分按 \(spec.tileSize)px 小块生成\(factor)细节并融合重叠区。\(faceText)高画质模型计算量更大，生成内容不一定等于真实原貌。"
            }
            return "AI 超分按小块生成细节并融合重叠区。生成内容不一定等于真实原貌，处理时间取决于照片尺寸。"
        }
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
        .disabled(!canStart)
    }

    private func icon(for preset: RestorePreset) -> String {
        switch preset {
        case .smart: return "sparkles"
        case .portrait: return "person.crop.circle"
        case .archive: return "camera.filters"
        }
    }
}
