import Foundation

// MARK: - 合成信号
//
// 鼾声、说话样、恒定单音、瞬发敲击、平滑噪声本底——都是解析式生成的，给定种子就逐位可重。
// 这一份同时被手机（界面上的「算法自检」）和 CI（mac 上的出包闸门）编进去跑同一批用例：
// 判据不靠肉眼听，靠事件表的数字。

enum SnoreSynth {
    /// 一次性伪随机（不用系统 rand：两边要给出同一个数）
    static func noiseSource(seed: UInt64) -> (Int) -> Double {
        var state = seed &+ 0x9E3779B97F4A7C15
        return { (n: Int) -> Double in
            var v = 0.0
            for _ in 0..<n {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let x = Double((state >> 11) & 0xFFFFFFF) / Double(0xFFFFFFF0)
                v = v * 0.35 + x * 0.65        // 一阶平滑：白噪声太尖，本底应该是连续的能量
            }
            return v
        }
    }

    /// 平滑噪声（本底用）
    static func bed(count: Int, level: Double, seed: UInt64) -> [Double] {
        let gen = noiseSource(seed: seed)
        var out = [Double](repeating: 0.0, count: count)
        var x = 0.0
        var lp = 0.0
        for i in 0..<count {
            x = x * 0.72 + gen(1) * 0.28
            lp = lp * 0.90 + x * 0.10          // 再压一点高频，听着/看着才像远处的空调与床响
            out[i] = lp * level
        }
        return out
    }

    /// 鼾声：每 periodSec 一鼾，每一鼾是基频 f0 的谐波堆，包络起—落。
    /// - level: 峰值幅度（0…1）
    /// - duty: 一鼾占一个呼吸周期的比例
    static func snore(count: Int, sampleRate: Double, periodSec: Double, f0: Double,
                      level: Double, duty: Double = 0.45, startAt: Double = 0.0,
                      wobble: Double = 0.05, seed: UInt64 = 7) -> [Double] {
        var out = [Double](repeating: 0.0, count: count)
        let period = max(0.4, periodSec) * sampleRate
        let rnd = noiseSource(seed: seed)
        var ph = [Double](repeating: 0.0, count: 10)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            guard t >= startAt else { continue }
            let rel = t - startAt
            let cycle = rel.truncatingRemainder(dividingBy: period) / period
            if cycle > duty { continue }
            let u = cycle / duty                          // 0…1 在这一鼾里的位置
            let env = pow(sin(Double.pi * u), 0.8)
            let f = f0 * (1.0 + wobble * sin(2.0 * Double.pi * rel / (period * 2.5)))
            var s = 0.0
            for h in 1...9 {
                let amp = 1.0 / pow(Double(h), 0.95)
                ph[h] += 2.0 * Double.pi * f * Double(h) / sampleRate
                if ph[h] > 2.0 * Double.pi { ph[h] -= 2.0 * Double.pi }
                s += amp * sin(ph[h])
            }
            // 一点点低频隆隆（软组织的震动），以及呼吸气流带来的细微抖动
            s += 0.5 * sin(2.0 * Double.pi * 55.0 * t)
            s += rnd(1) * 0.05
            out[i] = s * env * level / 3.2
        }
        return out
    }

    /// 说话样：基频 180 但共振峰在 700/1300/2600 上来回扫，音节率 3–4 Hz。
    /// 低频占比、稳定度、起伏深度三个尺子都会偏，正好拿来验「不把说话当鼾」。
    static func speech(count: Int, sampleRate: Double, level: Double, startAt: Double = 0.0,
                       seed: UInt64 = 11) -> [Double] {
        var out = [Double](repeating: 0.0, count: count)
        let rnd = noiseSource(seed: seed)
        var ph = [Double](repeating: 0.0, count: 24)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            guard t >= startAt else { continue }
            let rel = t - startAt
            let f0 = 180.0 * (1.0 + 0.12 * sin(2.0 * Double.pi * 0.7 * rel))
            // 共振峰跟着元音换，每 0.28 s 换一个位置
            let f1 = 700.0 + 380.0 * sin(2.0 * Double.pi * rel / 0.28)
            let f2 = 1300.0 + 500.0 * sin(2.0 * Double.pi * rel / 0.41 + 1.0)
            let f3 = 2600.0 + 700.0 * sin(2.0 * Double.pi * rel / 0.63 + 2.0)
            let syl = 0.45 + 0.55 * abs(sin(2.0 * Double.pi * 3.3 * rel))
            var s = 0.0
            for h in 1...22 {
                let fr = f0 * Double(h)
                let g = exp(-pow((fr - f1) / 220.0, 2)) * 1.0
                    + exp(-pow((fr - f2) / 300.0, 2)) * 0.8
                    + exp(-pow((fr - f3) / 400.0, 2)) * 0.6
                let amp = (0.10 + g) / Double(h)
                ph[h] += 2.0 * Double.pi * fr / sampleRate
                if ph[h] > 2.0 * Double.pi { ph[h] -= 2.0 * Double.pi }
                s += amp * sin(ph[h])
            }
            s += rnd(1) * 0.03
            out[i] = s * syl * level / 2.2
        }
        return out
    }

    /// 恒定单音：振幅一直不动。冰箱/风扇嗡鸣一类——起伏深度这一关就该把它挡掉。
    static func tone(count: Int, sampleRate: Double, freq: Double, level: Double,
                     startAt: Double = 0.0) -> [Double] {
        var out = [Double](repeating: 0.0, count: count)
        var ph = 0.0
        let step = 2.0 * Double.pi * freq / sampleRate
        for i in 0..<count {
            let t = Double(i) / sampleRate
            ph += step
            if ph > 2.0 * Double.pi { ph -= 2.0 * Double.pi }
            out[i] = t >= startAt ? sin(ph) * level : 0.0
        }
        return out
    }

    /// 瞬发敲击（关门、翻身、咳一声）：宽带、极短。时长这一关就该把它挡掉。
    static func clicks(count: Int, sampleRate: Double, level: Double, at: [Double],
                       decaySec: Double = 0.12) -> [Double] {
        var out = [Double](repeating: 0.0, count: count)
        for start in at {
            let i0 = Int(start * sampleRate)
            guard i0 >= 0 && i0 < count else { continue }
            let n = Int(decaySec * sampleRate)
            for k in 0..<n {
                let i = i0 + k
                if i >= count { break }
                let env = exp(-Double(k) / Double(max(1, n / 3)))
                out[i] += level * env * (Double(k).truncatingRemainder(dividingBy: 3.0) == 0 ? 1.0 : -0.6)
            }
        }
        return out
    }

    static func add(_ a: inout [Double], _ b: [Double]) {
        let n = min(a.count, b.count)
        for i in 0..<n { a[i] += b[i] }
    }
}

// MARK: - 用例：把合成信号喂进真分析器＋真状态机，看事件表的数字

struct SnoreCaseResult {
    var name: String
    var ok: Bool
    var detail: String
}

enum SnoreCases {
    static let rate = 48000.0

    /// 把一整段样本按 4096 一块喂进去，时刻按采样率推进——和手机上的通路一模一样。
    static func run(samples: [Double], sampleRate: Double, config: SnoreConfig,
                    into tracker: SnoreTracker) -> (events: [SnoreEvent], seconds: [SnoreSecond], frames: Int) {
        let analyzer = SnoreAnalyzer(sampleRate: sampleRate, config: config)
        var events: [SnoreEvent] = []
        var seconds: [SnoreSecond] = []
        tracker.onEvent = { events.append($0) }
        tracker.onSecond = { seconds.append($0) }
        let n = analyzer.n
        var i = 0
        var delivered = 0
        while i + n <= samples.count {
            analyzer.feed(Array(samples[i..<(i + n)]), endTime: Double(i + n) / sampleRate) { f in
                tracker.accept(f)
            }
            i += n
            delivered += 1
        }
        tracker.finish(at: Double(samples.count) / sampleRate)
        return (events, seconds, delivered)
    }

    static func all(config: SnoreConfig) -> [SnoreCaseResult] {
        var out: [SnoreCaseResult] = []
        let sr = rate

        // ① 数值：150 Hz 单音的谱峰要落在 150±12 Hz，RMS 要对得上
        do {
            let a = SnoreAnalyzer(sampleRate: sr, config: config)
            var peakHz = 0.0
            var level = -999.0
            let tone = SnoreSynth.tone(count: Int(sr * 2), sampleRate: sr, freq: 150, level: 0.1)
            a.feed(tone, endTime: 2.0) { f in peakHz = f.peakHz; level = f.level }
            let okHz = abs(peakHz - 150.0) <= 14.0
            let okDb = abs(level - (-20.0)) <= 2.0
            out.append(SnoreCaseResult(name: "谱峰与电平刻度", ok: okHz && okDb,
                                       detail: String(format: "峰值 %.1f Hz（要 150±14）／电平 %.2f dBFS（0.1 幅度的正弦要 -20±2）",
                                                      peakHz, level)))
        }

        // ② 连续鼾：30 s、每 3 s 一鼾 ⇒ 应该判出「在打」，且不该冒出中断
        do {
            var s = SnoreSynth.bed(count: Int(sr * 30), level: 0.0006, seed: 21)
            SnoreSynth.add(&s, SnoreSynth.snore(count: s.count, sampleRate: sr, periodSec: 3.0,
                                                f0: 140, level: 0.09))
            let r = SnoreTracker(frameSec: 4096.0 / sr, config: config)
            let got = run(samples: s, sampleRate: sr, config: config, into: r)
            let bouts = got.events.filter { $0.kind == .bout }
            let gaps = got.events.filter { $0.kind == .gap }
            let cov = got.seconds.reduce(0.0) { $0 + $1.snoreSec } / 30.0
            let rates = bouts.compactMap { $0.ratePerMin }
            let med = snoreMedian(rates) ?? 0
            let ok = bouts.count >= 1 && cov > 0.25 && gaps.isEmpty && abs(med - 20.0) <= 8.0
            out.append(SnoreCaseResult(name: "连续鼾要判出、不能判成中断", ok: ok,
                                       detail: String(format: "发作 %d 段／鼾声占 \(String(format: "%.0f", cov * 100))%%／中断 %d（要 0）／节律 %.1f 次/分（3 s 一鼾＝20）",
                                                      bouts.count, gaps.count, med)))
        }

        // ③ 停住再回来：12 s 鼾 → 14 s 静 → 12 s 鼾 ⇒ 至少一条疑似中断，且时长挨着 14 s
        do {
            let srLocal = sr
            let total = 40.0
            var s = SnoreSynth.bed(count: Int(srLocal * total), level: 0.0006, seed: 31)
            let a = SnoreSynth.snore(count: Int(srLocal * 12), sampleRate: srLocal, periodSec: 3.0,
                                     f0: 140, level: 0.09)
            SnoreSynth.add(&s, pad(a, into: Int(s.count), at: 2.0))
            let b = SnoreSynth.snore(count: Int(srLocal * 12), sampleRate: srLocal, periodSec: 3.0,
                                     f0: 160, level: 0.15)
            SnoreSynth.add(&s, pad(b, into: Int(s.count), at: 30.0))
            let r = SnoreTracker(frameSec: 4096.0 / srLocal, config: config)
            let got = run(samples: s, sampleRate: srLocal, config: config, into: r)
            let gaps = got.events.filter { $0.kind == .gap }
            let bouts = got.events.filter { $0.kind == .bout }
            let longest = gaps.map { $0.dur }.max() ?? 0
            let ok = bouts.count >= 2 && gaps.count >= 1 && longest >= 11.0 && longest <= 20.0
            out.append(SnoreCaseResult(name: "鼾声停住要记成疑似中断", ok: ok,
                                       detail: "发作 \(bouts.count) 段（要 ≥2）／中断 \(gaps.count) 条（要 ≥1）／最长停 \(String(format: "%.1f", longest)) s（要 11–20）"))
        }

        // ④ 说话样：不该判成鼾，但该记「其他发声」
        do {
            var s = SnoreSynth.bed(count: Int(sr * 30), level: 0.0006, seed: 41)
            SnoreSynth.add(&s, SnoreSynth.speech(count: s.count, sampleRate: sr, level: 0.06))
            let r = SnoreTracker(frameSec: 4096.0 / sr, config: config)
            let got = run(samples: s, sampleRate: sr, config: config, into: r)
            let bouts = got.events.filter { $0.kind == .bout }
            let vocals = got.events.filter { $0.kind == .vocal }
            let cov = got.seconds.reduce(0.0) { $0 + $1.snoreSec } / 30.0
            let ok = bouts.isEmpty && vocals.count >= 1
            out.append(SnoreCaseResult(name: "说话样不当鼾、要当其他发声", ok: ok,
                                       detail: "鼾 \(bouts.count) 段（要 0）／鼾声占比 \(String(format: "%.0f", cov * 100))%（要 0）／其他发声 \(vocals.count) 条（要 ≥1）"))
        }

        // ⑤ 恒定低频单音：起伏深度这一关挡掉
        do {
            var s = SnoreSynth.bed(count: Int(sr * 30), level: 0.0006, seed: 51)
            SnoreSynth.add(&s, SnoreSynth.tone(count: s.count, sampleRate: sr, freq: 120, level: 0.05))
            let r = SnoreTracker(frameSec: 4096.0 / sr, config: config)
            let got = run(samples: s, sampleRate: sr, config: config, into: r)
            let bouts = got.events.filter { $0.kind == .bout }
            out.append(SnoreCaseResult(name: "恒定嗡鸣不当鼾", ok: bouts.isEmpty,
                                       detail: "鼾 \(bouts.count) 段（要 0）"))
        }

        // ⑥ 高频单音（3 kHz）：频带这一关挡掉
        do {
            var s = SnoreSynth.bed(count: Int(sr * 30), level: 0.0006, seed: 61)
            SnoreSynth.add(&s, SnoreSynth.tone(count: s.count, sampleRate: sr, freq: 3000, level: 0.04))
            let r = SnoreTracker(frameSec: 4096.0 / sr, config: config)
            let got = run(samples: s, sampleRate: sr, config: config, into: r)
            let bouts = got.events.filter { $0.kind == .bout }
            out.append(SnoreCaseResult(name: "高频单音不当鼾", ok: bouts.isEmpty,
                                       detail: "鼾 \(bouts.count) 段（要 0）"))
        }

        // ⑦ 瞬发敲击：太短，时长这一关挡掉
        do {
            var s = SnoreSynth.bed(count: Int(sr * 20), level: 0.0006, seed: 71)
            SnoreSynth.add(&s, SnoreSynth.clicks(count: s.count, sampleRate: sr, level: 0.5,
                                                 at: [2, 5, 8, 11, 14]))
            let r = SnoreTracker(frameSec: 4096.0 / sr, config: config)
            let got = run(samples: s, sampleRate: sr, config: config, into: r)
            let bouts = got.events.filter { $0.kind == .bout }
            out.append(SnoreCaseResult(name: "瞬发敲击不当鼾", ok: bouts.isEmpty,
                                       detail: "鼾 \(bouts.count) 段（要 0）"))
        }

        // ⑧ 只有本底：一条事件都不该有，也不该报中断
        do {
            let s = SnoreSynth.bed(count: Int(sr * 30), level: 0.0009, seed: 81)
            let r = SnoreTracker(frameSec: 4096.0 / sr, config: config)
            let got = run(samples: s, sampleRate: sr, config: config, into: r)
            let ok = got.events.isEmpty
            out.append(SnoreCaseResult(name: "纯本底不该出事件", ok: ok,
                                       detail: "事件 \(got.events.count) 条（要 0）"))
        }

        // ⑨ 数字自洽：中断时长必须等于「上一鼾结束」到「复鼾开始」
        do {
            var s = SnoreSynth.bed(count: Int(sr * 40), level: 0.0006, seed: 91)
            SnoreSynth.add(&s, pad(SnoreSynth.snore(count: Int(sr * 14), sampleRate: sr, periodSec: 3.0,
                                                    f0: 140, level: 0.09), into: Int(s.count), at: 1.0))
            SnoreSynth.add(&s, pad(SnoreSynth.snore(count: Int(sr * 14), sampleRate: sr, periodSec: 3.0,
                                                    f0: 150, level: 0.12), into: Int(s.count), at: 26.0))
            let r = SnoreTracker(frameSec: 4096.0 / sr, config: config)
            let got = run(samples: s, sampleRate: sr, config: config, into: r)
            let bouts = got.events.filter { $0.kind == .bout }
            let gaps = got.events.filter { $0.kind == .gap }
            var consistent = !gaps.isEmpty
            for g in gaps {
                let prev = bouts.filter { $0.t1 <= g.t0 + 0.5 }.map { $0.t1 }.max() ?? -1
                let next = bouts.filter { $0.t0 >= g.t1 - 0.5 }.map { $0.t0 }.min() ?? -1
                if abs(g.t0 - prev) > 0.5 || abs(g.t1 - next) > 0.5 { consistent = false }
            }
            out.append(SnoreCaseResult(name: "中断两头接得上发作", ok: consistent,
                                       detail: "发作 \(bouts.count)／中断 \(gaps.count)；每条中断的起点都该压着上一段的末尾、终点顶着复鼾的开头"))
        }
        return out
    }

    /// 把一小段信号摆进整条时间线里的 at 秒处
    private static func pad(_ piece: [Double], into count: Int, at: Double) -> [Double] {
        var out = [Double](repeating: 0.0, count: count)
        let i0 = Int(at * rate)
        let n = min(piece.count, count - i0)
        guard n > 0 else { return out }
        for i in 0..<n { out[i0 + i] = piece[i] }
        return out
    }
}
