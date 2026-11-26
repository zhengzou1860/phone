import SwiftUI

struct RestoreRootView: View {
    var body: some View {
        TabView {
            RestoreHomeView()
                .tabItem { Label("修复", systemImage: "sparkles") }
            RestoreLibraryView()
                .tabItem { Label("记录", systemImage: "photo.on.rectangle.angled") }
            RestoreSettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .tint(RestoreTheme.cyan)
    }
}

struct RestoreHomeView: View {
    @EnvironmentObject private var store: RestoreStore
    @EnvironmentObject private var processor: RestoreProcessor

    @State private var pickerKind: MediaKind?
    @State private var editorMedia: ImportedMedia?
    @State private var selectedResult: RestoredAsset?
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    hero
                    importCard
                    recentSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(RestoreTheme.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .sheet(item: $pickerKind) { kind in
                RestorePicker(
                    kind: kind,
                    onPicked: { importPicked($0, kind: kind) },
                    onFailure: { message in
                        pickerKind = nil
                        importError = message
                    }
                )
            }
            .sheet(item: $editorMedia) { media in
                RestoreEditorView(media: media, processor: processor)
            }
            .sheet(item: $selectedResult) { asset in
                RestoreResultView(asset: asset)
            }
            .onChange(of: processor.completedAsset?.id) { _, newValue in
                guard let newValue, let asset = store.assets.first(where: { $0.id == newValue }) else { return }
                editorMedia = nil
                selectedResult = asset
            }
            .alert("无法导入", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("知道了", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .overlay {
                if isImporting {
                    ZStack {
                        Color.black.opacity(0.45).ignoresSafeArea()
                        VStack(spacing: 14) {
                            ProgressView().tint(RestoreTheme.cyan)
                            Text("正在准备原片…").font(.footnote.weight(.medium))
                        }
                        .padding(24)
                        .background(RestoreTheme.cardStrong, in: RoundedRectangle(cornerRadius: 20))
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            BrandMark(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("高清修复").font(.headline)
                Text("HiRestore").font(.caption).foregroundStyle(RestoreTheme.secondary)
            }
            Spacer()
            Image(systemName: "iphone")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RestoreTheme.cyan)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RestoreTheme.cyan.opacity(0.08), in: Capsule())
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("让每一帧\n更清晰。")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [.white, RestoreTheme.cyan], startPoint: .top, endPoint: .bottom)
                )
            Text("用 iPhone 原生影像能力，修复照片与视频的噪点、色彩和边缘。")
                .font(.subheadline)
                .foregroundStyle(RestoreTheme.secondary)
            PrivacyPill()
        }
        .padding(.top, 10)
    }

    private var importCard: some View {
        RestoreCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("开始修复").font(.title3.weight(.bold))
                    Spacer()
                    Text("系统相册").font(.caption).foregroundStyle(RestoreTheme.secondary)
                }
                HStack(spacing: 12) {
                    importButton(for: .image)
                    importButton(for: .video)
                }
                HStack(spacing: 8) {
                    feature("arrow.up.left.and.arrow.down.right", "边缘保留放大")
                    feature("waveform.path", "视频保留声音")
                    feature("memorychip", "iPhone 11 优化")
                }
            }
        }
    }

    private func importButton(for kind: MediaKind) -> some View {
        Button {
            pickerKind = kind
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: kind.systemName)
                    .font(.title2.weight(.semibold))
                Text(kind == .image ? "修复照片" : "修复视频")
                    .font(.subheadline.weight(.bold))
                Text(kind == .image ? "JPG / HEIC" : "MOV / MP4")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .padding(15)
            .background(
                LinearGradient(
                    colors: kind == .image
                        ? [RestoreTheme.cyan.opacity(0.22), RestoreTheme.cyan.opacity(0.06)]
                        : [RestoreTheme.violet.opacity(0.24), RestoreTheme.violet.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(kind == .image ? RestoreTheme.cyan.opacity(0.3) : RestoreTheme.violet.opacity(0.34))
            )
        }
        .buttonStyle(.plain)
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(RestoreTheme.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var recentSection: some View {
        HStack {
            Text("最近修复").font(.title3.weight(.bold))
            Spacer()
            if !store.assets.isEmpty {
                NavigationLink {
                    RestoreLibraryView()
                } label: {
                    Text("全部").font(.caption.weight(.semibold)).foregroundStyle(RestoreTheme.cyan)
                }
            }
        }

        if store.assets.isEmpty {
            RestoreCard {
                HStack(spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundStyle(RestoreTheme.cyan)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("还没有修复记录").font(.subheadline.weight(.semibold))
                        Text("完成第一张照片或视频后，可在这里继续查看和保存。")
                            .font(.caption).foregroundStyle(RestoreTheme.secondary)
                    }
                }
            }
        } else {
            ForEach(store.assets.prefix(3)) { asset in
                Button {
                    selectedResult = asset
                } label: {
                    HStack(spacing: 13) {
                        AssetThumbnail(asset: asset)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(asset.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(asset.summary).font(.caption).foregroundStyle(RestoreTheme.secondary).lineLimit(1)
                            Text("\(asset.outputWidth) × \(asset.outputHeight)")
                                .font(.caption2.monospacedDigit()).foregroundStyle(RestoreTheme.cyan)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(RestoreTheme.secondary)
                    }
                    .padding(12)
                    .background(RestoreTheme.card, in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func importPicked(_ url: URL?, kind: MediaKind) {
        pickerKind = nil
        guard let url else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let media = try await store.importMedia(from: url, kind: kind)
                RestoreJournal.line("导入完成：\(kind.rawValue) \(media.width)×\(media.height) \(media.byteCount) 字节")
                editorMedia = media
            } catch {
                RestoreJournal.line("导入失败：\(error.localizedDescription)")
                importError = error.localizedDescription
            }
        }
    }
}
