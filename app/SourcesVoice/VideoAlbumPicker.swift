import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// 「从相册选视频」：`PHPickerViewController`，`filter = .videos`，一次一段。
///
/// 为什么换掉文件选择器：片源本来就在相册里，走「文件」要先存一份出去才能选，白绕一道。
/// PHPicker 由系统另一个进程呈现，app 拿不到整个相册，所以**不需要相册权限**
/// ——`project-voice.yml` 里没有相册授权语也不用加（同仓库换脸线在 LiveContainer 里
/// 已经用它选过视频，`app/SourcesSwap/SwapApp.swift:411`）。
///
/// 两条硬规矩都是这台机上换来的：
/// ① 拷贝必须在 `loadFileRepresentation` 那个回调**返回之前**做完：系统给的那份落在它自己的
///   临时目录里，回调一返回就被收走（`app/SourcesSwap/SwapApp.swift:409`）。
/// ② 落点直接用 Documents 的 `pick_` 前缀，不进 `FileManager.temporaryDirectory`：
///   容器 tmp 是「历史文件」页扫不到的地方，往里落就是留残料（VR 线 0.15/5 为这条被他抓到过）。
///   `pick_` 那一格（`FileHistory.Kind.source`）本来既收音频也收视频，副本有人管。
struct VideoAlbumPickerHost: UIViewControllerRepresentable {
    /// 成功时给成品的 Documents 路径和相册里那个原始文件名（日志要能回对上他点了哪一段）。
    let onPick: (URL, String) -> Void
    let onCancel: (String) -> Void
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .videos
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        VoiceJournal.line("相册选视频已呈现（filter=videos／一次一段）")
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (URL, String) -> Void
        let onCancel: (String) -> Void
        let onDismiss: () -> Void

        init(_ p: VideoAlbumPickerHost) {
            onPick = p.onPick
            onCancel = p.onCancel
            onDismiss = p.onDismiss
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // 回调闭包只抓这三个局部量：收场之后 SwiftUI 会把 representable 拆掉，
            // 到时候再回头读 self 上的属性就没有依据了。
            let cb = onPick
            let no = onCancel
            let done = onDismiss
            guard let provider = results.first?.itemProvider else {
                Task { @MainActor in
                    no("相册里没选（回调给了 0 个）")
                    done()
                }
                return
            }
            let srcName = provider.registeredTypeIdentifiers.isEmpty
                ? "-" : provider.registeredTypeIdentifiers.joined(separator: ",")
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { file, error in
                guard let file = file else {
                    let why = error?.localizedDescription ?? "回调给了空路径"
                    Task { @MainActor in
                        no("相册那份取不出来：\(why)")
                        done()
                    }
                    return
                }
                let original = file.lastPathComponent
                let ext = file.pathExtension.isEmpty ? "mov" : file.pathExtension
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let dest = docs.appendingPathComponent("pick_\(Int(Date().timeIntervalSince1970)).\(ext)")
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: file, to: dest)
                    let bytes = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? 0
                    VoiceJournal.line("相册视频 \(original)（\(srcName)）→ \(dest.lastPathComponent) \(bytes / 1024) KB")
                    Task { @MainActor in
                        cb(dest, original)
                        done()
                    }
                } catch {
                    let why = error.localizedDescription
                    VoiceJournal.line("相册视频拷进 app 目录失败：\(why)")
                    Task { @MainActor in
                        no("拷进来失败：\(why)")
                        done()
                    }
                }
            }
        }
    }
}
