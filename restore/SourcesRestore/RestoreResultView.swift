import SwiftUI

struct RestoreResultView: View {
    let asset: RestoredAsset

    @EnvironmentObject private var store: RestoreStore
    @Environment(\.dismiss) private var dismiss

    @State private var isSaving = false
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
                    .disabled(isSaving)

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

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("删除这条修复记录", systemImage: "trash")
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                    }
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
