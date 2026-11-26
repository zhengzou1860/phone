import SwiftUI
import AVKit
import AVFoundation
import ImageIO
import UIKit

struct RestoreMediaImage: View {
    let url: URL
    var maxPixel: Int = 1800

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RestoreTheme.background
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    ProgressView()
                        .tint(RestoreTheme.cyan)
                }
            }
        }
        .task(id: url.path) {
            image = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
                return UIImage(cgImage: cgImage)
            }.value
        }
    }
}

struct RestoreMediaPlayer: View {
    let url: URL

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            RestoreTheme.background
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
                    .tint(RestoreTheme.cyan)
            }
        }
        .onAppear {
            if player == nil { player = AVPlayer(url: url) }
        }
        .onDisappear {
            player?.pause()
        }
    }
}

struct RestoreMediaPreview: View {
    let kind: MediaKind
    let url: URL

    var body: some View {
        Group {
            if kind == .image {
                RestoreMediaImage(url: url)
            } else {
                RestoreMediaPlayer(url: url)
            }
        }
        .aspectRatio(kind == .image ? nil : 16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(RestoreTheme.stroke, lineWidth: 1)
        )
    }
}

struct CompareView: View {
    let asset: RestoredAsset
    let sourceURL: URL
    let resultURL: URL

    @State private var showingResult = true

    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .topLeading) {
                Group {
                    if showingResult {
                        RestoreMediaPreview(kind: asset.kind, url: resultURL)
                    } else {
                        RestoreMediaPreview(kind: asset.kind, url: sourceURL)
                    }
                }
                .frame(height: 330)

                Text(showingResult ? "修复后" : "原图")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.58), in: Capsule())
                    .padding(12)
            }

            Picker("对比画面", selection: $showingResult) {
                Text("原图").tag(false)
                Text("修复后").tag(true)
            }
            .pickerStyle(.segmented)
        }
    }
}

struct AssetThumbnail: View {
    let asset: RestoredAsset
    @EnvironmentObject private var store: RestoreStore
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RestoreTheme.cardStrong
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: asset.kind.systemName)
                    .foregroundStyle(RestoreTheme.secondary)
            }
        }
        .frame(width: 82, height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(RestoreTheme.stroke, lineWidth: 1)
        )
        .task(id: asset.id) {
            image = await store.thumbnail(for: asset, maxPixel: 480)
        }
    }
}

struct ProcessingOverlay: View {
    let progress: Double
    let phase: String
    var detail: String = "请保持 App 在前台"
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(RestoreTheme.stroke, lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: max(0.01, min(1, progress)))
                        .stroke(
                            LinearGradient(colors: [RestoreTheme.cyan, RestoreTheme.violet], startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(progress * 100))%")
                        .font(.title3.weight(.bold).monospacedDigit())
                }
                .frame(width: 92, height: 92)

                Text(phase)
                    .font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(RestoreTheme.secondary)

                Button("停止处理", role: .destructive, action: onCancel)
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
            .padding(28)
            .background(RestoreTheme.cardStrong, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(24)
        }
    }
}
