import CryptoKit
import Foundation

/// 一个人的身份落成一份能选能删能改名的存档：18 个权重 + 512 维身份证。
/// 身份证也要存：出片线每 30 帧拿它复测一次「换后 <-> 源」，只存权重的那份存档会让这把尺子当场失效。
///
/// 落在 Documents/swap_idents/<hash12>.pak，显示名另放 <hash12>.name：改名只写那几十字节，不动 1 MB 级的包。
/// hash 取身份证 512 个 float 原始字节的 SHA-256 前 12 位——它只是文件名和"同一张照片别存两遍"的依据，
/// 不是"同一个人"的判定：同一个人再拍一张，网给的嵌入几乎相同而不逐位相同，hash 会变、会另开一格。
enum SwapIdents {
    struct Item {
        var id: String
        var name: String
        var bytes: Int
        var mtime: Date
    }

    struct Pack {
        var name: String
        var emb: [Float]
        var weights: [(name: String, dims: [Int], data: [Float])]
    }

    private static let version: UInt32 = 1

    static var dir: URL? {
        guard let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let t = d.appendingPathComponent("swap_idents", isDirectory: true)
        if !FileManager.default.fileExists(atPath: t.path) {
            do { try FileManager.default.createDirectory(at: t, withIntermediateDirectories: true) }
            catch { return nil }
        }
        return t
    }

    private static func pak(_ id: String) -> URL? {
        dir?.appendingPathComponent("\(id).pak")
    }

    private static func sidecar(_ id: String) -> URL? {
        dir?.appendingPathComponent("\(id).name")
    }

    static func hash(emb: [Float]) -> String {
        let bytes: [UInt8] = emb.withUnsafeBufferPointer { p in
            var u = [UInt8](repeating: 0, count: p.count * 4)
            for k in 0 ..< p.count {
                let b = p[k].bitPattern
                u[k * 4] = UInt8(b & 0xFF)
                u[k * 4 + 1] = UInt8((b >> 8) & 0xFF)
                u[k * 4 + 2] = UInt8((b >> 16) & 0xFF)
                u[k * 4 + 3] = UInt8((b >> 24) & 0xFF)
            }
            return u
        }
        let digest = SHA256.hash(data: Data(bytes))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// 列表按存下的先后排（mtime 升序）：他记的是"第几个"，不是文件名。
    static func list() -> [Item] {
        guard let d = dir else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let all = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: keys, options: []) else {
            return []
        }
        var out: [Item] = []
        for u in all where u.pathExtension == "pak" {
            let id = u.deletingPathExtension().lastPathComponent
            let r = try? u.resourceValues(forKeys: Set(keys))
            out.append(Item(id: id, name: displayName(id),
                            bytes: r?.fileSize ?? 0, mtime: r?.contentModificationDate ?? .distantPast))
        }
        return out.sorted { $0.mtime < $1.mtime }
    }

    static func displayName(_ id: String) -> String {
        guard let u = sidecar(id),
              let s = try? String(contentsOf: u, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return id }
        return s
    }

    /// 存一份。同 hash 已在列表里就不重写作废（他可能连选同一张照片），只报回那一格。
    static func save(emb: [Float], weights: [(name: String, dims: [Int], data: [Float])],
                     taken: [Item]) -> (id: String, name: String, isNew: Bool, bytes: Int, note: String) {
        guard !emb.isEmpty, !weights.isEmpty else {
            return ("", "", false, 0, "身份是空的，存不了（网没给嵌入或权重没装成）")
        }
        let id = hash(emb: emb)
        guard let u = pak(id), let s = sidecar(id) else {
            return ("", "", false, 0, "建不出存档目录（Documents/swap_idents）")
        }
        if let one = taken.first(where: { $0.id == id }) {
            return (id, one.name, false, one.bytes, "「\(one.name)」早就在列表里了（同一张照片，没重存）")
        }
        let name = nextName(taken)
        let data = encode(emb: emb, weights: weights)
        do { try data.write(to: u) } catch {
            return (id, name, false, 0, "存不下：写 \(u.lastPathComponent) 失败 \(error)（磁盘可用 \(SwapFacts.diskFreeGB()) GB）")
        }
        try? name.write(to: s, atomically: true, encoding: .utf8)
        let bytes = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? data.count
        return (id, name, true, bytes,
                "存成「\(name)」\(String(format: "%.2f", Double(bytes) / 1_048_576)) MB，下次直接选他、不必再挑照片")
    }

    private static func nextName(_ taken: [Item]) -> String {
        let used = Set(taken.map { $0.name })
        var n = 1
        while used.contains("人 \(n)") { n += 1 }
        return "人 \(n)"
    }

    static func load(id: String) -> Pack? {
        guard let u = pak(id), let data = try? Data(contentsOf: u),
              let (emb, ws) = decode(data) else { return nil }
        return Pack(name: displayName(id), emb: emb, weights: ws)
    }

    static func rename(id: String, to raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "名字是空的，没改" }
        guard let u = sidecar(id) else { return "拿不到存档目录，没改" }
        let short = String(t.prefix(24))
        let clash = list().first { $0.id != id && $0.name == short }
        let name = clash == nil ? short : "\(short)-\(id.suffix(4))"
        do {
            try name.write(to: u, atomically: true, encoding: .utf8)
            return clash == nil ? "改名成「\(name)」" : "这个名字别人占了，记成「\(name)」"
        } catch {
            return "改名没写进去：\(error)"
        }
    }

    static func remove(id: String) -> String {
        guard let u = pak(id) else { return "拿不到存档目录，没删" }
        let fm = FileManager.default
        let name = displayName(id)
        let r = try? u.resourceValues(forKeys: [.fileSizeKey])
        let gone = r?.fileSize ?? 0
        do { try fm.removeItem(at: u) } catch { return "「\(name)」没删掉：\(error)" }
        if let s = sidecar(id) { try? fm.removeItem(at: s) }
        return "删了「\(name)」，还回 \(String(format: "%.2f", Double(gone) / 1_048_576)) MB"
    }

    // MARK: - 包的字节格式

    /// SWID | u32 版本 | u32 嵌入个数 | f32×| u32 张量数 | 每条：u16 名长 + 名 + u16 秩 + i32×秩 + i32 个数 + f32×个数
    /// 整数一律小端逐字节写、float 按 bitPattern 拆字节：两头都不碰指针类型，也就没有对齐问题。
    static func encode(emb: [Float], weights: [(name: String, dims: [Int], data: [Float])]) -> Data {
        var d = Data("SWID".utf8)
        putU32(&d, version)
        putU32(&d, UInt32(emb.count))
        putFloats(&d, emb)
        putU32(&d, UInt32(weights.count))
        for w in weights {
            let nb = Data(w.name.utf8)
            putU16(&d, UInt16(truncatingIfNeeded: nb.count))
            d.append(nb)
            putU16(&d, UInt16(truncatingIfNeeded: w.dims.count))
            for x in w.dims { putI32(&d, Int32(truncatingIfNeeded: x)) }
            putI32(&d, Int32(truncatingIfNeeded: w.data.count))
            putFloats(&d, w.data)
        }
        return d
    }

    static func decode(_ d: Data) -> ([Float], [(name: String, dims: [Int], data: [Float])])? {
        var p = Cursor(d)
        guard p.take(4) == Data("SWID".utf8), let v = p.u32(), v == version else { return nil }
        guard let en = p.u32(), let emb = p.floats(Int(en)) else { return nil }
        guard let tn = p.u32() else { return nil }
        var ws: [(name: String, dims: [Int], data: [Float])] = []
        for _ in 0 ..< Int(tn) {
            guard let nl = p.u16(), let nd = p.take(Int(nl)), let nm = String(data: nd, encoding: .utf8),
                  let rn = p.u16() else { return nil }
            var dims: [Int] = []
            for _ in 0 ..< Int(rn) {
                guard let x = p.i32(), x >= 1 else { return nil }
                dims.append(Int(x))
            }
            guard let cn = p.i32(), cn >= 0, let data = p.floats(Int(cn)) else { return nil }
            guard dims.reduce(1, *) == data.count else { return nil }
            ws.append((nm, dims, data))
        }
        guard !ws.isEmpty else { return nil }
        return (emb, ws)
    }

    private static func putU16(_ d: inout Data, _ v: UInt16) { putInt(&d, UInt64(v), 2) }
    private static func putU32(_ d: inout Data, _ v: UInt32) { putInt(&d, UInt64(v), 4) }
    private static func putI32(_ d: inout Data, _ v: Int32) { putInt(&d, UInt64(bitPattern: Int64(v)), 4) }

    private static func putInt(_ d: inout Data, _ v: UInt64, _ bytes: Int) {
        var x = v
        for _ in 0 ..< bytes {
            d.append(UInt8(x & 0xFF))
            x >>= 8
        }
    }

    private static func putFloats(_ d: inout Data, _ a: [Float]) {
        for f in a {
            var b = f.bitPattern
            d.append(UInt8(b & 0xFF)); b >>= 8
            d.append(UInt8(b & 0xFF)); b >>= 8
            d.append(UInt8(b & 0xFF)); b >>= 8
            d.append(UInt8(b >> 24))
        }
    }
}

/// 只往前走的字节游标：任何一处越界或形状对不上就整份判读失败，让调用方走"重选照片"那条路——
/// 不许拿半截权重出片，那种画面照样"像个人"，只有身份会串。
private struct Cursor {
    private let u: [UInt8]
    private var i: Int = 0

    init(_ d: Data) { u = [UInt8](d) }

    mutating func take(_ n: Int) -> Data? {
        guard n >= 0, i + n <= u.count else { return nil }
        let s = Data(u[i ..< i + n])
        i += n
        return s
    }

    private mutating func u64(_ bytes: Int) -> UInt64? {
        guard let s = take(bytes) else { return nil }
        var v: UInt64 = 0
        var sh = 0
        for b in s {
            v |= UInt64(b) << sh
            sh += 8
        }
        return v
    }

    mutating func u16() -> UInt16? { u64(2).map { UInt16(truncatingIfNeeded: $0) } }
    mutating func u32() -> UInt32? { u64(4).map { UInt32(truncatingIfNeeded: $0) } }
    mutating func i32() -> Int32? { u32().map { Int32(bitPattern: $0) } }

    mutating func floats(_ n: Int) -> [Float]? {
        guard n >= 0, let s = take(n * 4) else { return nil }
        var out = [Float](repeating: 0, count: n)
        var k = 0
        var sh = 0
        var bits: UInt32 = 0
        for b in s {
            bits |= UInt32(b) << sh
            sh += 8
            if sh == 32 {
                out[k] = Float(bitPattern: bits)
                k += 1
                bits = 0
                sh = 0
            }
        }
        return out
    }
}
