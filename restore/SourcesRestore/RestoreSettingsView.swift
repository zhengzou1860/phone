import SwiftUI
import UIKit

struct RestoreSettingsView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    appIdentity
                    RestoreCard {
                        VStack(alignment: .leading, spacing: 14) {
                            infoRow("处理方式", "原生增强 + 本地 Core ML")
                            Divider().overlay(RestoreTheme.stroke)
                            infoRow("视频导出", "AVFoundation · 保留原声音")
                            Divider().overlay(RestoreTheme.stroke)
                            infoRow("照片输出上限", "原生 4096 px · AI 超分 6144 px")
                            Divider().overlay(RestoreTheme.stroke)
                            infoRow("视频输出上限", "长边 3840 px")
                            Divider().overlay(RestoreTheme.stroke)
                            infoRow("适配设备", "iPhone 11 及更新机型")
                        }
                    }
                    pcCard
                    modelCard
                    privacyCard
                    fileCard
                    Text("AI 超分和缺损修补会生成合理细节，但不保证还原真实原貌；原生增强仍可作为无需模型的备用方式。")
                        .font(.caption)
                        .foregroundStyle(RestoreTheme.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(18)
                .padding(.bottom, 30)
            }
            .background(RestoreTheme.background.ignoresSafeArea())
            .navigationTitle("设置")
        }
        .tint(RestoreTheme.cyan)
    }

    private var appIdentity: some View {
        HStack(spacing: 14) {
            BrandMark(size: 56)
            VStack(alignment: .leading, spacing: 5) {
                Text("高清修复").font(.title3.weight(.bold))
                Text("HiRestore v\(version)").font(.caption).foregroundStyle(RestoreTheme.secondary)
                Text("独立原生 iOS 应用").font(.caption2).foregroundStyle(RestoreTheme.cyan)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var modelCard: some View {
        RestoreCard {
            NavigationLink {
                RestoreModelView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.down.forward.line.vertical").foregroundStyle(RestoreTheme.cyan)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI 模型").font(.subheadline.weight(.bold))
                        Text("查看内置高画质模型，下载、校验和管理其他修复模型").font(.caption2).foregroundStyle(RestoreTheme.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(RestoreTheme.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var pcCard: some View {
        RestorePCView()
    }

    private var privacyCard: some View {
        RestoreCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("隐私优先", systemImage: "lock.shield.fill")
                    .font(.headline)
                    .foregroundStyle(RestoreTheme.green)
                Text("原片和修复结果只保存在这台 iPhone 的 App 沙盒中。AI 推理不访问网络，也不会自动上传照片或视频。只有你主动下载模型、发送运行日志或点击「上传到电脑」时，App 才会联网；日志不包含媒体内容。")
                    .font(.caption)
                    .foregroundStyle(RestoreTheme.secondary)
            }
        }
    }

    private var fileCard: some View {
        RestoreCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("在文件 App 中查看", systemImage: "folder.fill")
                    .font(.headline)
                    .foregroundStyle(RestoreTheme.cyan)
                Text("App 已开启文件共享。可在系统「文件」App 中进入「我的 iPhone → 高清修复 → HiRestore」，找到 Inputs 与 Results 文件夹。")
                    .font(.caption)
                    .foregroundStyle(RestoreTheme.secondary)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("打开系统设置", systemImage: "arrow.up.forward.app")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(RestoreTheme.cyan)
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(RestoreTheme.secondary)
            Spacer()
            Text(value).font(.caption.weight(.medium)).multilineTextAlignment(.trailing)
        }
    }
}
