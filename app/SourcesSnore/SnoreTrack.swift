import Foundation

// MARK: - 事件与逐秒曲线
//
// 一晚只留两样：① 事件表（发作／疑似中断／其他发声）② 1 秒一格曲线。
// 8 小时 = 28 800 格，一格 8 个数 ⇒ 几百 KB，进程不会被自己撑死（这是敢整夜挂着的底气）。

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
    var ratePerMin: Double?    // 发作内的鼾声节律（次/分）：这一段数不出「两次以上的鼾间隔」就 nil
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
    var vocalSec: Double     // 有声音但没成鼾的时长（说话、咳、翻身响动都算）
    var maxScore: Double     // 这一秒里最高的那次「像鼾分」（频谱×节律门，就是判进门的那个数）
    var floorDb: Double
    var stale: Bool          // 这一秒一个分析帧都没等到：引擎断了/被系统暂停，图上留白
}

// MARK: - 呼吸节律门
//
// 频谱打分回答的是「这一段声音像不像鼾」，回答不了「它是不是跟着呼吸一开一合」。
// 冰箱嗡鸣、电视低音、隔墙说话，频谱都能拿高分（低频、有谐波、稳）；
// 鼾独有的形状是：一段一段地响，每段 0.4–0.8 s，段与段隔 1–6 s。这一门就把形状数出来。

enum SnoreRhythm {
    /// 一鼾的收尾：声音停了这么久就不再续着算（一次吸气的量级，比 boutGapSec 短得多）
    static let burstHoldSec = 0.30
    /// 占空比吃的窗：最近 8 s 里有多少时间是响着的
    static let dutyWindowSec = 8.0
    /// 节律吃的窗：只数「这一段声音自己」的鼾，最多往回看 20 s
    static let rhythmWindowSec = 20.0
    /// 一鼾该有的长度：短于它是咳嗽／关门，长于它是持续的嗡鸣
    static let burstDurLo = 0.4
    static let burstDurHi = 0.8
    /// 鼾与鼾的间隔：1–6 s 是呼吸的量级；0.4–1 s 线性给分，再密就不算呼吸了
    static let intervalLo = 1.0
    static let intervalHi = 6.0
    static let intervalFloor = 0.4
    /// 节律数不出来时把频谱压到多少：0.45 意味着「再像也砍一半以上」。
    /// 不能压到 0——刚开口的头几个鼾、隔着枕头听不清的那些，形状本来就数不出来。
    static let gateFloor = 0.45

    /// 一次「连续响着」的声音，即一鼾
    struct Burst {
        var t0: Double
        var t1: Double
        var dur: Double { t1 - t0 }
    }

    /// 响着的时长占最近 8 s 的比例。鼾是「一开一合」，一直响着的不是。
    /// 不到 0.10 是刚开口，线性给；0.85–0.95 收口；占满就是持续声，0 分。
    static func dutyScore(voicedFrames: Int, frameSec: Double) -> Double {
        let frac = Double(voicedFrames) * frameSec / dutyWindowSec
        if frac < 0.10 { return frac / 0.10 }
        if frac <= 0.85 { return 1.0 }
        if frac >= 0.95 { return 0.0 }
        return (0.95 - frac) / 0.10
    }

    /// 门 = 一开一合（占空）× 每鼾够长（时长）× 间隔像呼吸；顺带报出节律（次/分）。
    /// bursts 按时间先后排，inProgress 是还没停的那一声。
    static func gate(bursts: [Burst], inProgress: Burst?, voicedFrames: Int,
                     frameSec: Double) -> (gate: Double, ratePerMin: Double?) {
        var items = bursts
        if let p = inProgress { items.append(p) }
        guard !items.isEmpty else { return (0.0, nil) }
        let d = dutyScore(voicedFrames: voicedFrames, frameSec: frameSec)
        let meanDur = snoreMedian(items.map { $0.dur }) ?? 0.0
        let ds = snoreClamp01((meanDur - burstDurLo) / (burstDurHi - burstDurLo))
        let onsets = items.map { $0.t0 }
        // 只有一段声音：既谈不上「间隔」，也无从分辨是鼾还是一声长响——门归零。
        // 这一条给 0.66 之类的宽容值试过：突起的嗡鸣能在灵敏度「高」那档撑出 20 多秒的发作。
        guard onsets.count >= 2 else { return (0.0, nil) }
        var diffs: [Double] = []
        for i in 1..<onsets.count { diffs.append(onsets[i] - onsets[i - 1]) }
        let iv = snoreMedian(diffs) ?? 0.0
        let isr: Double
        if iv < intervalFloor {
            isr = 0.0
        } else if iv < intervalLo {
            isr = (iv - intervalFloor) / (intervalLo - intervalFloor)
        } else if iv <= intervalHi {
            isr = 1.0
        } else if iv <= intervalHi + 2.0 {
            isr = (intervalHi + 2.0 - iv) / 2.0
        } else {
            isr = 0.0
        }
        let rate: Double? = iv >= intervalLo ? 60.0 / iv : nil
        return (d * ds * isr, rate)
    }
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

    // 迟滞与发作
    private var snoreOn = false
    private var overEnterStart: Double?
    private var lastSnoreTime = -1_000_000.0
    private var lastBoutEnd = -1_000_000.0
    private var boutStart = 0.0
    private var boutFrames = 0
    private var boutLevelSum = 0.0
    private var boutLevelMax = -120.0
    private var boutPeakHz: [Double] = []

    // 上一次刚收尾的发作（判「复鼾比中断前响」要跟它比）
    private var lastClosedBoutMean = -120.0

    // 鼾帧时刻：判「刚才确实在打」用，只留最近 4 分钟
    private var snoreTimes: [Double] = []

    // 呼吸节律：把有声帧串成一鼾一鼾
    private var bursts: [SnoreRhythm.Burst] = []
    private var voicedTimes: [Double] = []
    private var soundStart: Double?
    private var soundLast = -1_000_000.0
    private var lastBurstEnd = -1_000_000.0
    /// 本段连续有声的开口时刻：发作的起点往回钉到这里
    private var episodeStart: Double?
    private var burstRate: Double?

    // 「一段声音」：从有声到拖过 boutGap。收尾时才决定记不记成其他发声。
    private var epOpen = false
    private var epT0 = 0.0
    private var epT1 = -1_000_000.0
    private var epFrames = 0
    private var epLevelSum = 0.0
    private var epLevelMax = -120.0
    private var epHadBout = false

    // 疑似中断
    private var gapStart: Double?
    private var gapClosingAt: Double?
    private var gapResumeMax = -120.0
    private var gapOther = false

    // 逐秒
    private var secIdx = -1
    private var secFrames = 0
    private var secLevelSum = 0.0
    private var secLevelMax = -120.0
    private var secSnore = 0.0
    private var secVocal = 0.0
    private var secScoreMax = 0.0
    private var secFloor = -75.0

    /// 判定「这次中断」需要的前置活动：最近 4 分钟里至少打了 3 秒鼾。
    /// 3 秒≈两个呼吸周期的鼾——再高，入睡初期那种十几秒的短鼾段里停住就报不出来，
    /// 而那正是最该报的时段；再低，两声咳嗽之间的空白会被当成一次中断。
    private static let activityWindowSec = 240.0
    private static let activityMinSec = 3.0

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
        if epOpen {
            commitEpisode(at: min(epT1, t))
            epOpen = false
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

        liveLevel = f.level
        liveFloor = f.floor
        if let gs = gapStart { liveOpenGapSec = max(0, f.t - gs) }

        let rhythm = updateRhythm(f)
        // 进门的那把尺子：频谱 × 节律门。门数不出形状时也不是 0，还有 gateFloor 那一份。
        let eff = f.score * (SnoreRhythm.gateFloor + (1.0 - SnoreRhythm.gateFloor) * rhythm.gate)
        liveScore = eff

        var snoreFrame = false

        // ① 鼾的迟滞：进门要连续够 0.25 s 达 enter，出门是「低于 exit 且拖过 boutGap」
        if snoreOn {
            if eff >= exit {
                snoreFrame = true
                lastSnoreTime = f.t
                accumulateBout(f)
                snoreTimes.append(f.t)
            } else if f.t - lastSnoreTime > config.boutGapSec {
                closeBout(at: lastSnoreTime)
                snoreOn = false
            }
        }
        if !snoreOn {
            if eff >= enter {
                if overEnterStart == nil { overEnterStart = f.t }
                if f.t - (overEnterStart ?? f.t) >= 0.25 {
                    // 起点往回钉到这一段声音开口那一帧：确认节律花掉的 0.25 s 本该算在发作里，
                    // 不然每段发作的头都被削掉一块，跟着算的中断时长也跟着失真。
                    // 但不能钉到上一段发作之前——那等于把中断自己抹掉一截。
                    let raw = episodeStart ?? f.t
                    let start = min(max(raw, lastBoutEnd), f.t)
                    overEnterStart = nil
                    snoreOn = true
                    snoreFrame = true
                    lastSnoreTime = f.t
                    openBout(start: start, f: f)
                    snoreTimes.append(f.t)
                    beginGapCloseIfNeeded(boutStart: start, f: f)
                }
            } else {
                overEnterStart = nil
            }
        }
        if gapClosingAt != nil && f.peak > gapResumeMax { gapResumeMax = f.peak }
        liveSnoring = snoreOn

        // ② 一段声音（有声、还没成鼾）先攒着；成过鼾的那一段收尾时不记「其他发声」
        if f.voiced && eff < enter { accumulateEpisode(f) }
        if snoreFrame { epHadBout = true }
        if epOpen && f.t - epT1 > config.boutGapSec {
            commitEpisode(at: epT1)
            epOpen = false
        }

        // ③ 疑似中断：停够了、刚才确实在打、当前不在中断里
        if gapStart == nil && gapClosingAt == nil && !snoreOn && lastSnoreTime > 0 {
            let idle = f.t - lastSnoreTime
            if idle >= config.interruptGapSec && recentSnoreSec() >= Self.activityMinSec {
                gapStart = lastSnoreTime
                gapOther = false
                gapResumeMax = -120.0
            }
        }
        // 中断开着的那一阵里只要有过声音就记账（在起点看一眼不够：梦话常在停住之后才来）
        if gapStart != nil && gapClosingAt == nil && f.voiced { gapOther = true }
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

        trimSnoreTimes(floor: f.t - Self.activityWindowSec)
        rollSeconds(to: f.t, f: f, eff: eff, snoreFrame: snoreFrame, vocalFrame: f.voiced && eff < enter)
    }

    // MARK: 呼吸节律

    /// 把逐帧的「有没有声音」串成一鼾一鼾，交给 SnoreRhythm 打分；同时维护「一段声音」的边界。
    private func updateRhythm(_ f: SnoreFeature) -> (gate: Double, ratePerMin: Double?) {
        if f.voiced {
            voicedTimes.append(f.t)
            if soundStart == nil {
                soundStart = f.t
                // 离上一鼾够远 ⇒ 是新的一段声音：节律从零数起，别拿上一段的旧鼾替它作保
                // （不然说话挨着鼾声会借隔壁的呼吸节律混成一次发作）。
                if episodeStart == nil || f.t - lastBurstEnd > config.boutGapSec {
                    episodeStart = f.t
                    bursts = []
                    openEpisode(at: f.t)
                }
            }
            soundLast = f.t
        }
        if f.voiced && f.t > epT1 {
            epT1 = f.t
        } else if let s0 = soundStart, f.t - soundLast >= SnoreRhythm.burstHoldSec {
            bursts.append(SnoreRhythm.Burst(t0: s0, t1: soundLast))
            lastBurstEnd = soundLast
            soundStart = nil
        }

        var dropB = 0
        let cutB = f.t - SnoreRhythm.rhythmWindowSec
        while dropB < bursts.count && bursts[dropB].t1 < cutB { dropB += 1 }
        if dropB > 0 { bursts.removeFirst(dropB) }
        var dropV = 0
        let cutV = f.t - SnoreRhythm.dutyWindowSec
        while dropV < voicedTimes.count && voicedTimes[dropV] < cutV { dropV += 1 }
        if dropV > 0 { voicedTimes.removeFirst(dropV) }

        let inProgress: SnoreRhythm.Burst? = soundStart.map { SnoreRhythm.Burst(t0: $0, t1: soundLast) }
        let g = SnoreRhythm.gate(bursts: bursts, inProgress: inProgress,
                                 voicedFrames: voicedTimes.count, frameSec: frameSec)
        burstRate = g.ratePerMin
        return g
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
        let rate = burstRate
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
        lastBoutEnd = endT
        boutCount += 1
        if dur > longestBout { longestBout = dur }
        snoreSecTotal += dur
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
        gapCount += 1
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

    private func openEpisode(at t: Double) {
        epOpen = true
        epT0 = t
        epT1 = t
        epFrames = 0
        epLevelSum = 0.0
        epLevelMax = -120.0
        epHadBout = false
    }

    private func accumulateEpisode(_ f: SnoreFeature) {
        epFrames += 1
        epLevelSum += f.level
        if f.peak > epLevelMax { epLevelMax = f.peak }
    }

    /// 一段声音收尾才记账：够长、且这一段里一次鼾都没判出来，才是「其他发声」。
    /// 不在中途记——鼾的确认要晚 0.25 s，先把开头那半秒记成梦话、再把它改判成鼾，
    /// 界面上就成了「刚睡着就说梦话」的假事（一晚能凭空多出五六条）。
    private func commitEpisode(at endT: Double) {
        let dur = max(0, endT - epT0)
        let frames = epFrames
        let mean = frames > 0 ? epLevelSum / Double(frames) : -120.0
        let maxDb = epLevelMax
        let hadBout = epHadBout
        let start = epT0
        epFrames = 0
        epLevelSum = 0.0
        epLevelMax = -120.0
        guard !hadBout, dur >= 0.4 else { return }
        vocalCount += 1
        let e = SnoreEvent(id: nextId, kind: .vocal, t0: start, t1: endT, dur: dur,
                           peakDb: maxDb, meanDb: mean, ratePerMin: nil, peakHz: nil,
                           preDb: nil, resumeDb: nil, arousal: false, otherDuring: false,
                           unresolved: false)
        nextId += 1
        onEvent?(e)
    }

    // MARK: 逐秒曲线

    private func rollSeconds(to t: Double, f: SnoreFeature, eff: Double,
                             snoreFrame: Bool, vocalFrame: Bool) {
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
        if eff > secScoreMax { secScoreMax = eff }
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
