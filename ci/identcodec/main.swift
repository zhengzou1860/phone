import Foundation

// 只在 CI 的 mac 上跑：本机（Windows）没有 Swift 工具链，SwapIdents 那套字节格式从来没被真编译器执行过。
// 手机 10-13 13:16 那趟「存档自检」给的数是——写进去前 身份证模长 1.0000／18 权重合起来 87.198，
// encode→decode 之后 0.0000／0.000，而盘上第 13~16 个字节是 2c c9 aa 00（不是全 0）。
// 所以要么"写出去的那串字节不是那个数"，要么"读回来的不是那串字节"。这一趟把四样一起摊开：
//   参照写→SwapIdents 读、SwapIdents 写→参照读、SwapIdents 写→SwapIdents 读、截断一半必须整份判读失败。
// 两个桩是 SwapIdents.swift 里报错文本和 nearest() 用到的兄弟文件符号，这个测试不碰磁盘也不需要它们真的算。
enum SwapMath { static func cosine(_ a: [Float], _ b: [Float]) -> Double { 0 } }
enum SwapFacts { static func diskFreeGB() -> String { "-" } }

func norm(_ v: [Float]) -> Double {
    var s = 0.0
    for x in v { s += Double(x) * Double(x) }
    return s.squareRoot()
}

func hexOf(_ d: Data, _ from: Int, _ n: Int) -> String {
    guard d.count >= from + n else { return "字节不够" }
    return d[from ..< from + n].map { String(format: "%02x", $0) }.joined(separator: " ")
}

func f3(_ v: [Float]) -> String {
    v.prefix(3).map { String(format: "%.6e", $0) }.joined(separator: " ")
}

// 参照实现：不碰 SwapIdents 的两个函数，按本机内存原样布局读写（iOS 与这台 mac 都是小端）
func refBytes(_ a: [Float]) -> Data {
    var out = Data()
    for f in a { withUnsafeBytes(of: f) { out.append(contentsOf: $0) } }
    return out
}

func refFloats(_ d: Data, _ n: Int) -> [Float] {
    var out = [Float](repeating: 0, count: n)
    d.withUnsafeBytes { raw in
        for i in 0 ..< n where raw.count >= i * 4 + 4 {
            out[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: Float.self)
        }
    }
    return out
}

// 一份"像真的"数据：512 维身份证（归一化过，模长该≈1）＋ 18 个形状各异的权重
var emb = [Float](repeating: 0, count: 512)
for i in 0 ..< 512 { emb[i] = Float(i % 37) / 100.0 - 0.15 + Float(i) / 4000.0 }
let en = norm(emb)
for i in 0 ..< 512 { emb[i] /= Float(en) }

var ws: [(name: String, dims: [Int], data: [Float])] = []
for t in 0 ..< 18 {
    let c = 4 + 2 * t
    var d = [Float](repeating: 0, count: c)
    for i in 0 ..< c { d[i] = Float(Double(i) * 0.013 + Double(t) * 0.7 - 3.0) }
    ws.append(("w\(t)", [1, c, 1, 1], d))
}
let total = emb.count + ws.reduce(0) { $0 + $1.data.count }
let wn = norm(ws.flatMap { $0.data })
print("CODEC 原始数据 身份证 \(emb.count) 维／模长 \(String(format: "%.4f", norm(emb)))"
    + "｜权重 \(ws.count) 个／\(total) 数／合起来模长 \(String(format: "%.3f", wn))｜第 1 个数 \(f3(emb))")

// ① SwapIdents 自己写出来的字节，和参照字节是不是同一串（第 13~16 字节＝身份证第 1 个数）
let packed = SwapIdents.encode(emb: emb, weights: ws)
let refEmbBytes = refBytes(emb)
var writeOk = packed.count >= 12 + refEmbBytes.count
if writeOk {
    for i in 0 ..< refEmbBytes.count where packed[12 + i] != refEmbBytes[i] { writeOk = false }
}
print("CODEC 写 SwapIdents 写→参照读：第 12~15 字节 \(hexOf(packed, 12, 4))"
    + "｜参照该是 \(hexOf(refEmbBytes, 0, 4))｜逐位相同=\(writeOk)"
    + "｜参照读出第 1 个数 \(f3(refFloats(packed.subdata(in: 12 ..< 12 + refEmbBytes.count), emb.count)))")

// ② SwapIdents 自己读回来是什么数（不碰磁盘，纯内存往返）
let (e2, w2) = (SwapIdents.decode(packed) ?? ([Float](), []))
let readOk = e2.count == emb.count && w2.count == ws.count
    && zip(e2, emb).allSatisfy { $0 == $1 }
    && zip(w2.flatMap { $0.data }, ws.flatMap { $0.data }).allSatisfy { $0 == $1 }
print("CODEC 读 SwapIdents 写→SwapIdents 读：身份证 \(e2.count) 维／模长 \(String(format: "%.4f", norm(e2)))"
    + "｜权重 \(w2.count) 个／合起来模长 \(String(format: "%.3f", norm(w2.flatMap { $0.data })))"
    + "｜第 1 个数 \(f3(e2))｜逐位相同=\(readOk)")

// ③ 拿参照写出的整份字节喂给 SwapIdents 读（把写这一头先排除掉）
var refPack = Data("SWID".utf8)
func refU32(_ v: UInt32) -> Data { var x = v; var d = Data(); for _ in 0 ..< 4 { d.append(UInt8(x & 0xFF)); x >>= 8 }; return d }
refPack += refU32(1) + refU32(UInt32(emb.count)) + refEmbBytes + refU32(UInt32(ws.count))
for t in ws {
    let nb = Data(t.name.utf8)
    refPack += Data([UInt8(nb.count & 0xFF), UInt8((nb.count >> 8) & 0xFF)]) + nb
    refPack += Data([UInt8(t.dims.count & 0xFF), UInt8((t.dims.count >> 8) & 0xFF)])
    for x in t.dims { refPack += refU32(UInt32(x)) }
    refPack += refU32(UInt32(t.data.count)) + refBytes(t.data)
}
let (e3, w3) = (SwapIdents.decode(refPack) ?? ([Float](), []))
let refReadOk = e3.count == emb.count && zip(e3, emb).allSatisfy { $0 == $1 }
    && w3.count == ws.count && zip(w3.flatMap { $0.data }, ws.flatMap { $0.data }).allSatisfy { $0 == $1 }
print("CODEC 交叉 参照写→SwapIdents 读：身份证 \(e3.count) 维／模长 \(String(format: "%.4f", norm(e3)))"
    + "｜权重 \(w3.count) 个／第 1 个数 \(f3(e3))｜逐位相同=\(refReadOk)")

// ④ 半截包必须整份判读失败（不许拿半截权重出片）
let half = refPack.prefix(refPack.count / 2)
let truncOk = SwapIdents.decode(Data(half)) == nil

let verdict = (writeOk && readOk && refReadOk && truncOk) ? "PASS" : "FAIL"
print("CODEC-VERDICT \(verdict) 写逐位=\(writeOk)｜往返逐位=\(readOk)｜交叉逐位=\(refReadOk)｜半截被拒=\(truncOk)")
