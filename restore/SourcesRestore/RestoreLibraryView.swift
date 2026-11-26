import SwiftUI

struct RestoreLibraryView: View {
    @EnvironmentObject private var store: RestoreStore
    @State private var selectedAsset: RestoredAsset?

    private var totalBytes: Int {
        store.assets.reduce(0) { $0 + $1.resultBytes }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("\(store.assets.count) 条记录").font(.caption).foregroundStyle(RestoreTheme.secondary)
                        Spacer()
                        Text(RestoreMath.formatBytes(totalBytes)).font(.caption.monospacedDigit()).foregroundStyle(RestoreTheme.cyan)
                    }

                    if store.assets.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.assets) { asset in
                            assetRow(asset)
                        }
                    }
                }
                .padding(18)
                .padding(.bottom, 30)
            }
            .background(RestoreTheme.background.ignoresSafeArea())
            .navigationTitle("修复记录")
            .sheet(item: $selectedAsset) { asset in
                RestoreResultView(asset: asset)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(RestoreTheme.cyan)
            Text("这里还是空的").font(.headline)
            Text("回到「修复」页选择照片或视频，处理结果会自动保存在这里。")
                .font(.caption)
                .foregroundStyle(RestoreTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private func assetRow(_ asset: RestoredAsset) -> some View {
        HStack(spacing: 13) {
            Button {
                selectedAsset = asset
            } label: {
                HStack(spacing: 13) {
                    AssetThumbnail(asset: asset)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(asset.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(asset.summary).font(.caption).foregroundStyle(RestoreTheme.secondary).lineLimit(1)
                        Text("\(asset.outputWidth) × \(asset.outputHeight) · \(RestoreMath.formatBytes(asset.resultBytes))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(RestoreTheme.cyan)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            ShareLink(item: store.resultURL(for: asset)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.footnote)
                    .foregroundStyle(RestoreTheme.secondary)
            }
        }
        .padding(12)
        .background(RestoreTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(RestoreTheme.stroke)
        )
        .contextMenu {
            Button(role: .destructive) {
                store.delete(asset)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}
