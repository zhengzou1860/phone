import Foundation
import SwiftUI
import PhotosUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// 一条待发的附件。形状照网页 `PEND` 里那两种（`index.html:1052`）：
/// 图 = name/size/dataUrl（base64 随消息发，OpenAI 的 image_url 多模态格式），
/// 文本 = name/size/text/chars/truncated（整段读进来，以围栏代码块并进同一条消息）。
///
/// 和网页一样：**附件只在这台手机上被读**，不往电脑那台机器写任何中间文件；
/// 落盘只落在会话副本 chat_feed.json 里（等于网页那份 localStorage）。
struct ChatAttach: Codable, Identifiable {
    var id = UUID()
    var kind: String            // image / text
    var name: String
    var size: Int
    var dataUrl = ""
    var mime = ""
    var text = ""
    var chars = 0
    var truncated = false

    enum CodingKeys: String, CodingKey {
        case id, kind, name, size, dataUrl, mime, text, chars, truncated
    }

    init(kind: String, name: String, size: Int) {
        self.kind = kind
        self.name = name
        self.size = size
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "text"
        name = (try? c.decode(String.self, forKey: .name)) ?? "附件"
        size = (try? c.decode(Int.self, forKey: .size)) ?? 0
        dataUrl = (try? c.decode(String.self, forKey: .dataUrl)) ?? ""
        mime = (try? c.decode(String.self, forKey: .mime)) ?? ""
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        chars = (try? c.decode(Int.self, forKey: .chars)) ?? 0
        truncated = (try? c.decode(Bool.self, forKey: .truncated)) ?? false
    }
}

enum ChatAttachIO {
    // 网页那四个上限，一个数没改（index.html:480-482）
    static let fileMaxBytes = 200_000
    static let fileMaxChars = 40_000
    static let msgMaxChars = 200_000
    /// 网页没有这两条：浏览器随便吃，这台机不行 —— 一张 12 MP 照片 base64 之后 4 MB 上下，
    /// 链子本身峰值就 318 MB，图不设上限就是拿 jetsam 赌。超了明说拒收，不悄悄缩。
    static let imageMaxBytes = 8_000_000
    static let imageMaxCount = 4
    /// 会话副本超过这个字节数就把图的 base64 丢掉、只留名字和大小（网页 saveSession 那条
    /// LS_MAX_CHARS=3500000，index.html:479/899）。这边同样宁可丢图也不丢整份会话：
    /// 副本是开页时整份读进内存的，几张原图的 base64 就能把它顶到几十 MB。
    static let bookMaxBytes = 3_500_000

    static func fmtSize(_ b: Int) -> String {
        if b >= 1_048_576 { return String(format: "%.1f MB", Double(b) / 1_048_576) }
        return "\(max(1, Int((Double(b) / 1024).rounded()))) KB"
    }

    /// 只看内容不看扩展名：前 8192 字节里有 0、或者解出来的替换字符超过 2%，就当二进制拒收。
    /// 和网页 sniffText 同一条判据（index.html:1068）。
    static func sniff(_ data: Data) -> String? {
        let head = data.prefix(8192)
        if head.contains(0) { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let scan = text.prefix(8192)
        guard !scan.isEmpty else { return text }
        let bad = scan.filter { $0 == "\u{FFFD}" }.count
        if Double(bad) > Double(scan.count) * 0.02 { return nil }
        return text
    }

    /// 选进来一个文件。`pending` 是这条消息已经挂上的附件（算 200K 字符的余量要用）。
    /// 返回 (附件, 拒收原因)：两者只有一个非空。
    static func fromFile(_ url: URL, pending: [ChatAttach]) -> (ChatAttach?, String) {
        let name = url.lastPathComponent
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        let ext = url.pathExtension
        let type = UTType(filenameExtension: ext)
        if let t = type, t.conforms(to: .image) {
            guard let data = try? Data(contentsOf: url) else { return (nil, "\(name)：读不出来") }
            return fromImage(data, name: name, mime: t.preferredMIMEType ?? "image/png", pending: pending)
        }
        // 只读前 200 KB：网页是 f.slice(0, FILE_MAX_BYTES)，大文件不该整份进内存
        guard let fh = try? FileHandle(forReadingFrom: url) else { return (nil, "\(name)：读不出来") }
        defer { try? fh.close() }
        guard let raw = try? fh.read(upToCount: fileMaxBytes) else { return (nil, "\(name)：读不出来") }
        return fromText(raw, name: name, size: size, pending: pending)
    }

    static func fromImage(_ data: Data, name: String, mime: String, pending: [ChatAttach]) -> (ChatAttach?, String) {
        let imgs = pending.filter { $0.kind == "image" }
        if imgs.count >= imageMaxCount {
            return (nil, "\(name)：一条消息最多 \(imageMaxCount) 张图，先发出去或减几张")
        }
        if data.count > imageMaxBytes {
            return (nil, "\(name)：\(fmtSize(data.count)) 太大（上限 \(fmtSize(imageMaxBytes))），先存成小一点的再选")
        }
        guard !data.isEmpty else { return (nil, "\(name)：读出来是空的") }
        let (bytes, fname, fmime) = jpegIfBackendCantRead(data, name: name, mime: mime)
        var a = ChatAttach(kind: "image", name: fname, size: bytes.count)
        a.mime = fmime
        a.dataUrl = "data:\(fmime);base64," + bytes.base64EncodedString()
        VoiceJournal.line("附件（图）\(fname) \(bytes.count / 1024) KB \(fmime)")
        return (a, "")
    }

    /// 电脑那头读图走的是 llama.cpp 自带的那套解码（png/jpeg/webp/gif/bmp 这几种），
    /// 而这台手机相册里默认是 **HEIC** —— 原样 base64 发过去只会换回一句「图读不出来」。
    /// 所以不在那几种里的当场转成 JPEG 再发，名字/大小/类型跟着一起改，日志里写明转过了。
    /// 用 ImageIO 出图（长边封顶 4096）而不是 UIImage 整份解：12 MP 原图解进内存就是 48 MB。
    static func jpegIfBackendCantRead(_ data: Data, name: String, mime: String) -> (Data, String, String) {
        let readable: Set<String> = ["image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp"]
        if readable.contains(mime.lowercased()) { return (data, name, mime) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let out = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            VoiceJournal.line("附件图 \(name)（\(mime)）转 JPEG 没成，按原样发（后端可能读不了）")
            return (data, name, mime)
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return (data, name, mime) }
        let jpeg = out as Data
        let stem = (name as NSString).deletingPathExtension
        VoiceJournal.line("附件图 \(name)（\(mime)）后端读不了 ⇒ 转成 JPEG \(jpeg.count / 1024) KB")
        return (jpeg, stem + ".jpg", "image/jpeg")
    }

    static func fromText(_ raw: Data, name: String, size: Int, pending: [ChatAttach]) -> (ChatAttach?, String) {
        guard let text0 = sniff(raw) else {
            return (nil, "\(name)：不像文本（有 0 字节或解不出 UTF-8），已拒收")
        }
        var text = text0
        var truncated = size > fileMaxBytes
        let used = pending.filter { $0.kind == "text" }.reduce(0) { $0 + $1.chars }
        let room = msgMaxChars - used
        if room <= 0 {
            return (nil, "\(name)：这条消息的文件已塞满 \(msgMaxChars / 1000)K 字符，先发出去或减几个")
        }
        let cap = min(fileMaxChars, room)
        if text.count > cap {
            text = String(text.prefix(cap))
            truncated = true
        }
        var a = ChatAttach(kind: "text", name: name, size: size)
        a.text = text
        a.chars = text.count
        a.truncated = truncated
        VoiceJournal.line("附件（文本）\(name) \(size / 1024) KB → \(a.chars) 字\(truncated ? "（截断）" : "")")
        return (a, "")
    }

    /// 剪贴板：有图就当图附件，只有文字就照旧进输入框（网页那条「纯文本粘贴不抢」）。
    static func fromPasteboard(pending: [ChatAttach]) -> (ChatAttach?, String, String) {
        let pb = UIPasteboard.general
        if let img = pb.image {
            guard let data = img.pngData() else { return (nil, "", "剪贴板里的图转不成 PNG") }
            let (a, note) = fromImage(data, name: "剪贴板图片.png", mime: "image/png", pending: pending)
            return (a, note, "")
        }
        if let s = pb.string, !s.isEmpty { return (nil, "", s) }
        return (nil, "", "")
    }

    static func imageData(_ a: ChatAttach) -> Data? {
        guard let comma = a.dataUrl.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(a.dataUrl[a.dataUrl.index(after: comma)...]))
    }

    /// 气泡里那张只有 64 pt 高，原图可能 12 MP ⇒ 用 ImageIO 直接出缩略图，不整份解进内存。
    static func thumbnail(_ a: ChatAttach, maxPixel: Int = 300) -> UIImage? {
        guard let data = imageData(a),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 一条附件在 prompt 里长什么样（网页 fileBlock，index.html:794）。
    static func block(_ a: ChatAttach) -> String {
        let cut = a.truncated ? "（文件更大，这里只取到前 \(a.chars.formatted(.number)) 字符）" : ""
        return "【附件 \(a.name) · \(fmtSize(a.size)) · \(a.chars.formatted(.number)) 字符\(cut)】\n```\n\(a.text)\n```"
    }

    /// 一条用户消息在 prompt 里长什么样：图在前、附件正文在中、问话在最后（网页 userContent）。
    /// 没有附件时保持纯字符串，和以前的请求体完全一致。
    static func content(_ e: ChatRecord) -> Any {
        let imgs = e.imgs.filter { !$0.dataUrl.isEmpty }   // 存不下时 dataUrl 会被丢掉，那种图发不出去
        if imgs.isEmpty && e.files.isEmpty { return e.text }
        var parts: [[String: Any]] = imgs.map { ["type": "image_url", "image_url": ["url": $0.dataUrl]] }
        parts += e.files.map { ["type": "text", "text": block($0)] }
        if !e.text.isEmpty { parts.append(["type": "text", "text": e.text]) }
        return parts
    }
}

/// 附件要呈现哪一个选择器。两个共用一个 `fullScreenCover(item:)`：
/// 同一个视图上挂两个同类型的呈现，这环境下只有一个生效（① 那条 fileImporter 的老坑）。
enum AttachPick: String, Identifiable {
    case files
    case album
    var id: String { rawValue }
}

/// 「从相册选图」：和选视频那条同一个做法（PHPicker 由系统另一个进程呈现，不要相册授权语），
/// 只把 filter 换成 .images、一次可选多张。
///
/// 和视频那条的一处不同：这里**不往 Documents 拷副本** —— 附件要的是字节本身（base64 进消息），
/// 拷一份就是往盘上留残料。`loadDataRepresentation` 给的就是内存里那份，回调里当场收进 Data。
struct ImageAlbumPickerHost: UIViewControllerRepresentable {
    /// (图字节, 相册里那个名字, 系统给的类型标识)
    let onPick: (Data, String, String) -> Void
    let onCancel: (String) -> Void
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        VoiceJournal.line("相册选图已呈现（filter=images／可多选）")
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (Data, String, String) -> Void
        let onCancel: (String) -> Void
        let onDismiss: () -> Void
        private let lock = NSLock()
        private var left = 0
        private var notes: [String] = []

        init(_ p: ImageAlbumPickerHost) {
            onPick = p.onPick
            onCancel = p.onCancel
            onDismiss = p.onDismiss
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // 收场之后 SwiftUI 会把 representable 拆掉，回调只抓这三个局部量（同选视频那条的理由）
            let cb = onPick
            let no = onCancel
            let done = onDismiss
            guard !results.isEmpty else {
                Task { @MainActor in
                    no("相册里没选（回调给了 0 个）")
                    done()
                }
                return
            }
            lock.lock()
            left = results.count
            notes = []
            lock.unlock()
            for r in results {
                let provider = r.itemProvider
                let name = provider.suggestedName ?? "相册图片"
                let tid = provider.registeredTypeIdentifiers.first ?? UTType.image.identifier
                guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
                    finish("\(name)：不是能读出来的图", no: no, done: done)
                    continue
                }
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    if let data = data, !data.isEmpty {
                        let ext = UTType(tid)?.preferredFilenameExtension ?? "png"
                        let mime = UTType(tid)?.preferredMIMEType ?? "image/png"
                        Task { @MainActor in cb(data, name + "." + ext, mime) }
                        self.finish(nil, no: no, done: done)
                    } else {
                        let why = error?.localizedDescription ?? "回调给了空数据"
                        self.finish("\(name)：相册那份取不出来（\(why)）", no: no, done: done)
                    }
                }
            }
        }

        /// 多张图是各自异步回来的：数到最后一张才收场，拒收原因攒成一条说。
        private func finish(_ note: String?, no: @escaping (String) -> Void, done: @escaping () -> Void) {
            lock.lock()
            left -= 1
            if let n = note { notes.append(n) }
            let last = left <= 0
            let all = notes
            lock.unlock()
            guard last else { return }
            Task { @MainActor in
                if !all.isEmpty { no(all.joined(separator: "　·　")) }
                done()
            }
        }
    }
}