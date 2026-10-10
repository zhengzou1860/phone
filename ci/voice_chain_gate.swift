import Foundation

/// ChainDriver 的 macOS 数值对拍闸门。CI 里被复制成 main.swift 编成裸可执行文件，
/// 所以这里自带一份 VoiceJournal（VoiceCommon.swift 那份 import UIKit，macOS 裸程序编不进去）。
///
/// 为什么逐段比而不是只比最后一帧波形：PC 侧实测过，只把 fbank/pmel 抖
/// ±6.58e-05 / ±1.49e-06（= Swift 前端对 torch 的真实残差，前端闸门天天在量），
/// 整链输出的最大逐元素差就冲到 1.79（信号峰值才 1.75）、余弦掉到 0.968。
/// 也就是说端到端逐元素比根本测不出「Swift 有没有算错」，只会测出「前端残差被放大」。
/// 所以每个阶段都直接吃 python 落盘的中间量（Fixtures/chain_*.f32），
/// 输入逐字节相同 ⇒ 两边的差只可能是 Swift 自己的逻辑差。
///
/// 阈值是首轮量出来的余量，不是精度上限：python 那边 onnxruntime 1.19.2、
/// 这里链接的是 1.30.0，同图不同版本的 kernel 本来就有残差，所以第一版放得宽
/// （rel_max 0.2 / cos 0.99），每段都另印一行 SUGGEST（= 实测的 3 倍），
/// 看到真数以后按那一行收紧。
enum VoiceJournal {
    static func line(_ text: String) { print("  [journal] " + text) }
}

// MARK: - 命令行与 fixture 读取

let argv = CommandLine.arguments
func optionValue(_ flag: String, _ fallback: String) -> String {
    guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return fallback }
    return argv[i + 1]
}

let modelsDir = URL(fileURLWithPath: optionValue("--models", "models"))
let fixDir = URL(fileURLWithPath: optionValue("--fixtures", "Fixtures"))

func fixtureData(_ name: String) -> Data {
    let url = fixDir.appendingPathComponent(name)
    do { return try Data(contentsOf: url) } catch {
        FileHandle.standardError.write("FATAL fixture 读不到：\(url.path)（\(error)）\n".data(using: .utf8)!)
        exit(3)
    }
}

func fixtureFloats(_ name: String) -> [Float] {
    let d = fixtureData(name)
    let n = d.count / 4
    var out = [Float](repeating: 0, count: n)
    d.withUnsafeBytes { raw in
        for i in 0..<n { out[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: Float.self) }
    }
    return out
}

// MARK: - 指标

struct Metric {
    var nGot: Int
    var nExp: Int
    var relMax: Double      // max|差| / 期望峰值：把「差多大」和「信号多大」放一个尺子上
    var cos: Double
    var peakGot: Double
    var rmsGot: Double
    var bad: Int            // NaN / inf 的个数
}

func measure(_ got: [Float], _ exp: [Float]) -> Metric {
    let n = min(got.count, exp.count)
    var diff = 0.0, dot = 0.0, na = 0.0, nb = 0.0, peak = 0.0, sumsq = 0.0, expPeak = 0.0
    var bad = 0
    for i in 0..<n {
        let a = got[i], b = exp[i]
        if a.isNaN || a.isInfinite { bad += 1 }
        let da = Double(a), db = Double(b)
        let d = abs(da - db)
        if d > diff { diff = d }
        if abs(da) > peak { peak = abs(da) }
        if abs(db) > expPeak { expPeak = abs(db) }
        sumsq += da * da
        dot += da * db
        na += da * da
        nb += db * db
    }
    return Metric(nGot: got.count, nExp: exp.count,
                  relMax: expPeak > 0 ? diff / expPeak : diff,
                  cos: (na > 0 && nb > 0) ? dot / (na.squareRoot() * nb.squareRoot()) : -1,
                  peakGot: peak, rmsGot: (n > 0 ? (sumsq / Double(n)).squareRoot() : -1), bad: bad)
}

var failures: [String] = []

/// 报一行机器可读的 GATE，再按需判过/不过。hard=false 只印数不拦路。
func gate(_ name: String, _ m: Metric, relMaxLimit: Double, cosLimit: Double, hard: Bool = true,
          note: String = "") {
    let f = { (v: Double) in String(format: "%.6g", v) }
    print(String(format: "GATE name=%@ got=%d exp=%d rel_max=%@ cos=%@ peak=%@ rms=%@ nan=%d",
                 name, m.nGot, m.nExp, f(m.relMax), f(m.cos), f(m.peakGot), f(m.rmsGot), m.bad))
    if !note.isEmpty { print("     note " + note) }
    print(String(format: "SUGGEST name=%@ rel_max<=%@ cos>=%@", name, f(m.relMax * 3 + 1e-6), f(m.cos * 0.97)))
    var why: [String] = []
    if m.nGot != m.nExp || m.nGot == 0 { why.append("长度对不上：我 \(m.nGot) 期望 \(m.nExp)") }
    if m.bad > 0 { why.append("NaN/inf \(m.bad) 个") }
    if m.relMax > relMaxLimit { why.append(String(format: "rel_max %@ > %@", f(m.relMax), f(relMaxLimit))) }
    if m.cos < cosLimit { why.append(String(format: "cos %@ < %@", f(m.cos), f(cosLimit))) }
    if why.isEmpty {
        print("     过 " + name)
    } else if hard {
        print("     不过 " + name + "：" + why.joined(separator: "，"))
        failures.append(name)
    } else {
        print("     （只报数，不拦路）" + name + "：" + why.joined(separator: "，"))
    }
}

// MARK: - 帧主序 / 通道主序

let nMels = MelFrontEnd.nMels

/// [帧,80] → [80,帧]
func toChannels(_ rows: [Float], frames: Int) -> [Float] {
    var out = [Float](repeating: 0, count: rows.count)
    for t in 0..<frames {
        let s = t * nMels
        for c in 0..<nMels { out[c * frames + t] = rows[s + c] }
    }
    return out
}

/// [80,帧] → [帧,80]
func toFrames(_ cm: [Float], frames: Int) -> [Float] {
    var out = [Float](repeating: 0, count: cm.count)
    for c in 0..<nMels {
        let s = c * frames
        for t in 0..<frames { out[t * nMels + c] = cm[s + t] }
    }
    return out
}

// MARK: - 开跑

let src = fixtureFloats("chain_src.f32")
let ref = fixtureFloats("chain_ref.f32")
let noise = fixtureFloats("chain_noise.f32")
let expFB = fixtureFloats("chain_fbank.f32")
let expSpk = fixtureFloats("chain_spks.f32")
let expPM = fixtureFloats("chain_prompts.f32")
let expBN = fixtureFloats("chain_bn.f32")
let expMel = fixtureFloats("chain_mel.f32")      // 通道主序，且已经过 (+1)/2
let expWav = fixtureFloats("chain_expect.f32")
let basis = fixtureFloats("librosa_mel_basis.f32")
let melFrames = expMel.count / nMels
let fbFrames = expFB.count / nMels
print("fixtures: src=\(src.count) ref=\(ref.count) fb=\(fbFrames)x\(nMels) bn=\(expBN.count / 256)x256 mel=\(melFrames)x\(nMels) wav=\(expWav.count)")

let drv: ChainDriver
do {
    drv = try ChainDriver(modelDir: modelsDir)
} catch {
    print("FATAL ChainDriver 起不来（模型目录 \(modelsDir.path)）：\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    exit(4)
}
drv.onStage = { print("  [stage] " + $0) }
drv.noiseOverride = noise
drv.melBasisOverride = basis
let tAll = Date()

/// 每段都真跑，报错就把原文印出来（手机上只能靠这一行文本复盘，这里没这个限制，更不能省）。
func stage<T>(_ name: String, _ body: () throws -> T) -> T? {
    do { return try body() } catch {
        print("STAGE FAIL \(name)：\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        failures.append(name)
        return nil
    }
}

// ⓪ Swift 自己的前端（这一段前端闸门在 iOS target 上天天量，这里只当输入自检，不拦路）
let myFB = MelFrontEnd.kaldiFbank(AudioProcessor.scaled(src))
let myPM = MelFrontEnd.promptMel(ref, basis: basis)
gate("fbank", measure(myFB, expFB), relMaxLimit: 1e-3, cosLimit: 0.99, hard: false,
     note: "输入自检：这点残差是链路已知的地板来源，逐段比用的是 python 那份 fbank，不受它影响")
gate("pmel", measure(myPM, expPM), relMaxLimit: 1e-3, cosLimit: 0.99, hard: false)

// ① 音色嵌入：吃 chain_ref.f32，和 python 的 spk_emb 同一个图同一个输入
if let emb = stage("emb", { try drv.speakerEmbedding(ref) }), case .f32(let ed, let ev) = emb {
    print("  emb dims=\(ed)")
    gate("emb", measure(ev, expSpk), relMaxLimit: 0.2, cosLimit: 0.99)
}

// ② 内容编码：吃 python 落盘的 fbank 原值（不是 Swift 自己算的那份）
var bnRows: ChainRows?
if let r = stage("bn", { try drv.encode(fbank: expFB, frames: fbFrames) }) {
    bnRows = r
    gate("bn", measure(r.data, expBN), relMaxLimit: 0.2, cosLimit: 0.99,
         note: "Swift \(r.frames)x\(r.dim) vs python \(expBN.count / 256)x256")
}

// ③ 去噪：吃 python 的 bn / spks / prompt mel + 同一串噪声
let spkTensor: OrtTensor = .f32(dims: [1, expSpk.count], data: expSpk)
if let rows = bnRows, let r = stage("mel", { try drv.denoise(bn: rows, spks: spkTensor, prompts: expPM) }) {
    // python 存的是 ((mel+1)/2) 之后、通道主序的 mel_v，比较前先做同样两步
    var scaled = r.data
    for i in 0..<scaled.count { scaled[i] = (scaled[i] + 1.0) * 0.5 }
    gate("mel", measure(toChannels(scaled, frames: r.frames), expMel),
         relMaxLimit: 0.2, cosLimit: 0.99, note: "Swift \(r.frames)x\(r.dim) 已换通道主序并 (+1)/2")
}

// ④ 声码：吃 python 的 mel（先还原成 vocos 要的「未 (+1)/2」口径）
if let r = stage("wav", {
        try drv.vocode(ChainRows(data: toFrames(expMel.map { $0 * 2.0 - 1.0 }, frames: melFrames),
                                 frames: melFrames, dim: nMels))
    }) {
    gate("wav", measure(r, expWav), relMaxLimit: 0.2, cosLimit: 0.99,
         note: "逐字节相同的 mel 进 vocos；这一段的 cos 就是『同样输入下 Swift 链和 python 链差多少』的下限")
}

// ⑤ 端到端：Swift 自己算前端 + 自己灌噪声。已知会被前端残差放大，只报数不拦路，
//    判读依据是 PC 侧量的地板（只抖前端 → cos 0.968 / max_abs 1.79）。
if let e2e = stage("e2e", { try drv.convert(source: src, reference: ref) }) {
    gate("e2e", measure(e2e, expWav), relMaxLimit: 1e9, cosLimit: 0.85,
         note: "地板：只抖前端（6.58e-05 / 1.49e-06）就到 cos 0.968；这一格只要求别掉到结构错的范围")
}

print(String(format: "总用时 %.1f s", Date().timeIntervalSince(tAll)))
if failures.isEmpty {
    print("CHAIN GATE PASS")
    exit(0)
}
print("CHAIN GATE FAIL: " + failures.joined(separator: " / "))
exit(1)
