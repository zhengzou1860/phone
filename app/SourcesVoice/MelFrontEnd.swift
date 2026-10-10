import Foundation

/// 链路里的两个 mel 前端，各走各的口径，不可互换（写成一套必然跑偏）：
///
///   内容通道 = kaldi fbank：输入已乘 32768、25 ms/10 ms、snip_edges、去直流、预加重 0.97、
///             povey = hann(非周期)^0.85、补零到 512 点 FFT、HTK mel 20–8000 共 80 个三角、log(max(·,ε))
///   prompt 通道 = MeanVC MelSpectrogramFeatures：输入 [-1,1]、n_fft 1024 / win 640 / hop 160、
///             center + reflect 补零、周期性 hann、幅度 √(功率+1e-6)、librosa mel 基 80×513、
///             dB(ref −115) − 20、归一到 ±1
///
/// 逐算子对着 tools/_fbank_ref.py 与 tools/_pmel_ref.py 抄。这两份 python 又分别和
/// torchaudio.compliance.kaldi（rel_l2 5.5e-7）、MeanVC 自己在真样本上算的 mel（rel_l2 1.6e-6）对过。
/// Swift 这一版在落地前，先用 tools/_swift_fe_sim.py 把同一串 float32 算子跑了一遍：
/// 对合成 fixture 的残差 fbank 6.6e-5、prompt mel 1.5e-6，FFT 相对误差 1.2e-7。
/// 所以 selfTest() 报出来的数就该在这个量级；差一个数量级以上说明实现漂了，不是精度问题。
enum MelFrontEnd {

    // MARK: - FFT（迭代 radix-2 DIT：输入位反转，输出自然序）

    struct FFTPlan {
        let n: Int
        private let rev: [Int]
        private let twRe: [Float]
        private let twIm: [Float]

        init(_ n: Int) {
            precondition(n > 1 && n & (n - 1) == 0, "FFT 长度必须是 2 的幂")
            self.n = n
            var bits = 0
            var v = n
            while v > 1 { v >>= 1; bits += 1 }
            var r = [Int](repeating: 0, count: n)
            for i in 0..<n {
                var rr = 0
                var x = i
                for _ in 0..<bits {
                    rr = (rr << 1) | (x & 1)
                    x >>= 1
                }
                r[i] = rr
            }
            rev = r
            // 角度在 Double 里算、结果降成 Float 存表（和 _swift_fe_sim 一致）
            var wr = [Float](repeating: 0, count: n / 2)
            var wi = [Float](repeating: 0, count: n / 2)
            for k in 0..<(n / 2) {
                let a = -2.0 * Double.pi * Double(k) / Double(n)
                wr[k] = Float(cos(a))
                wi[k] = Float(sin(a))
            }
            twRe = wr
            twIm = wi
        }

        func transform(re: inout [Float], im: inout [Float]) {
            precondition(re.count == n && im.count == n)
            for i in 0..<n {
                let j = rev[i]
                if j > i {
                    re.swapAt(i, j)
                    im.swapAt(i, j)
                }
            }
            var length = 2
            while length <= n {
                let half = length >> 1
                let step = n / length
                var block = 0
                while block < n {
                    for j in 0..<half {
                        let t = j * step
                        let wr = twRe[t]
                        let wi = twIm[t]
                        let a = block + j
                        let b = a + half
                        let tr = wr * re[b] - wi * im[b]
                        let ti = wr * im[b] + wi * re[b]
                        let ra = re[a]
                        let ia = im[a]
                        re[a] = ra + tr
                        im[a] = ia + ti
                        // 两只输出都以 a 处的 u 为基准。写成 im[b] - ti 会实部全对、
                        // 只有部分虚部错——对拍时最容易漏。
                        re[b] = ra - tr
                        im[b] = ia - ti
                    }
                    block += length
                }
                length <<= 1
            }
        }
    }

    // MARK: - 内容通道：kaldi fbank

    static let nMels = 80
    static let kaldiFrame = 400          // 25 ms @16k
    static let kaldiShift = 160          // 10 ms
    static let kaldiPadded = 512         // next_pow2(400)
    /// kaldi 在取 log 之前用的地板 = std::numeric_limits<float>::epsilon()
    static let kaldiEpsilon: Float = 1.1920928955078125e-07

    private static func melScale(_ f: Double) -> Double { 1127.0 * log(1.0 + f / 700.0) }

    /// (80 × 256) 展平。kaldi 那边右侧还会补一列全 0（bin 256 = 8000 Hz），
    /// 补了也乘 0，所以这里直接不算那一列。
    private static let kaldiBanks: [Float] = {
        let half = kaldiPadded / 2
        var out = [Float](repeating: 0, count: nMels * half)
        let low = melScale(20.0)
        let high = melScale(8000.0)                    // high_freq=0 ⇒ 落到 nyquist
        let delta = (high - low) / Double(nMels + 1)
        let binWidth = 16000.0 / Double(kaldiPadded)
        for b in 0..<nMels {
            let left = low + Double(b) * delta
            let center = low + Double(b + 1) * delta
            let right = low + Double(b + 2) * delta
            for k in 0..<half {
                let mel = melScale(binWidth * Double(k))
                let up = (mel - left) / (center - left)
                let down = (right - mel) / (right - center)
                out[b * half + k] = Float(max(0.0, min(up, down)))
            }
        }
        return out
    }()

    /// 每个三角只在一段连续 bin 上非零，跳着乘就行（也把"bin 256 恒不贡献"这件事固定住）
    private static let kaldiNz: [[Int]] = {
        let half = kaldiPadded / 2
        return (0..<nMels).map { b in (0..<half).filter { k in kaldiBanks[b * half + k] != 0 } }
    }()

    private static let povey: [Float] = {
        (0..<kaldiFrame).map { i in
            let w = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(kaldiFrame - 1))
            return Float(pow(w, 0.85))
        }
    }()

    private static let kaldiFFT = FFTPlan(kaldiPadded)

    /// scaled：16 kHz 单声道、已乘 32768 的样本。返回 帧数×80 展平，帧数 = 1 + (n-400)/160。
    static func kaldiFbank(_ scaled: [Float]) -> [Float] {
        let n = scaled.count
        guard n >= kaldiFrame else { return [] }
        let frames = 1 + (n - kaldiFrame) / kaldiShift
        let half = kaldiPadded / 2
        var out = [Float](repeating: 0, count: frames * nMels)
        var re = [Float](repeating: 0, count: kaldiPadded)
        var im = [Float](repeating: 0, count: kaldiPadded)
        for f in 0..<frames {
            let base = f * kaldiShift
            var sum = 0.0
            for i in 0..<kaldiFrame { sum += Double(scaled[base + i]) }
            let mean = Float(sum / Double(kaldiFrame))
            var prev: Float = 0
            for k in kaldiFrame..<kaldiPadded {
                re[k] = 0
                im[k] = 0
            }
            for i in 0..<kaldiFrame {
                let v = scaled[base + i] - mean                    // remove_dc_offset
                let pe = i == 0 ? v - 0.97 * v : v - 0.97 * prev   // kaldi: pre[0] = f0 - a·f0
                prev = v
                re[i] = pe * povey[i]
                im[i] = 0            // 缓冲区跨帧复用：上一帧的原地 FFT 把虚部写脏了
            }
            kaldiFFT.transform(re: &re, im: &im)
            for b in 0..<nMels {
                var acc: Float = 0
                let row = b * half
                for k in kaldiNz[b] {
                    acc += (re[k] * re[k] + im[k] * im[k]) * kaldiBanks[row + k]
                }
                out[f * nMels + b] = Float(log(Double(max(acc, kaldiEpsilon))))
            }
        }
        return out
    }

    // MARK: - prompt 通道：MeanVC 的 MelSpectrogramFeatures

    static let pmelNFFT = 1024
    static let pmelWin = 640
    static let pmelHop = 160
    static let pmelBins = pmelNFFT / 2 + 1     // 513
    static let pmelMinDB = -115.0

    /// 窗在 FFT 帧里左偏 (1024-640)/2 = 192 起步，两侧补零；
    /// 这个 192 和 center 的 padding 512 是两个不同的数，别混（混了窗外样本会被原样带过去，
    /// 帧能量高 2.6 倍，dB 域整体偏 +0.16，值域却照样对得上，很能骗人）。
    private static let pmelWindow: [Float] = {
        var w = [Float](repeating: 0, count: pmelNFFT)
        let off = (pmelNFFT - pmelWin) / 2
        for i in 0..<pmelWin {
            w[off + i] = Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(pmelWin)))
        }
        return w
    }()

    private static let pmelFFT = FFTPlan(pmelNFFT)

    /// samples：16 kHz 单声道、[-1,1] 归一域。basis：80×513 的 librosa mel 基（行主序展平，
    /// 来自 bundle 的 librosa_mel_basis.f32 —— 那是训练侧的常量，不在 Swift 里重抄 Slaney 公式）。
    /// 返回 帧数×80 展平，帧数 = 1 + n/160，值已按 MeanVC 的约定做完 dB 与 ±1 归一化。
    static func promptMel(_ samples: [Float], basis: [Float]) -> [Float] {
        let n = samples.count
        let pad = pmelNFFT / 2
        guard n >= pad + 2, basis.count == nMels * pmelBins else { return [] }

        // reflect 补零：不重复边缘样本（numpy 'reflect' / torch F.pad 'reflect' 同一个口径）
        var padded = [Float](repeating: 0, count: n + 2 * pad)
        for j in 0..<pad { padded[j] = samples[pad - j] }
        for i in 0..<n { padded[pad + i] = samples[i] }
        for t in 0..<pad { padded[pad + n + t] = samples[n - 2 - t] }

        let frames = 1 + (padded.count - pmelNFFT) / pmelHop
        var nz = [[Int]](repeating: [], count: nMels)
        for b in 0..<nMels {
            let row = b * pmelBins
            nz[b] = (0..<pmelBins).filter { k in basis[row + k] != 0 }
        }
        let minLevel = Float(pow(10.0, pmelMinDB / 20.0))
        var out = [Float](repeating: 0, count: frames * nMels)
        var re = [Float](repeating: 0, count: pmelNFFT)
        var im = [Float](repeating: 0, count: pmelNFFT)
        for f in 0..<frames {
            let s = f * pmelHop
            for k in 0..<pmelNFFT {
                re[k] = padded[s + k] * pmelWindow[k]
                im[k] = 0
            }
            pmelFFT.transform(re: &re, im: &im)
            for b in 0..<nMels {
                let row = b * pmelBins
                var acc: Float = 0
                for k in nz[b] {
                    let amp = sqrtf(re[k] * re[k] + im[k] * im[k] + 1e-6)
                    acc += amp * basis[row + k]
                }
                let lin = Double(max(acc, minLevel))
                let db = 20.0 * log10(lin) - 20.0
                let v = 2.0 * ((db - pmelMinDB) / (0.0 - pmelMinDB)) - 1.0
                out[f * nMels + b] = Float(min(1.0, max(-1.0, v)))
            }
        }
        return out
    }

    // MARK: - bundle 里的对拍向量与自检

    /// 纯 Float32 小端一维数组，见 SourcesVoice/Fixtures/PROVENANCE.txt
    static func loadFloats(_ name: String) -> [Float]? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "f32"),
              let data = try? Data(contentsOf: url) else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return nil }
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                out[i] = raw.loadUnaligned(fromByteOffset: i * MemoryLayout<Float>.size, as: Float.self)
            }
        }
        return out
    }

    /// 自检阈值：Float32 这条路实测残差 6.6e-5 / 1.5e-6，这里放一个数量级余量。
    /// 上机若报 1e-2 以上就不是精度，是某一步算子顺序/偏移和 python 那份不一致。
    static func selfTest() -> String {
        guard let wave = loadFloats("synth16k_scaled"),
              let expFB = loadFloats("fbank_expect"),
              let expPM = loadFloats("pmel_expect"),
              let basis = loadFloats("librosa_mel_basis") else {
            return "前端自检：Fixtures/*.f32 没进包（bundle 里找不到），这一格等于没验"
        }
        var lines: [String] = ["前端自检 输入 \(wave.count) 样本（合成音，非用户素材）"]

        let gotFB = kaldiFbank(wave)
        if let d = maxAbs(gotFB, expFB) {
            lines.append("  kaldi fbank \(gotFB.count / nMels)×\(nMels)  max_abs=\(fmt(d)) 期望<5e-3 \(d < 5e-3 ? "过" : "不过")")
        } else {
            lines.append("  kaldi fbank 帧数对不上：我 \(gotFB.count / nMels) 期望 \(expFB.count / nMels)")
        }

        let norm = wave.map { $0 / 32768.0 }
        let gotPM = promptMel(norm, basis: basis)
        if let d = maxAbs(gotPM, expPM) {
            lines.append("  prompt mel \(gotPM.count / nMels)×\(nMels)  max_abs=\(fmt(d)) 期望<5e-3 \(d < 5e-3 ? "过" : "不过")")
        } else {
            lines.append("  prompt mel 帧数对不上：我 \(gotPM.count / nMels) 期望 \(expPM.count / nMels)")
        }
        return lines.joined(separator: "\n")
    }

    private static func maxAbs(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var m: Float = 0
        for i in 0..<a.count {
            let d = abs(a[i] - b[i])
            if d > m { m = d }
        }
        return m
    }

    private static func fmt(_ v: Float) -> String { String(format: "%.3g", v) }
}
