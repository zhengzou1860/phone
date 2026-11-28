import SwiftUI
import UIKit

struct RestorePCView: View {
    @AppStorage(RestorePCTransport.endpointKey) private var endpoint = RestorePCTransport.defaultEndpoint
    @AppStorage(RestorePCTransport.tokenKey) private var token = RestorePCTransport.defaultToken

    @State private var message = "还没有连接或发送"
    @State private var isBusy = false
    @State private var progress: Double?
    @State private var sharedLogURL: URL?

    var body: some View {
        RestoreCard {
            VStack(alignment: .leading, spacing: 13) {
                Label("上传到电脑", systemImage: "computer")
                    .font(.headline)
                    .foregroundStyle(RestoreTheme.cyan)
                Text("手机和电脑需在同一 Wi-Fi。电脑双击 tools/start_hirestore.bat 并保持窗口打开；若 Windows 防火墙询问，允许 Python 访问专用网络。按窗口显示的局域网地址填写，密钥默认 hirestore-local。")
                    .font(.caption)
                    .foregroundStyle(RestoreTheme.secondary)

                TextField("电脑地址", text: $endpoint, prompt: Text(RestorePCTransport.defaultEndpoint))
                    .font(.caption.monospaced())
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .padding(11)
                    .background(RestoreTheme.cardStrong, in: RoundedRectangle(cornerRadius: 12))

                SecureField("上传密钥", text: $token, prompt: Text(RestorePCTransport.defaultToken))
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .padding(11)
                    .background(RestoreTheme.cardStrong, in: RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 10) {
                    Button("测试连接") { ping() }
                        .buttonStyle(.bordered)
                    Button("发送运行日志") { sendLog() }
                        .buttonStyle(.borderedProminent)
                }
                .tint(RestoreTheme.cyan)
                .disabled(isBusy)

                Button("导出日志（无需连接电脑）") { exportLog() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(isBusy)

                if isBusy {
                    HStack(spacing: 10) {
                        ProgressView().tint(RestoreTheme.cyan)
                        if let progress {
                            ProgressView(value: progress).tint(RestoreTheme.cyan)
                            Text("\(Int(progress * 100))%").font(.caption.monospacedDigit())
                        }
                    }
                }

                Text(message)
                    .font(.caption)
                    .foregroundStyle(RestoreTheme.secondary)
                    .textSelection(.enabled)

                Text("日志只包含 App 版本、设备型号、存储状态和操作记录，不包含照片或视频内容。无法连接电脑时，可点「导出日志」后存储到文件或发给他人。媒体结果只能在「修复完成」页由你主动上传。")
                    .font(.caption2)
                    .foregroundStyle(RestoreTheme.secondary)
            }
        }
        .sheet(isPresented: Binding(
            get: { sharedLogURL != nil },
            set: { if !$0 { sharedLogURL = nil } }
        )) {
            if let sharedLogURL {
                ShareLink(item: sharedLogURL) {
                    Label("导出运行日志", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(24)
                .presentationDetents([.medium])
            }
        }
    }

    private func ping() {
        guard !isBusy else { return }
        isBusy = true
        message = "正在测试连接…"
        let target = endpoint
        let key = RestorePCTransport.savedToken
        Task {
            defer { isBusy = false }
            do {
                let reply = try await RestorePCTransport.ping(endpoint: target, token: key)
                message = reply
                RestoreJournal.line("电脑连接测试成功：\(reply)")
            } catch {
                let diagnostic = RestorePCTransport.userMessage(for: error)
                message = diagnostic
                RestoreJournal.line("电脑连接测试失败：\(diagnostic)")
            }
        }
    }

    private func sendLog() {
        guard !isBusy else { return }
        isBusy = true
        progress = 0
        message = "正在发送运行日志…"
        let target = endpoint
        let key = RestorePCTransport.savedToken
        let report = RestoreJournal.snapshot(details: deviceDetails(target: target))
        RestoreJournal.line("准备发送运行日志到 \(RestorePCTransport.normalizedEndpoint(target) ?? target)")
        Task {
            defer {
                isBusy = false
                progress = nil
            }
            do {
                let reply = try await RestorePCTransport.sendLog(report, endpoint: target, token: key)
                message = reply
                RestoreJournal.line("运行日志发送成功：\(reply)")
            } catch {
                let diagnostic = RestorePCTransport.userMessage(for: error)
                message = diagnostic
                RestoreJournal.line("运行日志发送失败：\(diagnostic)")
            }
        }
    }

    private func exportLog() {
        RestoreJournal.line("导出运行日志到文件")
        do {
            let url = try RestoreJournal.exportSnapshot(details: deviceDetails(target: endpoint))
            sharedLogURL = url
            message = "日志已生成，可存储到「文件」或分享给他人"
        } catch {
            message = "日志导出失败：\(error.localizedDescription)"
            RestoreJournal.line("运行日志导出失败：\(error.localizedDescription)")
        }
    }

    private func deviceDetails(target: String) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        let device = UIDevice.current
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let available = documents.flatMap { try? $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage } ?? 0
        return """
        版本：\(version) (\(build))
        系统：\(device.systemName) \(device.systemVersion)
        设备：\(device.model)
        内存：\(RestoreMath.formatBytes(Int(ProcessInfo.processInfo.physicalMemory)))
        电脑地址：\(RestorePCTransport.normalizedEndpoint(target) ?? target)
        可用空间：\(RestoreMath.formatBytes(Int(available)))
        """
    }
}
