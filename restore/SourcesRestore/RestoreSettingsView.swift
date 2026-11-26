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
                            infoRow("处理方式", "iOS 原生 Core Image")
                            Divider().overlay(RestoreTheme.stroke)
                            infoRow("视频导出", "AVFoundation · 保留原声音")
                            Divider().overlay(RestoreTheme.stroke)
                            infoRow("照片输出上限", "长边 4096 px")
                            Divider().overlay(RestoreTheme.stroke)
                            infoRow("视频输出上限", "长边 3840 px")
                            Divider().overlay(RestoreTheme.stroke)
                            infoRow("适配设备", "iPhone 11 及更新机型")
                        }
                    }
                    pcCard
                    privacyCard
                    fileCard
                    Text("系统增强不等于 AI 超分：降噪、锐化和边缘保留放大可以改善观感，但无法重建传感器从未记录到的细节。")
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

    private var pcCard: some View {
        RestorePCView()
    }

    private var privacyCard: some View {
        RestoreCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("隐私优先", systemImage: "lock.shield.fill")
                    .font(.headline)
                    .foregroundStyle(RestoreTheme.green)
                Text("原片和修复结果只保存在这台 iPhone 的 App 沙盒中。处理过程不访问网络，也不会自动上传照片或视频。只有你点击「发送运行日志」或在结果页点击「上传到电脑」时，App 才会连接你填写的电脑地址；日志不包含媒体内容。")
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
