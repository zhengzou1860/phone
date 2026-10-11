import SwiftUI
import UIKit

/// 系统分享面板。iPhone 上"导出到手机"的落点就是面板里的「存储到"文件"」，
/// 顺带给隔空投送和其它 app。包一层 UIViewControllerRepresentable 是因为
/// SwiftUI 没有原生的分享控件。
///
/// 只喂 URL 不喂 Data：给了文件 URL 系统才会走"拷贝到目标位置"，直接给 Data
/// 会被各 app 当成附件、"存储到文件"那一项就不出现。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onDismiss: () -> Void
    let onPresent: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        onPresent()
        vc.completionWithItemsHandler = { _, completed, _, err in
            VoiceJournal.line(String(format: "导出面板收尾 completed=%@ err=%@",
                                     completed ? "是" : "否",
                                     err?.localizedDescription ?? "无"))
            onDismiss()
        }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
