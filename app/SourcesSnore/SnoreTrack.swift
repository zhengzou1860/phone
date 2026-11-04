import Foundation

// MARK: - 事件与逐秒曲线
//
// 一晚只留两样：① 事件表（发作／疑似中断／其他发声）② 1 秒一格曲线。
// 8 小时 = 28 800 格，一格 7 个数 ⇒ 几百 KB，进程不会被自己撑死（这是敢整夜挂着的底气）。

enum SnoreEventKind: String, Codable {
    case bout      // 一次鼾声发作
    case gap       // 鼾声突然停住（疑似呼吸中断）
    case vocal     // 说话／咳嗽样发声（不是鼾，但医生会想知道）
}

struct SnoreEvent: Codable, Identifiable {
    var id: Int
    var kind: SnoreEventKind
    var t0: Double
    var t1: Double
    var dur: Double
    var peakDb: Double
    var meanDb: Double
    var ratePerMin: Double?    // 发作内的鼾声节律（次/分），自相关拿不到就 nil
    var peakHz: Double?        // 基频那一根的中位
    var preDb: Double?         // 中断前那次发作的均值（gap）
    var resumeDb: Double?      // 复鼾后 2 s 的峰值（gap）
    var arousal: Bool          // 复鼾比中断前响 3 dB 以上：更像暂停过后那口气喘回来
    var otherDuring: Bool      // 停的这一阵里夹着别的发声（翻身、梦话、咳嗽）
    var unresolved: Bool       // 到收尾还没复鼾（不打了／人走了／手机断气）
}

struct SnoreSecond: Codable {
    var t0: Int          // 会话内整秒
    var maxDb: Double
    var meanDb: Double
    var snoreSec: Double
    var vocalSec: Double
    var maxScore: Double
    var floorDb: Double
    var stale: Bool      // 这一秒一个分析帧都没等到：引擎断了/被系统暂停，图上留白
}

private struct TimeValue {
    var t: Double
    var v: Double
}

// MARK: - 状态机：逐帧读数 → 发作、疑似中断、其他发声、逐秒曲线

final class SnoreTracker {
    var config: SnoreConfig
    let frameSec: Double

    var onEvent: ((SnoreEvent) -> Void)?
    var onSecond: ((SnoreSecond) -> Void)?

    /// 下一件事件的编号：界面上「听片段」按 id 找 snippets/s_12.wav，两头都用它。
    private(set) var nextId = 1

    // 给界面实时读的
    private(set) var liveSnoring = false
    private(set) var liveScore = 0.0
    private(set) var liveLevel = -120.0
    private(set) var liveFloor = -75.0
    private(set) var liveOpenGapSec = 0.0
    private(set) var boutCount = 0
    private(set) var gapCount = 0
    private(set) var vocalCount = 0
    private(set) var snoreSecTotal = 0.0
    private(set) var longestBout = 0.0
    private(set) var longestGap = 0.0
    private(set) var boutRates: [Double] = []

    // 迟滞与发作
    private var snoreOn = false
    private var overEnterStart: Double?
    private var lastSnoreTime = -1_000_000.0
    private var boutStart = 0.0
    private var boutFrames = 0
    private var boutLevelSum = 0.0
    private var boutLevelMax = -120.0
    private var boutPeakHz: [Double] = []

    // 低频包络：逐帧都记，留最近 10 s。节律（次/分）的自相关就吃这一段——
    // 一次发作常常只有两三个鼾，往前多带 1.5 s 才够摆出周期。
    private var envRing: [TimeValue] = []

    // 上一次刚收尾的发作（判「复鼾比中断前响」要跟它比）
    private var lastClosedBoutMean = -120.0

    // 鼾帧时刻：判「刚才确实在打」用，只留最近 4 分钟
    private var snoreTimes: [Double] = []

    // 疑似中断
    private var gapStart: Double?
    private var gapClosingAt: Double?
    private var gapResumeMax = -120.0
    private var gapOther = false
    private var voicedSinceSnore = 0

    // 其他发声
    private var vocalOn = false
    private var vocalRunStart: Double?
    private var vocalLast = -1_000_000.0
    private var vocalStart = 0.0
    private var vocalFrames = 0
    private var vocalLevelSum = 0.0
    private var vocalLevelMax = -120.0

    // 逐秒
    private var secIdx = -1
    private var secFrames = 0
    private var secLevelSum = 0.0
    private var secLevelMax = -120.0
    private var secSnore = 0.0
    private var secVocal = 0.0
    private var secScoreMax = 0.0
    private var secFloor = -75.0

    /// 节律自相关吃的包络长度：最长周期 6 s + 前后各留一段，10 s 是下限
    private static let envKeepSec = 10.0
    /// 判定「这次中断」需要的前置活动：最近 4 分钟里至少打了 8 秒鼾。
    /// 8 秒是拿合成信号试出来的下限：再高，入睡初期那种十几秒的短鼾段里停住就报不出来，
    /// 而那正是最该报的时段；再低，两声咳嗽之间的空白会被当成一次中断。
    private static let activityWindowSec = 240.0
    private static let activityMinSec = 8.0

    init(frameSec: Double, config: SnoreConfig) {
        self.frameSec = frameSec > 0.005 ? frameSec : 0.085
        self.config = config
    }

    /// 会话收尾：结掉还挂着的发作／发声／秒格，够长的未复鼾中断也留一条。
    func finish(at t: Double) {
        if snoreOn {
            closeBout(at: max(boutStart, min(lastSnoreTime, t)))
            snoreOn = false
            liveSnoring = false
        }
        if vocalOn {
            closeVocal(at: max(vocalStart, min(vocalLast, t)))
            vocalOn = false
        }
        if secFrames > 0 {
            emitSecond(index: secIdx, stale: false)
            secFrames = 0
        }
        if gapClosingAt == nil, let gs = gapStart, (t - gs) >= 30.0 {
            emitGap(t0: gs, t1: t, resumeDb: nil, otherDuring: gapOther, unresolved: true)
        }
        gapStart = nil
        gapClosingAt = nil
        liveOpenGapSec = 0
    }

    func accept(_ f: SnoreFeature) {
        let enter = config.enterScore
        let exit = config.exitScore

        liveScore = f.score
        liveLevel = f.level
        liveFloor = f.floor
        if let gs = gapStart { liveOpenGapSec = max(0, f.t - gs) }

        envRing.append(TimeValue(t: f.t, v: f.envLow))
        let envLimit = f.t - Self.envKeepSec
        var drop = 0
        while drop < envRing.count && (envRing[drop].t < envLimit || envRing.count - drop > 600) {
            drop += 1
        }
        if drop > 0 { envRing.removeFirst(drop) }

        var snoreFrame = false

        // ① 鼾的迟滞：进门要连续够 0.25 s 达 enter，出门是「低于 exit 且拖过 boutGap」
        if snoreOn {
            if f.score >= exit {
                snoreFrame = true
                lastSnoreTime = f.t
                accumulateBout(f)
                snoreTimes.append(f.t)
                voicedSinceSnore = 0
            } else if f.t - lastSnoreTime > config.boutGapSec {
                closeBout(at: lastSnoreTime)
                snoreOn = false
            }
        }
        if !snoreOn {
            if f.score >= enter {
                if overEnterStart == nil { overEnterStart = f.t }
                if f.t - (overEnterStart ?? f.t) >= 0.25 {
                    let start = overEnterStart ?? f.t
                    overEnterStart = nil
                    snoreOn = true
                    snoreFrame = true
                    lastSnoreTime = f.t
                    voicedSinceSnore = 0
                    openBout(start: start, f: f)
                    snoreTimes.append(f.t)
                    beginGapCloseIfNeeded(boutStart: start, f: f)
                }
            } else {
                overEnterStart = nil
            }
        }
        if f.voiced && !snoreFrame { voicedSinceSnore += 1 }
        if gapClosingAt != nil && f.peak > gapResumeMax { gapResumeMax = f.peak }
        liveSnoring = snoreOn

        // ② 疑似中断：停够了、刚才确实在打、当前不在中断里
        if gapStart == nil && gapClosingAt == nil && !snoreOn && lastSnoreTime > 0 {
            let idle = f.t - lastSnoreTime
            if idle >= config.interruptGapSec && recentSnoreSec() >= Self.activityMinSec {
                gapStart = lastSnoreTime
                gapOther = voicedSinceSnore > 0
                gapResumeMax = -120.0
            }
        }
        // 复鼾后满 2 s 才能量出「喘回来那一下有多响」，到点结掉这一条
        if let closing = gapClosingAt, f.t >= closing + 2.0 {
            if let gs = gapStart {
                emitGap(t0: gs, t1: closing, resumeDb: gapResumeMax, otherDuring: gapOther,
                        unresolved: false)
            }
            gapStart = nil
            gapClosingAt = nil
            gapOther = false
            gapResumeMax = -120.0
            liveOpenGapSec = 0
        }

        // ③ 其他发声（说话／咳嗽样）：有声音、不够鼾、中高频占大头
        let vocalish = f.voiced && f.score < enter && f.hiRatio > 0.38
        if vocalOn {
            if vocalish {
                vocalLast = f.t
                accumulateVocal(f)
            } else if snoreFrame {
                closeVocal(at: f.t)
                vocalOn = false
                vocalRunStart = nil
            } else if f.t - vocalLast > 0.8 {
                closeVocal(at: vocalLast)
                vocalOn = false
                vocalRunStart = nil
            }
        } else if vocalish {
            if vocalRunStart == nil { vocalRunStart = f.t }
            if f.t - (vocalRunStart ?? f.t) >= 0.2 {
                vocalOn = true
                vocalStart = vocalRunStart ?? f.t
                vocalLast = f.t
                vocalRunStart = nil
                accumulateVocal(f)
            }
        } else {
            vocalRunStart = nil
        }

        trimSnoreTimes(floor: f.t - Self.activityWindowSec)
        rollSeconds(to: f.t, f: f, snoreFrame: snoreFrame, vocalFrame: vocalish)
    }

    // MARK: 发作

    private func openBout(start: Double, f: SnoreFeature) {
        boutStart = start
        boutFrames = 1
        boutLevelSum = f.level
        boutLevelMax = f.peak
        boutPeakHz = [f.peakHz]
    }

    private func accumulateBout(_ f: SnoreFeature) {
        boutFrames += 1
        boutLevelSum += f.level
        if f.peak > boutLevelMax { boutLevelMax = f.peak }
        // 基频逐 4 帧取一个就够算中位，别把长发作撑大
        if boutFrames % 4 == 1 { boutPeakHz.append(f.peakHz) }
    }

    private func closeBout(at endT: Double) {
        let dur = max(0, endT - boutStart)
        let frames = boutFrames
        let mean = frames > 0 ? boutLevelSum / Double(frames) : -120.0
        let maxDb = boutLevelMax
        let hz = boutPeakHz
        let start = boutStart
        defer {
            boutFrames = 0
            boutLevelSum = 0
            boutLevelMax = -120.0
            boutPeakHz = []
            if dur > 0 {
                lastClosedBoutMean = mean
            }
        }
        guard dur >= config.minBoutSec else { return }
        let rate = periodicity(from: start - 1.5, to: endT)
        boutCount += 1
        if dur > longestBout { longestBout = dur }
        snoreSecTotal += dur
        if let r = rate { boutRates.append(r) }
        let e = SnoreEvent(id: nextId, kind: .bout, t0: start, t1: endT, dur: dur,
                           peakDb: maxDb, meanDb: mean, ratePerMin: rate,
                           peakHz: snoreMedian(hz), preDb: nil, resumeDb: nil,
                           arousal: false, otherDuring: false, unresolved: false)
        nextId += 1
        onEvent?(e)
    }

    // MARK: 疑似中断

    private func beginGapCloseIfNeeded(boutStart: Double, f: SnoreFeature) {
        guard gapStart != nil && gapClosingAt == nil else { return }
        gapClosingAt = boutStart
        gapResumeMax = f.peak
    }

    private func emitGap(t0: Double, t1: Double, resumeDb: Double?, otherDuring: Bool,
                         unresolved: Bool) {
        let dur = max(0, t1 - t0)
        guard dur >= config.interruptGapSec else { return }
        if dur > longestGap { longestGap = dur }
        let pre = lastClosedBoutMean > -119 ? lastClosedBoutMean : nil
        let arous = (resumeDb ?? -120.0) > (pre ?? -120.0) + 3.0
        let e = SnoreEvent(id: nextId, kind: .gap, t0: t0, t1: t1, dur: dur,
                           peakDb: resumeDb ?? -120.0, meanDb: -120.0, ratePerMin: nil, peakHz: nil,
                           preDb: pre, resumeDb: resumeDb, arousal: arous,
                           otherDuring: otherDuring, unresolved: unresolved)
        nextId += 1
        onEvent?(e)
    }

    /// 「刚才确实在打」：否则半夜安静躺着、或整晚根本没鼾，都不该报中断。
    private func recentSnoreSec() -> Double {
        return Double(snoreTimes.count) * frameSec
    }

    private func trimSnoreTimes(floor: Double) {
        var drop = 0
        while drop < snoreTimes.count && snoreTimes[drop] < floor { drop += 1 }
        if drop > 0 { snoreTimes.removeFirst(drop) }
    }

    // MARK: 其他发声

    private func accumulateVocal(_ f: SnoreFeature) {
        vocalFrames += 1
        vocalLevelSum += f.level
        if f.peak > vocalLevelMax { vocalLevelMax = f.peak }
    }

    private func closeVocal(at endT: Double) {
        let dur = max(0, endT - vocalStart)
        let frames = vocalFrames
        let mean = frames > 0 ? vocalLevelSum / Double(frames) : -120.0
        let maxDb = vocalLevelMax
        defer {
            vocalFrames = 0
            vocalLevelSum = 0
            vocalLevelMax = -120.0
        }
        guard dur >= 0.4 else { return }
        vocalCount += 1
        let e = SnoreEvent(id: nextId, kind: .vocal, t0: vocalStart, t1: endT, dur: dur,
                           peakDb: maxDb, meanDb: mean, ratePerMin: nil, peakHz: nil,
                           preDb: nil, resumeDb: nil, arousal: false, otherDuring: false,
                           unresolved: false)
        nextId += 1
        onEvent?(e)
    }

    // MARK: 节律（低频包络的自相关）

    /// 取 envRing 里 [from, to] 那一段包络做归一化自相关，找呼吸节律（1–6 s 一鼾）。
    private func periodicity(from: Double, to: Double) -> Double? {
        var vals: [Double] = []
        for s in envRing where s.t >= from && s.t <= to { vals.append(s.v) }
        let fps = 1.0 / frameSec
        let lagLo = max(2, Int((1.0 * fps).rounded()))
        let lagHi = max(lagLo, Int((6.0 * fps).rounded()))
        // 至少要攒够「两个最长周期」才谈得上找周期，否则报出来的次/分是猜的
        guard vals.count >= lagHi * 2 else { return nil }
        let m = snoreMean(vals)
        var best = -2.0
        var bestLag = 0
        var lag = lagLo
        while lag <= lagHi {
            var s = 0.0
            var ea = 0.0
            var eb = 0.0
            var i = 0
            let limit = vals.count - lag
            while i < limit {
                let a = vals[i] - m
                let b = vals[i + lag] - m
                s += a * b
                ea += a * a
                eb += b * b
                i += 1
            }
            let norm = s / (sqrt(ea * eb) + 1e-12)
            if norm > best { best = norm; bestLag = lag }
            lag += 1
        }
        guard best >= 0.30 && bestLag > 0 else { return nil }
        let period = Double(bestLag) * frameSec
        guard period >= 1.0 && period <= 6.0 else { return nil }
        return 60.0 / period
    }

    // MARK: 逐秒曲线

    private func rollSeconds(to t: Double, f: SnoreFeature, snoreFrame: Bool, vocalFrame: Bool) {
        let idx = Int(floor(t))
        if secIdx < 0 {
            secIdx = idx
            clearSecond()
        } else if idx > secIdx {
            if secFrames > 0 { emitSecond(index: secIdx, stale: false) }
            var k = secIdx + 1
            while k < idx {
                emitSecond(index: k, stale: true)
                k += 1
            }
            secIdx = idx
            clearSecond()
        }
        secFrames += 1
        secLevelSum += f.level
        if f.peak > secLevelMax { secLevelMax = f.peak }
        if snoreFrame { secSnore += frameSec }
        if vocalFrame { secVocal += frameSec }
        if f.score > secScoreMax { secScoreMax = f.score }
        secFloor = f.floor
    }

    private func clearSecond() {
        secFrames = 0
        secLevelSum = 0.0
        secLevelMax = -120.0
        secSnore = 0.0
        secVocal = 0.0
        secScoreMax = 0.0
    }

    private func emitSecond(index: Int, stale: Bool) {
        guard index >= 0 else { return }
        let b: SnoreSecond
        if stale {
            b = SnoreSecond(t0: index, maxDb: -120, meanDb: -120, snoreSec: 0, vocalSec: 0,
                            maxScore: 0, floorDb: secFloor, stale: true)
        } else {
            b = SnoreSecond(t0: index,
                            maxDb: secLevelMax,
                            meanDb: secFrames > 0 ? secLevelSum / Double(secFrames) : -120,
                            snoreSec: min(1.0, secSnore),
                            vocalSec: min(1.0, secVocal),
                            maxScore: secScoreMax,
                            floorDb: secFloor,
                            stale: false)
        }
        clearSecond()
        onSecond?(b)
    }
}
