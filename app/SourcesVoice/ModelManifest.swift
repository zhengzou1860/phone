import Foundation
import CryptoKit

/// 模型包自带的 manifest.txt：一行版本号 + 每图一行 "sha256  大小  文件名"。
/// 存在的理由：手机上可能已经躺着上一版 616 MB 的死包（11/13 张图 ORT 连加载都过不了），
/// 只看"有没有 dit_state_0.onnx"会把死包当就绪，白跑一次装机。逐条 sha256 才能把坏包挡在门外。
enum ModelManifest {
    /// 2026-10-14a = dit_state_1..6 换了 rope 精度：位置 × inv_freq 原来整段在 fp16 里算，
    /// 而那个位置就是绝对 mel 帧号（inv_freq[0]=1.0、分母=1.0 ⇒ 最 Plane 的角度＝帧号本身）。
    /// fp16 在 [2048,4096) 的 ulp 是 2、[4096,8192) 是 4、[8192,16384) 是 8 ⇒ 150 s 一片跑到
    /// 帧号 ~15000 时相位误差最大 4 rad，一个片里 20 帧塌到几个不同位置 ⇒ 吐字糊而音高不糊
    /// （音高走 spks/cond，不走注意力对齐）。RoPE 本该平移不变，所以任何随 offset 变化的
    /// 输出都是纯数值误差。判据：`tools/rope_ab.py` 同内容同噪声只挪起点，旧包 mel 余弦
    /// 1.0000→0.9660、3 kHz 上/下能量比 −12.32→−16.24 dB；补成 fp32 后 cos 1.000000。
    /// 权重一个字节没动，只改 dtype 与 4 处节点 ⇒ 见 `tools/_rope_patch.py`。
    static let version = "2026-10-14a"

    struct Item {
        let name: String
        let size: Int64
        let sha256: String
    }

    static func file(in dir: URL) -> URL { dir.appendingPathComponent("manifest.txt") }
    static var marker: String { ".verified-" + version }

    /// 返回 nil = 全部通过；否则是一条能直接念给用户的原因。
    static func verify(dir: URL, progress: ((Int, Int, String) -> Void)? = nil) -> String? {
        let url = file(in: dir)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "目录里没有 manifest.txt（旧模型包没有这个文件，必须重下）"
        }
        guard let first = text.split(separator: "\n").first, first.contains(version) else {
            return "manifest 版本不是 \(version)：\(text.split(separator: "\n").first ?? "?")"
        }
        let items = parse(text)
        guard !items.isEmpty else { return "manifest.txt 里没有有效条目" }
        for (i, it) in items.enumerated() {
            progress?(i + 1, items.count, it.name)
            let p = dir.appendingPathComponent(it.name)
            guard let sz = (try? FileManager.default.attributesOfItem(atPath: p.path))?[.size] as? NSNumber else {
                return "缺文件 \(it.name)"
            }
            if sz.int64Value != it.size {
                return "\(it.name) 大小 \(sz.int64Value)，清单声明 \(it.size)"
            }
            guard let got = sha256Hex(p) else { return "\(it.name) 读不出来"}
            if got != it.sha256 {
                return "\(it.name) sha256 对不上（下载或落盘被截断）\n  期望 \(it.sha256)\n  实得 \(got)"
            }
        }
        return nil
    }

    static func parseCount(_ dir: URL) -> Int {
        if let text = try? String(contentsOf: file(in: dir), encoding: .utf8) {
            let n = parse(text).count
            if n > 0 { return n }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".onnx") }.count
    }

    /// 校验不通过的目录整清空掉：留着只会让每次 onAppear 再验一遍 700 MB。
    static func purge(dir: URL) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        for f in files {
            try? fm.removeItem(at: dir.appendingPathComponent(f))
        }
        return files.count
    }

    static func parse(_ text: String) -> [Item] {
        var out: [Item] = []
        for line in text.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("#") { continue }
            let parts = s.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let size = Int64(parts[1]) else { continue }
            out.append(Item(name: String(parts[2]), size: size, sha256: String(parts[0])))
        }
        return out
    }

    /// 386 MB 单文件，分块喂；一次读全 Data 会先把内存吃掉。
    static func sha256Hex(_ url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var h = SHA256()
        let chunk = 1 << 20
        while true {
            guard let data = try? fh.read(upToCount: chunk), !data.isEmpty else { break }
            h.update(data: data)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
