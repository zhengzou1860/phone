import Foundation

// 只在 CI 的 mac 上跑：本机（Windows）没有 Swift 工具链，SwapIdents 那套字节格式从来没被真编译器执行过。
// 这一条线每人那一份就是 512 维身份证（latent 是它乘 emap 现算的，不存盘），所以格式只剩四段：
//   SWID | u32 版本 | u32 个数 | f32×
// 手机 10-13 13:16 那趟「存档自检」量出来的那个坑还在：putFloats 当年把每个 float 的第四个字节写成 0，
// 内存往返照样"合法"、模长却掉到 5e-39，画面看着像人、身份全串。这一趟四样一起摊开：
//   ① SwapIdents 写出的字节和参照（按内存原样布局）逐位相同
//   ② SwapIdents 写→SwapIdents 读 逐位相同
//   ③ 参照写→SwapIdents 读 逐位相同（把写这一头先排除掉）
//   ④ 半截包必须整份判读失败；旧版（版本 1，带 18 个权重）那份字节也必须整份拒读
// 下面两个桩是 SwapIdents.swift 里 nearest()／write() 用到的兄弟文件符号，这个测试不碰磁盘也不需要它们真的算。
enum FsxMath { static func cosine(_ a: [Float], _ b: [Float]) -> Double { 0 } }
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

func same(_ a: [Float], _ b: [Float]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0 == $1 }
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

func refU32(_ v: UInt32) -> Data {
    var x = v; var d = Data()
    for _ in 0 ..< 4 { d.append(UInt8(x & 0xFF)); x >>= 8 }
    return d
}

// 一份"像真的"数据：512 维身份证（归一化过，模长该≈1）
var emb = [Float](repeating: 0, count: 512)
for i in 0 ..< 512 { emb[i] = Float(i % 37) / 100.0 - 0.15 + Float(i) / 4000.0 }
let en = norm(emb)
for i in 0 ..< 512 { emb[i] /= Float(en) }
print("CODEC 原始数据 身份证 \(emb.count) 维／模长 \(String(format: "%.4f", norm(emb)))｜第 1 个数 \(f3(emb))")

// ① SwapIdents 自己写出来的字节，和参照字节是不是同一串（第 12~15 字节＝身份证第 1 个数）
let packed = SwapIdents.encode(emb: emb)
let refEmbBytes = refBytes(emb)
var writeOk = packed.count == 12 + refEmbBytes.count
if writeOk {
    for i in 0 ..< refEmbBytes.count where packed[12 + i] != refEmbBytes[i] { writeOk = false }
}
print("CODEC 写 SwapIdents 写→参照读：第 12~15 字节 \(hexOf(packed, 12, 4))"
    + "｜参照该是 \(hexOf(refEmbBytes, 0, 4))｜逐位相同=\(writeOk)"
    + "｜参照读出第 1 个数 \(f3(refFloats(packed.subdata(in: 12 ..< 12 + refEmbBytes.count), emb.count)))")

// ② SwapIdents 自己读回来是什么数（不碰磁盘，纯内存往返）
let e2 = SwapIdents.decode(packed) ?? []
let readOk = same(e2, emb)
print("CODEC 读 SwapIdents 写→SwapIdents 读：身份证 \(e2.count) 维／模长 \(String(format: "%.4f", norm(e2)))"
    + "｜第 1 个数 \(f3(e2))｜逐位相同=\(readOk)")

// ③ 拿参照写出的整份字节喂给 SwapIdents 读（把写这一头先排除掉）
var refPack = Data("SWID".utf8) + refU32(2) + refU32(UInt32(emb.count)) + refEmbBytes
let e3 = SwapIdents.decode(refPack) ?? []
let refReadOk = same(e3, emb)
print("CODEC 交叉 参照写→SwapIdents 读：身份证 \(e3.count) 维／第 1 个数 \(f3(e3))｜逐位相同=\(refReadOk)")

// ④ 半截包必须整份判读失败（不许拿半截身份出片）
let half = refPack.prefix(refPack.count / 2)
let truncOk = SwapIdents.decode(Data(half)) == nil

// ⑤ 旧那版（版本 1、后面还挂着 18 个权重）的字节必须整份拒读：
// 界面按「读不出来→重选一张源脸照片」那条路走，不许把旧包里的身份证当这一版的数用
var oldPack = Data("SWID".utf8) + refU32(1) + refU32(UInt32(emb.count)) + refEmbBytes
oldPack += refU32(18)                                   // 那一版接在后面的张量数
for t in 0 ..< 18 {
    let nb = Data("w\(t)".utf8)
    oldPack += Data([UInt8(nb.count & 0xFF), 0]) + nb
    oldPack += Data([4, 0])
    for x in [1, 4, 1, 1] { oldPack += refU32(UInt32(x)) }
    oldPack += refU32(4) + refBytes([Float](repeating: 0.5, count: 4))
}
let oldOk = SwapIdents.decode(oldPack) == nil
print("CODEC 闸门 半截被拒=\(truncOk)｜旧版(版本 1)被拒=\(oldOk)（旧包 \(oldPack.count) 字节）")

let verdict = (writeOk && readOk && refReadOk && truncOk && oldOk) ? "PASS" : "FAIL"
print("CODEC-VERDICT \(verdict) 写逐位=\(writeOk)｜往返逐位=\(readOk)｜交叉逐位=\(refReadOk)"
    + "｜半截被拒=\(truncOk)｜旧版被拒=\(oldOk)")
