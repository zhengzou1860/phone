import Foundation

/// ChainDriver 的 macOS 数值对拍闸门。CI 里被复制成 main.swift 编成裸可执行文件，
/// 所以这里自带一份 VoiceJournal（VoiceCommon.swift 那份 import UIKit，macOS 裸程序编不进去）。
///
/// 为什么逐段比而不是只比最后一帧波形：PC 侧实测过，只把 fbank/pmel 抖
/// ±6.58e-05 / ±1.49e-06（= Swift 前端对 torch 的真实残差，前端闸门天天在量），
/// 整链输出的最大逐元素差就到 0.576、余弦掉到 0.9958（信号峰值 1.75、rms 0.211）。
/// 也就是说端到端逐元素比测不出「Swift 有没有算错」，只会测出「前端残差被放大」，
/// 所以每个阶段都直接吃 python 落盘的中间量（Fixtures/chain_*.f32），
/// 输入逐字节相同 ⇒ 两边的差只可能是 Swift 自己的逻辑差。
///
/// 这一轮就是这么把唯一的分歧夹出来的：③ 报 rel_max 0.91814 / cos 0.882743，
/// 而 ④ 喂逐字节相同的 mel 时 cos 0.999997。根因不在 Swift——tools/_f16_ab.py 的
/// base = {"x": x.numpy()} 是张量的 numpy 视图，x = x - (t-r)*res[0] 出块新张量，
/// 第二个 euler 步喂进图的还是初始噪声。PC 上「标准 euler vs 那份旧 fixture」量到
/// rel_max 0.9183 / cos 0.882823，和 CI 的读数对到小数点后四位（差的 2e-4 就是
/// ORT 1.19.2 与 1.30.0 的 kernel 残差）。_f16_ab 已改成标准 euler、fixture 重生成。
///
/// 阈值按首轮实测放 3~40 倍余量，每段另印一行 SUGGEST（= 实测 3 倍）继续收紧。
/// 结构错（通道序、图选错、少喂 cache/kv）会当场红。
///
/// fixture 换成标准 euler 那一轮（716f80c）的读数：fbank 1.58e-06 / pmel 1.33e-06 /
/// emb 0.0338 / bn 9.9e-04 / **mel 0.00432（原来是 0.918）**/ wav 0.01167，cos 全 ≥0.9999。
/// 只剩 e2e 那格：rel_max 0.889 / cos 0.922。
///
/// e2e 这一格按设计只报数不拦路，理由是链路是**混沌**的：输入逐字节 pin 死（src/ref/
/// noise/melBasis 全从 fixture 读），只剩前端 3.6e-05 的残差，放大 4 个量级就到 0.9 这一档；
/// 而且这只讲了一半——同一条链换个 ORT 版本（kernel 残差 2e-4）端到端也会落成完全不同的
/// 波形。所以「Swift 的波形和 python 逐点不像」既不是 bug 的证据，也不可能是通过的条件。
/// 判对错只看 ⓪~④ 那五段各自吃同一份输入的逐元素差；真机上的好坏只能靠耳朵 + CER/音色那两把尺。
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
// chain_prompts.f32 是钉死的 [1,150,80]，Swift 这份是整段（501 帧），链路上只取前 150 帧，
// 所以也只比前 150 帧——比全长必报一条假「长度对不上」。
gate("pmel", measure(Array(myPM.prefix(expPM.count)), expPM), relMaxLimit: 1e-3, cosLimit: 0.99,
     hard: false, note: "只比前 \(expPM.count / nMels) 帧：DiT 的 prompts 就吃这一段")

// ① 音色嵌入：吃 chain_ref.f32，和 python 的 spk_emb 同一个图同一个输入
if let emb = stage("emb", { try drv.speakerEmbedding(ref) }), case .f32(let ed, let ev) = emb {
    print("  emb dims=\(ed)")
    gate("emb", measure(ev, expSpk), relMaxLimit: 0.1, cosLimit: 0.995)      // 实测 0.0338 / 0.99931
}

// ② 内容编码：吃 python 落盘的 fbank 原值（不是 Swift 自己算的那份）
var bnRows: ChainRows?
if let r = stage("bn", { try drv.encode(fbank: expFB, frames: fbFrames) }) {
    bnRows = r
    gate("bn", measure(r.data, expBN), relMaxLimit: 0.005, cosLimit: 0.999,   // 实测 9.9e-04 / 1.000000
         note: "Swift \(r.frames)x\(r.dim) vs python \(expBN.count / 256)x256")
}

// ③ 去噪：吃 python 的 bn / spks / prompt mel + 同一串噪声
let spkTensor: OrtTensor = .f32(dims: [1, expSpk.count], data: expSpk)
if let rows = bnRows, let r = stage("mel", { try drv.denoise(bn: rows, spks: spkTensor, prompts: expPM) }) {
    // python 存的是 ((mel+1)/2) 之后、通道主序的 mel_v，比较前先做同样两步
    var scaled = r.data
    for i in 0..<scaled.count { scaled[i] = (scaled[i] + 1.0) * 0.5 }
    // 实测跨 ORT 版本约 2e-4（PC 上标准 euler 对同一份 fixture 量出来的）
    gate("mel", measure(toChannels(scaled, frames: r.frames), expMel),
         relMaxLimit: 0.02, cosLimit: 0.998, note: "Swift \(r.frames)x\(r.dim) 已换通道主序并 (+1)/2")
}

// ④ 声码：吃 python 的 mel（先还原成 vocos 要的「未 (+1)/2」口径）
if let r = stage("wav", {
        try drv.vocode(ChainRows(data: toFrames(expMel.map { $0 * 2.0 - 1.0 }, frames: melFrames),
                                 frames: melFrames, dim: nMels))
    }) {
    gate("wav", measure(r, expWav), relMaxLimit: 0.05, cosLimit: 0.999,       // 实测 0.0138 / 0.999997
         note: "逐字节相同的 mel 进 vocos；这一段的 cos 就是『同样输入下 Swift 链和 python 链差多少』的下限")
}

// ⑤ 端到端：Swift 自己算前端、其余输入逐字节 pin 死（src/ref/noise/melBasis 全是 fixture）。
//    这一格的 rel_max / cos 按设计不拦路（链路混沌，见文件头），拦的是「出来的还是不是一段
//    同样长的、音量正常的语音」——这三件在混沌下仍然有信息。
if let e2e = stage("e2e", { try drv.convert(source: src, reference: ref) }) {
    gate("e2e", measure(e2e, expWav), relMaxLimit: 1e9, cosLimit: -1,
         note: "实测 0.889 / 0.922（只抖前端到 0.576 / 0.9958）——只印数，逐点比对在混沌链上没有信息")
    let rms = { (a: [Float]) in
        var s = 0.0
        for v in a { s += Double(v) * Double(v) }
        return (s / Double(a.count)).squareRoot()
    }
    let r = rms(e2e) / rms(expWav)
    if r < 0.25 || r > 4 {
        print(String(format: "     不过 e2e：音量比 rms %.4g（应在 [0.25, 4]）= 输出成静音或炸掉了", r))
        failures.append("e2e")
    } else {
        print(String(format: "     过 e2e：音量比 rms %.4g", r))
    }
}

// MARK: - ⑥ 录音那一段的重采样尺
//
// 手机录的是设备原生格式（iPhone 上 48 kHz Float32），模型这一侧钉在 16 kHz，中间只有
// AVAudioConverter 这一步。这一步以前一个数都没有：降采样要是把 12 kHz 的能量不滤就折进
// 带内，fbank 看到的就多出一层尖峰，而这在逐段闸门里根本照不出来（那五段吃的是 fixture，
// 不经过重采样）。所以这里用「48k 写盘 → loadWAV16K 读回」原样走一遍 app 的路。
// 首轮只出数、不拦路——阈值等这轮读数定了再挂。

/// 1 s 窗的 Goertzel 幅度。整数 Hz 在 16000 点里正好整数个周期 ⇒ 无泄漏，读数就是正弦振幅。
/// 窗取末尾：转换器滤波器的建立段在前面，别把它算进幅度里。
func toneAmp(_ x: [Float], _ hz: Int) -> Double {
    let n = 16000
    guard x.count >= n else { return -1 }
    let start = x.count - n
    let w = 2.0 * Double.pi * Double(hz) / Double(n)
    var s1 = 0.0, s2 = 0.0
    let coeff = 2.0 * cos(w)
    for i in 0..<n {
        let s0 = Double(x[start + i]) + coeff * s1 - s2
        s2 = s1
        s1 = s0
    }
    let re = s1 - s2 * cos(w)
    let im = s2 * sin(w)
    return 2.0 * (re * re + im * im).squareRoot() / Double(n)
}

/// 48 kHz 写盘（顺带就是 app 写 output wav 的那段代码）→ 16 kHz 读回（录音进链路的那段）
func resampleProbe(_ tones: [(hz: Int, amp: Double)], tag: String) throws -> [Float] {
    let sr = 48000, n = sr * 3
    var s = [Float](repeating: 0, count: n)
    for t in tones {
        let w = 2.0 * Double.pi * Double(t.hz) / Double(sr)
        for i in 0..<n { s[i] += Float(t.amp * sin(Double(i) * w)) }
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("rsprobe_\(tag).wav")
    try AudioProcessor.saveWAV(s, to: url, sampleRate: Double(sr))
    let got = try AudioProcessor.loadWAV16K(url)
    try? FileManager.default.removeItem(at: url)
    print(String(format: "RESAMPLE tag=%@ 写 %d 样本@48k → 读回 %d 样本@16k（长度应 ≈ %d）",
                 tag, n, got.count, n / 3))
    return got
}

_ = stage("resample", { () throws -> Bool in
    let a = try resampleProbe([(300, 0.3), (3000, 0.3)], tag: "inband")
    for hz in [300, 3000] {
        let v = toneAmp(a, hz)
        print(String(format: "RESAMPLE inband hz=%d 写 0.300000 读回 %.6f ⇒ 增益 %.4f", hz, v, v / 0.3))
    }
    print(String(format: "RESAMPLE floor hz=7777 amp=%.6f（同一条里无关频点＝这把尺的本底）", toneAmp(a, 7777)))

    // 带外音 12 kHz@48k：不滤的话 3 倍抽取正好落在 4 kHz@16k。
    // 天花板另标定：同一条尺量「真的 4 kHz」应该是多少。
    let b = try resampleProbe([(12000, 0.3)], tag: "alias")
    let c = try resampleProbe([(4000, 0.3)], tag: "ref4k")
    var bestHz = 0, bestAmp = 0.0, hz = 100
    while hz < 7900 {
        let v = toneAmp(b, hz)
        if v > bestAmp { bestAmp = v; bestHz = hz }
        hz += 100
    }
    let ref = toneAmp(c, 4000)
    print(String(format: "RESAMPLE alias 带外 12k 折进带内最大 %.6f @%d Hz ／ 天花板（真 4k）%.6f ⇒ %.4f%%",
                 bestAmp, bestHz, ref, ref > 0 ? bestAmp / ref * 100.0 : -1))
    return true
})

print(String(format: "总用时 %.1f s", Date().timeIntervalSince(tAll)))
if failures.isEmpty {
    print("CHAIN GATE PASS")
    exit(0)
}
print("CHAIN GATE FAIL: " + failures.joined(separator: " / "))
exit(1)
