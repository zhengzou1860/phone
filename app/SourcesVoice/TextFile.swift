import Foundation
import CoreFoundation

/// 读手机里的文本文件（.txt/.md）成 String，编码自己试，不赌系统帮猜。
///
/// 小说 txt 在手机上就那几种口径：UTF-8（现在主流）、UTF-16 带 BOM（Windows 另存的）、
/// GB18030/GBK（老站子抓下来的）、Big5（繁站）。`String(data:encoding:)` 是严格解码，
/// 猜错就返回 nil ⇒ 按顺序试，最后一个兜底用有损 UTF-8（宁可花几个字符也别整篇读不出来）。
///
/// 报回来的 `encoding` 是要进日志的：读进去的字不对，靠这一格才知道是解码选错了还是本来就错。
enum TextFile {

    /// 32 MB ≈ 一千多万字，够装一本长篇。超了这个数多半选错了文件（视频、zip）。
    static let maxBytes = 32 * 1024 * 1024

    /// 用 CF 的编码常量搭 NSStringEncoding，Swift 的 `String.Encoding` 里没有 GBK/Big5 这两档。
    /// `UInt(...)` 那一手是不赌宽度：`NSStringEncoding` 在不同 SDK 里可能是 UInt32/UInt64，
    /// 而 `String.Encoding` 的 rawValue 钉死是 UInt。
    private static func nsEncoding(_ cf: CFStringEncodings) -> String.Encoding {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue))
        return String.Encoding(rawValue: UInt(raw))
    }

    static func load(_ url: URL) throws -> (text: String, encoding: String) {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw fail("\(url.lastPathComponent) 是 0 字节") }
        guard size <= Int64(maxBytes) else {
            throw fail(String(format: "%@ 有 %.1f MB，不像一本能读完的书（上限 %.0f MB）⇒ 确认选的是文本文件",
                              url.lastPathComponent, Double(size) / 1e6, Double(maxBytes) / 1e6))
        }
        let data = try Data(contentsOf: url)
        // 只掐头几个字节看 BOM 和魔数，别为此把整份文件再复制一遍（上限是 32 MB）。
        let head = Array(data.prefix(8))
        func byte(_ i: Int) -> UInt8 { i < head.count ? head[i] : 0 }
        func starts(_ magic: [UInt8]) -> Bool {
            guard data.count >= magic.count else { return false }
            for i in 0..<magic.count where head[i] != magic[i] { return false }
            return true
        }
        // 0.1/23 真机：一份 `林华.pdf` 被当成「UTF-8 有损」读了 45470 字乱码，界面上看不出来。
        // 撞上任一个二进制魔数就直接拒，别让他拿一章乱码去跑二十分钟。
        let binaries: [(String, [UInt8])] = [
            ("PDF", [0x25, 0x50, 0x44, 0x46]),        // %PDF
            ("zip／epub／docx", [0x50, 0x4B]),        // PK
            ("RTF", [0x7B, 0x5C, 0x72, 0x74, 0x66]),  // {\rtf
            ("mp3／带标签音频", [0x49, 0x44, 0x33]),   // ID3
            ("GIF", [0x47, 0x49, 0x46, 0x38]),        // GIF8
            ("PNG", [0x89, 0x50, 0x4E, 0x47]),
            ("WAV／AVI", [0x52, 0x49, 0x46, 0x46]),   // RIFF
            ("Ogg", [0x4F, 0x67, 0x67, 0x53])
        ]
        for (name, magic) in binaries where starts(magic) {
            throw fail("\(url.lastPathComponent) 开头是 \(name) 那种格式（不是纯文本）⇒ 请选 .txt/.md")
        }

        // 带 BOM 的先按 BOM 走，并把 BOM 本身摘掉（留着会在第一句前面杵一个不可见字符）。
        func stripBOM(_ s: String) -> String { s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }

        if data.count >= 3, byte(0) == 0xEF, byte(1) == 0xBB, byte(2) == 0xBF,
           let s = String(data: data, encoding: .utf8) {
            return (stripBOM(s), "UTF-8 BOM")
        }
        if data.count >= 2, byte(0) == 0xFF, byte(1) == 0xFE,
           let s = String(data: data, encoding: .utf16LittleEndian) {
            return (stripBOM(s), "UTF-16LE BOM")
        }
        if data.count >= 2, byte(0) == 0xFE, byte(1) == 0xFF,
           let s = String(data: data, encoding: .utf16BigEndian) {
            return (stripBOM(s), "UTF-16BE BOM")
        }
        if let s = String(data: data, encoding: .utf8) { return (s, "UTF-8") }
        if let s = String(data: data, encoding: Self.nsEncoding(.GB_18030_2000)) {
            return (s, "GB18030")
        }
        if let s = String(data: data, encoding: Self.nsEncoding(.big5)) {
            return (s, "Big5")
        }
        // 有损兜底：整篇读进来，坏字节替换成 U+FFFD。坏得多就不是「几个字节不合编码」，
        // 是这文件的口径根本不在这条试法里 ⇒ 宁可不读，也不给他一章乱码去跑链子。
        let lossy = String(decoding: data, as: UTF8.self)
        let bad = lossy.reduce(0) { $1 == "\u{FFFD}" ? $0 + 1 : $0 }
        guard lossy.isEmpty || Double(bad) / Double(lossy.count) < 0.01 else {
            throw fail(String(format: "%@ 有 %d/%d 个字解不出来（超过 1%%）⇒ 不是 UTF-8/GB18030/Big5 任一种，先转成纯文本再选",
                              url.lastPathComponent, bad, lossy.count))
        }
        return (lossy, bad == 0 ? "UTF-8 有损" : "UTF-8 有损（\(bad) 个坏字节）")
    }

    private static func fail(_ text: String) -> NSError {
        VoiceJournal.line("TextFile: \(text)")
        return NSError(domain: "TextFile", code: -1,
                       userInfo: [NSLocalizedDescriptionKey: text])
    }
}
