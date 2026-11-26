import SwiftUI

struct RestoreResultView: View {
    let asset: RestoredAsset

    @EnvironmentObject private var store: RestoreStore
    @Environment(\.dismiss) private var dismiss

    @State private var isSaving = false
    @State private var isUploading = false
    @State private var uploadProgress: Double?
    @State private var uploadTask: Task<Void, Never>?
    @State private var showUploadConfirmation = false
    @State private var message: String?
    @State private var showDeleteConfirmation = false

    private var resultURL: URL { store.resultURL(for: asset) }
    private var sourceURL: URL { store.sourceURL(for: asset) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CompareView(asset: asset, sourceURL: sourceURL, resultURL: resultURL)

                    HStack(spacing: 10) {
                        metric("分辨率", "\(asset.outputWidth) × \(asset.outputHeight)")
                        metric(asset.kind == .image ? "文件大小" : "时长", asset.kind == .image
                               ? RestoreMath.formatBytes(asset.resultBytes)
                               : String(format: "%.1f 秒", asset.duration))
                    }

                    RestoreCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(asset.title).font(.headline)
                            Text(asset.summary).font(.caption).foregroundStyle(RestoreTheme.secondary)
                            Text(asset.createdAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption2).foregroundStyle(RestoreTheme.secondary)
                        }
                    }

                    Button {
                        save()
                    } label: {
                        HStack {
                            if isSaving { ProgressView().tint(.black) } else { Image(systemName: "square.and.arrow.down") }
                            Text(isSaving ? "正在保存…" : "保存到系统相册")
                            Spacer()
                        }
                        .font(.headline)
                        .foregroundStyle(.black)
                        .padding(16)
                        .background(RestoreTheme.cyan, in: RoundedRectangle(cornerRadius: 17))
                    }
                    .disabled(isSaving || isUploading)

                    ShareLink(item: resultURL) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("分享修复结果")
                            Spacer()
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(16)
                        .background(RestoreTheme.card, in: RoundedRectangle(cornerRadius: 17))
                    }
                    .disabled(isSaving || isUploading)

                    Button {
                        showUploadConfirmation = true
                    } label: {
                        HStack {
                            if isUploading {
                                ProgressView().tint(RestoreTheme.cyan)
                                Text("上传中 \(Int((uploadProgress ?? 0) * 100))%")
                            } else {
                                Image(systemName: "computer")
                                Text("发给电脑 · 上传修复结果")
                            }
                            Spacer()
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(16)
                        .background(RestoreTheme.card, in: RoundedRectangle(cornerRadius: 17))
                    }
                    .disabled(isSaving || isUploading)
                    .confirmationDialog("只发送这条修复结果（\(RestoreMath.formatBytes(asset.resultBytes))），不发送 App 内保留的原片。继续上传吗？", isPresented: $showUploadConfirmation) {
                        Button("上传到电脑") { uploadResult() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("电脑地址：\(RestorePCTransport.normalizedEndpoint(RestorePCTransport.savedEndpoint) ?? RestorePCTransport.defaultEndpoint)")
                    }

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("删除这条修复记录", systemImage: "trash")
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(isSaving || isUploading)
                    .confirmationDialog("同时删除 App 内的原片副本和修复结果？系统相册中已保存的文件不受影响。", isPresented: $showDeleteConfirmation) {
                        Button("删除", role: .destructive) {
                            store.delete(asset)
                            dismiss()
                        }
                        Button("取消", role: .cancel) {}
                    }
                }
                .padding(18)
                .padding(.bottom, 30)
            }
            .background(RestoreTheme.background.ignoresSafeArea())
            .navigationTitle("修复完成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .disabled(isUploading)
                }
            }
            .alert("提示", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("知道了", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
        .tint(RestoreTheme.cyan)
        .interactiveDismissDisabled(isUploading)
        .onDisappear { uploadTask?.cancel() }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(RestoreTheme.secondary)
            Text(value).font(.subheadline.weight(.bold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RestoreTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func uploadResult() {
        guard !isUploading else { return }
        isUploading = true
        uploadProgress = 0
        let target = RestorePCTransport.savedEndpoint
        let key = RestorePCTransport.savedToken
        RestoreJournal.line("准备上传修复结果：\(asset.kind.rawValue) \(asset.outputWidth)×\(asset.outputHeight) \(asset.resultBytes) 字节")
        uploadTask = Task {
            defer {
                isUploading = false
                uploadProgress = nil
                uploadTask = nil
            }
            do {
                let reply = try await RestorePCTransport.upload(
                    file: resultURL,
                    endpoint: target,
                    token: key
                ) { value in
                    await MainActor.run { uploadProgress = value }
                }
                message = reply
                RestoreJournal.line("修复结果上传成功：\(reply)")
            } catch is CancellationError {
                RestoreJournal.line("修复结果上传已取消")
            } catch {
                message = RestorePCTransport.userMessage(for: error)
                RestoreJournal.line("修复结果上传失败：\(RestorePCTransport.userMessage(for: error))")
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await store.saveToPhotos(asset)
                message = "已保存到系统相册"
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
