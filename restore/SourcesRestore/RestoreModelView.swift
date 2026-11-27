import SwiftUI

struct RestoreModelView: View {
    @EnvironmentObject private var models: RestoreModelManager
    @State private var deleteCandidate: RestoreModelID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("RealESRGAN 高画质模型已内置在安装包中。LocalSR Fast 与 AOT-GAN 仅在点击下载后访问模型来源；校验通过后，照片推理完全在本机进行，原片不会上传。")
                    .font(.caption)
                    .foregroundStyle(RestoreTheme.secondary)

                ForEach(RestoreModelCatalog.all) { spec in
                    modelCard(spec)
                }

                Label {
                    Text("AI 生成是对周围纹理和语义的合理补全，不等于找回传感器从未记录的真实细节。重要照片请先保留原片。")
                } icon: {
                    Image(systemName: "info.circle")
                }
                    .font(.caption)
                    .foregroundStyle(RestoreTheme.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(18)
            .padding(.bottom, 30)
        }
        .background(RestoreTheme.background.ignoresSafeArea())
        .navigationTitle("AI 模型")
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除 AI 模型？", isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )) {
            Button("取消", role: .cancel) { deleteCandidate = nil }
            Button("删除", role: .destructive) {
                if let id = deleteCandidate { Task { await models.delete(id) } }
                deleteCandidate = nil
            }
        } message: {
            Text("删除后再次使用 AI 修复需要重新下载，不会影响已保存的修复结果。")
        }
    }

    private func modelCard(_ spec: RestoreModelSpec) -> some View {
        let state = models.state(for: spec.id)
        return RestoreCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: spec.id == .aotGAN ? "bandage.fill" : "sparkles")
                        .font(.title3)
                        .foregroundStyle(RestoreTheme.cyan)
                        .frame(width: 38, height: 38)
                        .background(RestoreTheme.cyan.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(spec.name).font(.subheadline.weight(.bold))
                        Text("v\(spec.version) · \(RestoreMath.formatBytes(spec.totalByteCount))")
                            .font(.caption2).foregroundStyle(RestoreTheme.secondary)
                    }
                    Spacer()
                    statusLabel(state)
                }
                Text(spec.summary).font(.caption).foregroundStyle(RestoreTheme.secondary)
                Text(spec.technicalSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(RestoreTheme.secondary)
                if case .downloading(let value) = state {
                    ProgressView(value: value).tint(RestoreTheme.cyan)
                }
                if case .failed(let message) = state {
                    Text(message).font(.caption2).foregroundStyle(.red)
                }
                HStack {
                    if let url = URL(string: spec.sourceURL) {
                        Link("查看来源", destination: url)
                            .font(.caption.weight(.semibold))
                    }
                    Spacer()
                    switch state {
                    case .notInstalled:
                        Button("下载模型") { models.download(spec.id) }
                    case .downloading:
                        Button("取消下载") { models.cancelDownload(spec.id) }
                    case .compiling:
                        ProgressView().controlSize(.small)
                    case .installed:
                        if spec.isBundled {
                            Label("内置模型", systemImage: "square.stack.3d.up.fill")
                                .font(.caption2.weight(.semibold))
                        } else {
                            Button("删除", role: .destructive) { deleteCandidate = spec.id }
                        }
                    case .failed:
                        if spec.isBundled {
                            Text("请重新安装 App 以恢复内置模型").font(.caption2.weight(.semibold))
                        } else {
                            Button("重试下载") { models.download(spec.id) }
                        }
                    }
                }
                .buttonStyle(.bordered)
                .tint(RestoreTheme.cyan)
                Text("\(spec.licenseLabel) · \(spec.attribution)")
                    .font(.caption2)
                    .foregroundStyle(RestoreTheme.secondary)
            }
        }
    }

    private func statusLabel(_ state: RestoreModelInstallState) -> some View {
        Group {
            switch state {
            case .notInstalled:
                Label("未下载", systemImage: "arrow.down.circle")
            case .downloading:
                Label("下载中", systemImage: "arrow.down.circle")
            case .compiling:
                Label("准备中", systemImage: "gear")
            case .installed:
                Label("已就绪", systemImage: "checkmark.circle.fill")            case .failed:
                Label("失败", systemImage: "exclamationmark.triangle.fill")
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(state == .installed ? RestoreTheme.green : RestoreTheme.secondary)
    }
}
