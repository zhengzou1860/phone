import Foundation

/// 频率 → bin。夹在 1…n/2 里：DC 和超过 Nyquist 的都不看（本底和混叠不是鼾）。
func snoreBin(_ hz: Double, n: Int, sr: Double) -> Int {
    let k = Int((hz * Double(n) / sr).rounded())
    if k < 1 { return 1 }
    if k > n / 2 { return n / 2 }
    return k
}

// MARK: - FFT（迭代 radix-2 DIT：先位反转，再逐级蝶形）
//
// 自己写而不是用 vDSP：这一份既要在手机上跑 8 小时，又要在 CI 那台 mac 上拿合成信号做数值自检。
// 少一个系统 API 就少一处「本机没有 Swift 工具链、只能等 CI 报编译错」的风险，
// 而且成本算得清：4096 点 × 每秒 11.7 帧 ≈ 57 万次蝶形/秒，双精度也就 1% 上下的一核。

final class SnoreFFT {
    let n: Int
    private var bitRev: [Int] = []
    private var twR: [[Double]] = []
    private var twI: [[Double]] = []

    init(_ n: Int) {
        precondition(n >= 8 && n & (n - 1) == 0, "FFT 长度必须是 2 的幂")
        self.n = n
        var lg = 0
        var m = n
        while m > 1 { m >>= 1; lg += 1 }
        for i in 0..<n {
            var x = i
            var y = 0
            for _ in 0..<lg {
                y = (y << 1) | (x & 1)
                x >>= 1
            }
            bitRev.append(y)
        }
        var len = 2
        while len <= n {
            let half = len / 2
            var wr = [Double](repeating: 0.0, count: half)
            var wi = [Double](repeating: 0.0, count: half)
            for k in 0..<half {
                let ang = -2.0 * Double.pi * Double(k) / Double(len)
                wr[k] = cos(ang)
                wi[k] = sin(ang)
            }
            twR.append(wr)
            twI.append(wi)
            len <<= 1
        }
    }

    /// 就地变换：re/im 长度必须等于 n。传实信号时 im 全 0 就行，出来的谱共轭对称，只看前 n/2+1 个 bin。
    func transform(re: inout [Double], im: inout [Double]) {
        guard re.count == n, im.count == n else { return }
        for i in 0..<n {
            let j = bitRev[i]
            if j > i {
                var tmp = re[i]; re[i] = re[j]; re[j] = tmp
                tmp = im[i]; im[i] = im[j]; im[j] = tmp
            }
        }
        var stage = 0
        var len = 2
        while len <= n {
            let half = len / 2
            let wr = twR[stage]
            let wi = twI[stage]
            var base = 0
            while base < n {
                for k in 0..<half {
                    let a = base + k
                    let b = a + half
                    let tr = wr[k] * re[b] - wi[k] * im[b]
                    let ti = wr[k] * im[b] + wi[k] * re[b]
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] = re[a] + tr
                    im[a] = im[a] + ti
                }
                base += len
            }
            stage += 1
            len <<= 1
        }
    }
}

// MARK: - 一帧的读数

struct SnoreFeature {
    var t: Double            // 会话内秒（这一窗结束的时刻）
    var level: Double        // dBFS（时域 RMS）
    var peak: Double         // dBFS（这一窗里最大幅度）
    var floor: Double        // 本底 dBFS（慢跟）
    var lowRatio: Double     // 30–400 Hz 占 30–6000 Hz 的能量比
    var hiRatio: Double      // 1000–6000 Hz 占比（说话/摩擦音靠它区分）
    var peakHz: Double       // 45–350 Hz 里最强的那一根
    var tonality: Double     // dB：最低频那一带的峰/均，鼾声是谐波堆⇒高
    var stability: Double    // 与上一帧五个频带向量的余弦相似（说话共振峰在跑⇒低）
    var modDepth: Double     // 最近 4 s 低频能量的起伏（dB）：steady 的冰箱嗡鸣靠它筛掉
    var score: Double        // 0…1「频谱像鼾」的程度；进门还要过 SnoreTracker 的呼吸节律门
    var voiced: Bool         // 高于本底门限的任何声音（鼾、说话、咳嗽都算）
}

// MARK: - 逐帧分析

/// 麦克风那一串样本进来，攒够一窗出一帧读数。不判「是不是鼾」，那是 SnoreTracker 的事。
final class SnoreAnalyzer {
    /// 窗长。4096 @ 48 kHz = 85.3 ms，bin 宽 11.7 Hz（鼾声基频 60–300 Hz 那一带够用了）。
    static let defaultWindow = 4096

    let n: Int
    let sampleRate: Double
    let frameSec: Double
    var config: SnoreConfig

    private let fft: SnoreFFT
    private let hann: [Double]
    private var re: [Double]
    private var im: [Double]
    private var stash: [Double] = []
    private var bandE = [Double](repeating: 0.0, count: 5)
    private var prevBand: [Double]?

    private var floorDb: Double = -75.0
    private var floorReady = false
    private var envRing: [Double] = []
    private let envRingMax: Int

    // bin 边界（都是 n/2 以内的整数）
    private let bandBins: [Int]
    private let binPeakLo: Int
    private let binPeakHi: Int
    private let binTonLo: Int
    private let binTonHi: Int

    /// 频带边界 Hz：30–150 / 150–400 / 400–1000 / 1000–2500 / 2500–6000。
    static let bandEdges: [Double] = [30, 150, 400, 1000, 2500, 6000]

    init(sampleRate: Double, windowSize: Int = SnoreAnalyzer.defaultWindow, config: SnoreConfig) {
        self.sampleRate = sampleRate > 4000 ? sampleRate : 16000
        self.n = windowSize
        self.frameSec = Double(windowSize) / self.sampleRate
        self.config = config
        self.fft = SnoreFFT(windowSize)

        var w = [Double](repeating: 0.0, count: windowSize)
        for i in 0..<windowSize {
            w[i] = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(windowSize)))
        }
        self.hann = w
        self.re = [Double](repeating: 0.0, count: windowSize)
        self.im = [Double](repeating: 0.0, count: windowSize)

        var bins: [Int] = []
        for hz in SnoreAnalyzer.bandEdges { bins.append(snoreBin(hz, n: windowSize, sr: self.sampleRate)) }
        self.bandBins = bins
        self.binPeakLo = snoreBin(45, n: windowSize, sr: self.sampleRate)
        self.binPeakHi = min(windowSize / 2, snoreBin(350, n: windowSize, sr: self.sampleRate))
        self.binTonLo = snoreBin(30, n: windowSize, sr: self.sampleRate)
        self.binTonHi = min(windowSize / 2, snoreBin(1200, n: windowSize, sr: self.sampleRate))
        self.envRingMax = max(8, Int(4.0 / self.frameSec))
    }

    /// 攒样本、出帧。endTime 是这一段最后一个样本的会话时刻（秒）。
    func feed(_ samples: [Double], endTime: Double, emit: (SnoreFeature) -> Void) {
        stash.append(contentsOf: samples)
        var used = 0
        let count = stash.count
        while count - used >= n {
            let t = endTime - Double(count - used - n) / sampleRate
            if let f = analyzeFrame(start: used, t: t) { emit(f) }
            used += n
        }
        if used > 0 { stash.removeFirst(used) }
    }

    private func analyzeFrame(start: Int, t: Double) -> SnoreFeature? {
        guard stash.count - start >= n else { return nil }

        // ① 时域：RMS、峰值，同时把 Hann 窗乘进 FFT 的实部
        var sumSq = 0.0
        var peakAbs = 0.0
        for i in 0..<n {
            let x = stash[start + i]
            sumSq += x * x
            let a = abs(x)
            if a > peakAbs { peakAbs = a }
            re[i] = x * hann[i]
            im[i] = 0.0
        }
        let level = snoreDbfs(rms: sqrt(sumSq / Double(n)))
        let peakDb = snoreDbfs(peak: peakAbs)

        // ② 频谱
        fft.transform(re: &re, im: &im)
        let half = n / 2
        for b in 0..<5 { bandE[b] = 0.0 }
        var totalE = 0.0
        for b in 0..<5 {
            let lo = bandBins[b]
            let hi = bandBins[b + 1]
            var e = 0.0
            var k = lo
            while k < hi && k <= half {
                e += re[k] * re[k] + im[k] * im[k]
                k += 1
            }
            bandE[b] = e
            totalE += e
        }
        guard totalE > 1e-24 else { return nil }

        // ③ 基频那一带的峰，和它相对 30–1200 Hz 平均高出多少
        var peakMag = 0.0
        var peakBin = binPeakLo
        var k = binPeakLo
        while k <= binPeakHi {
            let m = re[k] * re[k] + im[k] * im[k]
            if m > peakMag { peakMag = m; peakBin = k }
            k += 1
        }
        var tonSum = 0.0
        var tonN = 0
        k = binTonLo
        while k <= binTonHi {
            tonSum += sqrt(re[k] * re[k] + im[k] * im[k])
            tonN += 1
            k += 1
        }
        let tonality: Double
        if tonN > 0 && peakMag > 1e-20 {
            let meanMag = tonSum / Double(tonN)
            tonality = meanMag > 1e-15 ? 20.0 * log10(sqrt(peakMag) / meanMag) : 0.0
        } else {
            tonality = 0.0
        }
        let peakHz = Double(peakBin) * sampleRate / Double(n)

        // ④ 与上一帧的频带向量余弦相似（鼾声稳、说话共振峰在跑）
        var stability = 1.0
        if let prev = prevBand {
            var dot = 0.0
            var na = 0.0
            var nb = 0.0
            for b in 0..<5 {
                dot += bandE[b] * prev[b]
                na += bandE[b] * bandE[b]
                nb += prev[b] * prev[b]
            }
            stability = (na > 1e-30 && nb > 1e-30) ? dot / (sqrt(na) * sqrt(nb)) : 1.0
        }
        prevBand = bandE

        let lowRatio = (bandE[0] + bandE[1]) / totalE
        let hiRatio = (bandE[3] + bandE[4]) / totalE
        let envLow = 10.0 * log10(bandE[0] + bandE[1] + 1e-24)

        // ⑤ 本底：往下跟得快、往上爬得慢。整晚开着不能把鼾声本身学成本底。
        if !floorReady {
            floorDb = level
            floorReady = true
        } else if level < floorDb {
            floorDb += 0.20 * (level - floorDb)
        } else {
            floorDb += 0.0015 * (level - floorDb)
        }
        if floorDb < -95 { floorDb = -95 }
        if floorDb > level { floorDb = level }

        // ⑥ 起伏深度：最近 4 s 低频能量的标准差（鼾随呼吸一起一落）
        envRing.append(envLow)
        if envRing.count > envRingMax { envRing.removeFirst(envRing.count - envRingMax) }
        var modDepth = 0.0
        if envRing.count >= 8 {
            let m = snoreMean(envRing)
            var v = 0.0
            for e in envRing { v += (e - m) * (e - m) }
            modDepth = sqrt(v / Double(envRing.count))
        }

        // ⑦ 门限与打分（频谱像不像鼾；「一开一合」的形状由 SnoreTracker 的节律门管）
        let gate = max(floorDb + 4.0, config.absGateDb)
        let voiced = level > gate
        let score: Double
        if voiced {
            let sLevel = snoreClamp01((level - gate) / 12.0)
            let sLow = snoreClamp01((lowRatio - 0.30) / 0.40)
            let sTon = snoreClamp01((tonality - 3.0) / 9.0)
            let sHi = snoreClamp01((0.55 - hiRatio) / 0.25)
            let sStab = snoreClamp01((stability - 0.78) / 0.18)
            let sMod = snoreClamp01((modDepth - 2.0) / 4.0)
            let sFreq: Double
            if peakHz < 30 {
                sFreq = 0.0
            } else if peakHz < 50 {
                sFreq = (peakHz - 30.0) / 20.0
            } else if peakHz <= 330 {
                sFreq = 1.0
            } else if peakHz <= 500 {
                sFreq = (500.0 - peakHz) / 170.0
            } else {
                sFreq = 0.0
            }
            score = 0.20 * sLevel + 0.20 * sLow + 0.14 * sTon + 0.16 * sFreq
                + 0.10 * sHi + 0.08 * sStab + 0.12 * sMod
        } else {
            score = 0.0
        }

        return SnoreFeature(t: t, level: level, peak: peakDb, floor: floorDb, lowRatio: lowRatio,
                            hiRatio: hiRatio, peakHz: peakHz, tonality: tonality,
                            stability: stability, modDepth: modDepth,
                            score: score, voiced: voiced)
    }
}
