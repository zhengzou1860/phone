import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 「选文件」：自己包一层 UIDocumentPickerViewController，不用 SwiftUI 的 fileImporter。
///
/// 三条理由都是这台机上量出来的（真机 0.1/15 回传）：
/// ① fileImporter 的呈现由 SwiftUI 自己管，同一个视图上挂两个（源槽 + 参考槽）只有一个生效
///   ⇒ 症状就是「① 源音频点选文件没反应」。
/// ② allowedContentTypes 给 `[.audio,.wav,…]` 时列表里全灰 ⇒ 症状是「进了目录但选不了文件」；
///   放宽到 `[.item]`，能不能用改由我们自己验（选完就地开一次 AVAudioFile），
///   别让系统的类型过滤决定用户点不点得动。
/// ③ 另外两个 app 的同一坑：这环境下 cover 不会因为选完而自己消失，必须在回调里自己收场
///   （见 app/Sources/Cut.swift:967）。
///
/// `asCopy: true`：系统直接把文件复制进沙盒临时区，回调给的 URL 立刻可读，
/// 不需要 startAccessingSecurityScopedResource（那条在 LiveContainer 里本来就是半残的）。
/// 拿到后仍马上再拷一份进 Documents —— 临时区随时会被清。
struct DocumentPickerHost: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: (String) -> Void
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        vc.allowsMultipleSelection = false
        vc.delegate = context.coordinator
        VoiceJournal.line("文件选择器已呈现（forOpeningContentTypes=[.item] asCopy=true）")
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerHost
        init(_ parent: DocumentPickerHost) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                parent.onCancel("回调给了空列表（0 个 URL）")
                parent.onDismiss()
                return
            }
            parent.onPick(url)
            parent.onDismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel("用户自己取消")
            parent.onDismiss()
        }
    }
}
