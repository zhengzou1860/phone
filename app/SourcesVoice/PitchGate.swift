import Foundation
import Accelerate

/// 「去掉男声」：源音频里基频低于门限的那些块就地清零，时间轴一个样本都不动。
///
/// 为什么用基频而不是音色向量：这一条要的从来不是"这句话是谁说的"，而是"这是男是女"。
/// 上一版拿①的音色向量和**要换成的那个样本**比，方向就错了——访谈里那两个说话人谁都不是
/// 目标音色，于是 121 块判下来只放行 3 块，整条几乎全被清零（真机日志 0.1/43 那次），
/// 剩下的声音还是链子从近乎全静音里硬合成的，听感就是"含糊"。而 ① 那一趟本身要多花
/// 53 s／265 s 素材，还要临时顶 386 MB。基频这把尺不载任何图：同一趟 0.5 s 量级。
///
/// 块内中位 F0 在 PC 上拿出厂素材量过（`probe_pitch.py`，和我的 Swift 逐帧自相关同一套数）：
/// 男声两块 137／131 Hz，女声三把嗓子 25 块里最低 180 Hz ⇒ 150 Hz 这条线两边各留 15 Hz
/// 和 30 Hz 的余量。逐帧和 librosa.pyin 的中位差 3.5~6.2%（八度跳变落在个别帧上，
/// 取块内中位数就压掉了）。
///
/// 为什么清零而不是删掉：⑤ 视频换声的口型靠「链子输出和源逐片对齐」，删掉一块会把后面整体
/// 前移，越到片尾偏得越多。清零留下一条纹丝不动的时间轴。
///
/// 听感上判反的两种，按用户的话是接受的（"偶尔剩点男声也没事"）：低沉的女声（<150 Hz）会被
/// 删掉，压着嗓子说的男声漏网。真机日志里那块逐块 F0 的一行就是给这条线回账的。
enum PitchGate {

    /// 一块标称多长。和分段那套（`VoiceEngine.quietCut`）不必一致，但刀口同样躲停顿：
    /// 一块里只装一个人，删起来才不会半个字半个字地啃。
    static let maxPieceSecs = 2.5

    /// 两块刀口之间最少这么多，比这短的块自己判不准。
    static let minPieceSecs = 1.0

    /// 刀口可以在标称位置前后这么宽的范围内找能量最低的一格。
    static let cutSearchSecs = 0.5

    /// 能量格子（50 ms），和 `VoiceEngine.quietCut` 同一口径。
    static let cellSecs = 0.05

    /// 男声门限：块内有声帧的 F0 中位数低于这条线 ⇒ 判男声、清零。
    /// PC 实测男 131~137／女 180~281，线画在 150：偏「留人」那一侧，宁可漏一句男声。
    static let maleHz = 150.0

    /// 一窗里有声帧占比不到这个数 ⇒ 不判（清音、气口、几乎没人说话的那块），原样留着。
    static let minVoicedRatio = 0.15

    // 逐帧尺：30 ms 窗 / 15 ms 跳，自相关搜 60~400 Hz（lag 40~266 @16 kHz）
    static let frameSamples = 480
    static let hopSamples = 240
    static let lagLo = 40
    static let lagHi = 266

    struct Report {
        var sourceSecs: Double
        var pieces: Int
        var keptPieces: Int
        var droppedPieces: Int
        var droppedSecs: Double
        var judged: Int
        var quietPieces: Int
        var minHz: Double
        var maxHz: Double
        /// 逐块判定的墙钟。基频这把尺不载任何图，所以这一个数就是「开这个开关多花了几秒」。
        var wallSeconds: Double
        /// 逐块：块头秒数 + 块内中位 F0（不判的那几块 hz 给 0）。
        var tracks: [(sec: Double, hz: Double, voiced: Double)]
        /// 被清零的那些块的样本区间。**调用方必须拿它把输出侧同一段也钉成静音**，
        /// 否则链子会在这一片全零上合成出含噪的假人声（0.1/43 那次「含糊」的第二半成因）。
        var droppedSpans: [(start: Int, end: Int)]

        var line: String {
            String(format: "去男声：源 %.1f s ⇒ %d 块（标称 %.1f s／块，刀口躲能量低谷）"
                   + "｜判 %d 块／有声太少不判 %d 块｜留 %d 块／清零 %d 块＝%.1f s"
                   + "｜F0 最好 %.0f 最差 %.0f Hz（男声线 %.0f Hz）｜墙钟 %.2f s",
                   sourceSecs, pieces, PitchGate.maxPieceSecs, judged, quietPieces,
                   keptPieces, droppedPieces, droppedSecs, maxHz, minHz,
                   PitchGate.maleHz, wallSeconds)
        }

        /// 逐块 F0：那条 150 Hz 线合不合适，看这一串的分布就知道。
        var hzLine: String {
            let cap = 400
            let body = tracks.prefix(cap).map { t -> String in
                t.hz <= 0 ? String(format: "%.1f:—", t.sec)
                          : String(format: "%.1f:%.0f", t.sec, t.hz)
            }.joined(separator: " ")
            let tail = tracks.count > cap
                ? String(format: "…（只列前 %d 块，共 %d 块）", cap, tracks.count) : ""
            return "去男声逐块 F0（男声线 " + String(format: "%.0f", PitchGate.maleHz) + " Hz）：" + body + tail
        }
    }

    /// 跑一趟，**原地**改 `source`，并把被清零的区间还给调用方去钉输出。
    /// 不复制整条：长素材那一份就是几百 MB，而这里是唯一一处需要按块取数的地方。
    static func run(_ source: inout [Float],
                    onProgress: (Int, Int) -> Void = { _, _ in }) throws -> Report {
        let t0 = Date()
        let sr = AudioProcessor.sampleRate
        let ps = pieces(source)
        var keep = [Bool](repeating: true, count: ps.count)
        var tracks: [(sec: Double, hz: Double, voiced: Double)] = []
        var judged = 0
        var quiet = 0
        var lo = Double.greatestFiniteMagnitude
        var hi = 0.0

        for k in 0..<ps.count {
            let (hz, voiced) = pieceF0(source, ps[k].start, ps[k].end)
            tracks.append((Double(ps[k].start) / sr, hz, voiced))
            if voiced < minVoicedRatio {
                quiet += 1                              // 几乎没有浊音：不判，原样留着
            } else {
                judged += 1
                if hz < lo { lo = hz }
                if hz > hi { hi = hz }
                keep[k] = hz >= maleHz
            }
            if (k + 1) % 20 == 0 { onProgress(k + 1, ps.count) }
        }

        var dropped = 0
        var droppedSecs = 0.0
        var spans: [(start: Int, end: Int)] = []
        for k in 0..<ps.count where !keep[k] {
            dropped += 1
            droppedSecs += Double(ps[k].end - ps[k].start) / sr
            spans.append((ps[k].start, ps[k].end))
        }
        // 判过的块一块都没留下＝这条片子里根本没有女声（或者门限画高了）。
        // 交一条从头到尾没声音的成片，得听完整条才知道坏了；所以在动刀之前先一句话说明白。
        if judged > 0, dropped == judged {
            let lowest = tracks.filter { $0.hz > 0 }.map { $0.hz }.max() ?? 0
            throw ChainError.input(String(format: "去男声：判过的 %d 块全低于 %.0f Hz（最尖的一块只有 %.0f Hz）"
                                          + "⇒ 这条源里没有女声，或者男声都在高音区。源没动，关掉「去掉男声」再来一遍",
                                          judged, maleHz, lowest))
        }
        for k in 0..<ps.count where !keep[k] {
            var i = ps[k].start
            while i < ps[k].end {
                source[i] = 0
                i += 1
            }
        }

        return Report(sourceSecs: Double(source.count) / sr, pieces: ps.count,
                      keptPieces: ps.count - dropped, droppedPieces: dropped,
                      droppedSecs: droppedSecs, judged: judged, quietPieces: quiet,
                      minHz: lo == Double.greatestFiniteMagnitude ? 0 : lo, maxHz: hi,
                      wallSeconds: Date().timeIntervalSince(t0), tracks: tracks, droppedSpans: spans)
    }

    // MARK: - 逐块 F0

    /// 一块的中位 F0 和有声占比。窗 30 ms／跳 15 ms，跨整块滑过去；浊音帧取中位数，
    /// 个别八度跳变（PC 上和 pyin 的 95% 分位差 23~49% 就是它）被中位数压掉。
    static func pieceF0(_ src: [Float], _ from: Int, _ to: Int) -> (hz: Double, voiced: Double) {
        var vals: [Double] = []
        var frames = 0
        var s = from
        while s + frameSamples <= to {
            frames += 1
            let h = frameF0(src, s)
            if h > 0 { vals.append(h) }
            s += hopSamples
        }
        guard frames > 0 else { return (0, 0) }
        guard !vals.isEmpty else { return (0, 0) }
        vals.sort()
        let med = vals[vals.count / 2]
        return (med, Double(vals.count) / Double(frames))
    }

    /// 一帧：归一化自相关取最大那一格；再往小 lag 退，只要不低于最大值的 0.85 就认更短的周期
    /// ——那是修八度（把"半个周期"误当真周期）那一格，不修会把男声报成它自己的高八度、
    /// 女声和男声就挤在一堆。
    static func frameF0(_ src: [Float], _ from: Int) -> Double {
        let n = frameSamples
        guard from + n <= src.count else { return 0 }
        let win = Array(src[from..<from + n])
        var peak = 0.0
        for v in win { peak += Double(v) * Double(v) }
        peak /= Double(n)
        if peak < 1e-8 { return 0 }                    // 这一帧没人说话

        // 前缀平方和：Σ_{i<n-lag} x² = csum[n−lag]，Σ_{i≥lag} x² = csum[n]−csum[lag]
        var csum = [Double](repeating: 0, count: n + 1)
        var acc = 0.0
        var i = 0
        while i < n {
            acc += Double(win[i]) * Double(win[i])
            csum[i + 1] = acc
            i += 1
        }
        let hiLag = min(lagHi, n - 8)
        let cnt = hiLag - lagLo + 1
        guard cnt > 0 else { return 0 }
        // 归一化自相关：denom = √(Σ前段² · Σ后段²)。这里不能各自取均方再相除——那样分母少一个
        // √(lag／(n−lag))，越长的 lag 越占便宜，峰会一路滑到搜索范围上端：PC 上拿男女对话仿真的
        // 素材试这一版，25 块全报 65~74 Hz（真值女 219~250／男 131~138），男女一起被判成男声。
        // 八度修正只能沿 r 的高原往短 lag 退，跨不过两个峰之间的谷，救不回来。
        // 现在这个不带倾斜的口径和 PC 上与 librosa.pyin 对拍的那把尺同一套数（probe_pitch.py）。
        var r = [Double](repeating: 0, count: cnt)
        var bestV = 0.0
        var bestLag = 0
        for idx in 0..<cnt {
            let lag = lagLo + idx
            let denom = (csum[n - lag] * (csum[n] - csum[lag])).squareRoot()
            if denom < 1e-9 { continue }
            // vDSP_dotpr 只认 Float：求和用 Float，比值再升回 Double。
            // 语音幅度下 480 项的 Float 累加误差在 1e-7 量级，离 0.30 这条有声线差着好几个数量级。
            var dotF: Float = 0
            win.withUnsafeBufferPointer { buf in
                vDSP_dotpr(buf.baseAddress! + lag, 1, buf.baseAddress!, 1,
                           &dotF, vDSP_Length(n - lag))
            }
            let v = Double(dotF) / denom
            r[idx] = v
            if v > bestV {
                bestV = v
                bestLag = lag
            }
        }
        if bestV < 0.30 || bestLag == 0 { return 0 }
        var lag = bestLag
        while lag - 1 >= lagLo, r[lag - 1 - lagLo] >= 0.85 * bestV {
            lag -= 1
        }
        return AudioProcessor.sampleRate / Double(lag)
    }

    // MARK: - 切块

    /// 一刀一刀的落点：标称每 `maxPieceSecs` 一块，每一刀在附近 ±`cutSearchSecs` 里找能量最低的
    /// 那一格下刀——两个人换口的地方多半就是一个低谷，躲得开就躲开，块里就只剩一个人。
    /// 两刀之间最少隔 `minPieceSecs`，尾巴不足这个数的并进前面那一块。
    ///
    /// 为什么不做「静音块跳过」：跳过＝那块原封不动过了链，轻声那个人整片漏网；而判一块静音
    /// 再清零，一个耳朵都听不出来。所以整条都判，能量只用来决定刀口往哪儿挪。
    static func pieces(_ src: [Float]) -> [(start: Int, end: Int)] {
        let cell = Int((cellSecs * AudioProcessor.sampleRate).rounded())
        let n = src.count
        guard cell > 0, n > cell else { return [] }
        let nCells = (n + cell - 1) / cell
        let maxCells = max(2, Int((maxPieceSecs * AudioProcessor.sampleRate).rounded()) / cell)
        let minCells = max(1, Int((minPieceSecs * AudioProcessor.sampleRate).rounded()) / cell)
        let lookCells = max(0, Int((cutSearchSecs * AudioProcessor.sampleRate).rounded()) / cell)

        var cellRms = [Double](repeating: 0, count: nCells)
        for c in 0..<nCells {
            cellRms[c] = rms(src, c * cell, min((c + 1) * cell, n))
        }

        var out: [(start: Int, end: Int)] = []
        var a = 0
        while a < nCells {
            if nCells - a <= maxCells {
                out.append((a * cell, n))
                break
            }
            var cut = a + maxCells
            let lo = a + minCells
            let hi = min(nCells - 1, a + maxCells + lookCells)
            if hi > lo {
                var bestV = Double.greatestFiniteMagnitude
                var k = lo
                while k <= hi {
                    if cellRms[k] < bestV {
                        bestV = cellRms[k]
                        cut = k
                    }
                    k += 1
                }
            }
            out.append((a * cell, cut * cell))
            a = cut
        }
        if out.count > 1 {
            let last = out.count - 1
            if out[last].end - out[last].start < minCells * cell {
                out[last - 1].end = n
                out.removeLast()
            }
        }
        return out
    }

    /// 一段样本的均方根。隔 8 个取一个，和 `VoiceEngine.quietCut` 同一口径。
    static func rms(_ src: [Float], _ from: Int, _ to: Int) -> Double {
        var s = 0.0
        var counted = 0
        var i = from
        while i < to {
            let v = Double(src[i])
            s += v * v
            counted += 1
            i += 8
        }
        return counted > 0 ? (s / Double(counted)).squareRoot() : 0.0
    }
}
