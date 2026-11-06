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
    var resumeDb: Double?      // 复鼾那一声的峰值（gap）
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
    var maxScore: Double     // 这一秒里最高的那次「逐帧频谱像鼾分」（0…1，不含节律：判定在收口时做）
    var floorDb: Double
    var stale: Bool          // 这一秒一个分析帧都没等到：引擎断了/被系统暂停，图上留白
    /// 同一秒里「不看响度门」的那份频谱分的最大值（0…1）。响度门以下的秒这里照样有数，
    /// 而 maxScore 是 0 —— 两者一比就是「这片时间是真安静，还是轻到门以下没敢判」。
    ///
    /// 这一列必须留在 CSV 的最后一格：curve.csv 按位置解析，老晚上的文件没有第 9 列，
    /// 加在中间会把后面每一列都读错位。
    var maxScoreNoGate: Double = 0
}

// MARK: - 判定单位是「一次发声」，不是「一帧」
//
// 老写法是逐帧迟滞：像鼾分连续过线 0.25 s 才进门。真鼾不吃这一套，两处都亏：
//   ① 一声鼾只有 0.3–0.5 s，证据还没攒够（要 ≥0.4 s）它就响完了；
//   ② 真鼾一口气只响一声（隔 5–8 s 才来下一声），而往回的节律门在静默超过 boutGapSec
//      时把上一鼾清零 ⇒ 永远数不出第二个开声 ⇒ 门恒 0 ⇒ 频谱再像也要被砍一半，进不了门。
// 用户手机上「离得很近却一件鼾都没判出来」就是这条：日志里逐帧频谱分 0.9 上下、电平比本底高
// 20 多 dB，可【鼾声占比】0.0%、事件表里全是「其他发声」。合成用例也全用 2.8–4.0 s 的周期，
// 比 boutGapSec 短 ⇒ 这套写法在自检里天生就是对的，抓不到。
//
// 现在：响完（停了 holdSec 以上）再算总账。那时段长、频谱中位、帧间稳定中位三样都齐了，
// 拿这三样判「像不像一次吸气里的鼾」，再要求它跟邻鼾配成一次呼吸的量级（1–10 s）；
// 一晚的头几声没有邻鼾，就要求频谱自己高过「判定分＋单独余量」才敢单判。
// 判完才把一声一声串成发作，所以「鼾次/分」这种数是从收口的时刻表里来的，不是逐帧凑的。

enum SnoreSound {
    /// 声音停了这么久就不再续着算同一声
    static let holdSec = 0.30
    /// 段长的形状分：0.10 起分、0.30 满分、2.0 以后往下掉、4.0 归零——一次吸气的量级
    static let durRise = 0.10
    static let durLo = 0.30
    static let durHi = 2.0
    static let durFall = 4.0
    /// 形状分要够这一条才算「够一次吸气」
    static let shapeBar = 0.60
    /// 鼾与鼾的间隔：1–10 s（一口气 6–10 s，浅睡期更密）；再密是颤音／咳嗽连环，不算呼吸
    static let intervalLo = 1.0
    static let intervalHi = 10.0
    /// 帧间频谱稳定度的中位低于这个就当「在说话」：说话共振峰一直在跑（实测 0.51–0.55），
    /// 鼾不管密集还是稀疏都是同一姿势在震（实测 1.00）。这一条是早点「识破说话」的那关，
    /// 少了它，说话会借隔壁鼾段的呼吸间隔混成一次发作——把真中断抹平。
    static let stabLo = 0.72
    /// 没有邻鼾可配时（一晚的头几声）频谱中位要额外高这么多才敢单判
    static let soloMargin = 0.30
    /// 邻鼾配对最多往回看这么久
    static let pairWindowSec = 12.0

    /// 0…1：这一段声音的长度像不像一次吸气
    static func shapeOf(dur: Double) -> Double {
        return snoreClamp01((dur - durRise) / (durLo - durRise))
            * snoreClamp01((durFall - dur) / (durFall - durHi))
    }
}

// MARK: - 状态机：逐帧读数 → 发作、疑似中断、其他发声、逐秒曲线

final class SnoreTracker {
    var config: SnoreConfig
    let frameSec: Double

    var onEvent: ((SnoreEvent) -> Void)?
    var onSecond: ((SnoreSecond) -> Void)?
    /// 一声收口后回头补的那几秒格子。判定要等响完，格子却已经先发出去了（图上先画响度、
    /// 鼾色随后补上）；SnoreStore 按 t0 原位改一格，盘上还是 30 s 一重写。
    var onSecondAmend: ((SnoreSecond) -> Void)?

    /// 下一件事件的编号：界面上「听片段」按 id 找 snippets/s_12.wav，两头都用它。
    private(set) var nextId = 1

    // 给界面实时读的
    private(set) var liveSnoring = false
    private(set) var liveScore = 0.0
    private(set) var liveLevel = -120.0
    private(set) var liveFloor = -75.0
    private(set) var liveOpenGapSec = 0.0
    private(set) var liveSoundDur = 0.0
    private(set) var boutCount = 0
    private(set) var gapCount = 0
    private(set) var vocalCount = 0
    private(set) var snoreSecTotal = 0.0
    private(set) var longestBout = 0.0
    private(set) var longestGap = 0.0

    // 发给日志的账：「为什么没判成鼾」靠这几个数分流，不用猜
    private(set) var soundTotal = 0        // 收口的声音一共多少
    private(set) var soundShaped = 0       // 段长＋频谱＋稳定三样都过关的
    private(set) var soundSnore = 0        // 判成鼾的
    private(set) var soundLonely = 0       // 三样过关、却没配上邻鼾也没高到能单判的（线上那次漏判就卡这）
    private(set) var loudestRejected = ""  // 最响的那一声「不是鼾」的完整数字，收尾时一行日志

    /// 正在响的这一声
    private struct Draft {
        var t0 = 0.0
        var t1 = 0.0
        var raws: [Double] = []
        var stabs: [Double] = []
        var lvSum = 0.0
        var frames = 0
        var pk = -120.0
        var hz: [Double] = []
    }
    private var draft: Draft?
    /// 频谱／稳定度最多各攒这么多帧（约一分钟的量）：再长的声音靠形状分那一关就否掉了，
    /// 不值得为一整晚不响的循环嗡鸣养着一条长数组。
    private static let draftCap = 600

    /// 一声收口之后的账（留着给后面的鼾配对，只保最近 pairWindowSec）
    private final class Closed {
        let t0: Double
        let t1: Double
        let dur: Double
        let raw: Double
        let stab: Double
        let pk: Double
        let mean: Double
        let hz: Double?
        let shapeOk: Bool
        var snore = false
        init(t0: Double, t1: Double, dur: Double, raw: Double, stab: Double, pk: Double,
             mean: Double, hz: Double?, shapeOk: Bool) {
            self.t0 = t0; self.t1 = t1; self.dur = dur; self.raw = raw; self.stab = stab
            self.pk = pk; self.mean = mean; self.hz = hz; self.shapeOk = shapeOk
        }
    }
    private var closed: [Closed] = []

    /// 逐秒用的记账：一段声音从收口起才知道算鼾还是算别的发声
    private struct Mark {
        var t0: Double
        var t1: Double
        var snore: Bool
    }
    private var marks: [Mark] = []

    /// 已经发出去的秒格子（回填用）。只留最近这些秒：判成鼾的一声最长 2.8 s（形状分那关卡的），
    /// 加上一句「孤单的声被后面的鼾认下来」要往回照应的 12 s，留 24 s 足够。
    private var recent: [Int: SnoreSecond] = [:]
    private static let amendWindowSec = 24.0

    /// 发作：把一鼾一鼾串成「这一段在打」
    private struct Run {
        var t0: Double
        var t1: Double
        var n = 0
        var pk = -120.0
        var lvSum = 0.0
        var lvN = 0
        var hz: [Double] = []
    }
    private var run: Run?
    private var runOnsets: [Double] = []
    private var lastSnoreEnd = -1_000_000.0
    private var lastRunMean = -120.0

    /// 鼾帧时刻：判「刚才确实在打」用，只留最近 4 分钟
    private var snoreTimes: [Double] = []
    private static let activityWindowSec = 240.0
    /// 判定「这次中断」需要的前置活动：最近 4 分钟里至少打了 3 秒鼾。
    /// 3 秒≈两口气的鼾——再高，入睡初期那种十几秒的短鼾段里停住就报不出来，
    /// 而那正是最该报的时段；再低，两声咳嗽之间的空白会被当成一次中断。
    private static let activityMinSec = 3.0

    /// 中断那一阵里有没有夹着别的发声（梦话、翻身、咳）
    private var gapOther = false

    // 逐秒
    private var secIdx = -1
    private var secFrames = 0
    private var secLevelSum = 0.0
    private var secLevelMax = -120.0
    private var secScoreMax = 0.0
    private var secScoreNoGateMax = 0.0
    private var secFloor = -75.0

    init(frameSec: Double, config: SnoreConfig) {
        self.frameSec = frameSec > 0.005 ? frameSec : 0.085
        self.config = config
    }

    // MARK: 逐帧

    func accept(_ f: SnoreFeature) {
        liveLevel = f.level
        liveFloor = f.floor

        if f.voiced {
            var d: Draft
            if let cur = draft {
                d = cur
            } else {
                d = Draft()
                d.t0 = f.t
                d.t1 = f.t
                d.pk = f.peak
            }
            d.t1 = f.t
            if d.raws.count < Self.draftCap {
                d.raws.append(f.score)
                d.stabs.append(f.stability)
            }
            d.lvSum += f.level
            d.frames += 1
            if f.peak > d.pk { d.pk = f.peak }
            // 基频逐 4 帧取一个就够算中位，别把长声音撑大
            if d.frames % 4 == 1 { d.hz.append(f.peakHz) }
            draft = d
        } else if let d = draft, f.t - d.t1 >= SnoreSound.holdSec {
            closeSound(at: f.t)
        }

        // 实时读数：正在响的这一声此刻像不像鼾（判定仍然等收口，这里只给「像不像」）
        if let d = draft {
            liveSoundDur = d.t1 - d.t0
            liveScore = snoreMedian(d.raws) ?? 0.0
            let stabMed = snoreMedian(d.stabs)
            liveSnoring = liveScore >= config.enterScore
                && (d.stabs.count < 2 || (stabMed ?? 0.0) >= SnoreSound.stabLo)
        } else {
            liveSoundDur = 0
            liveSnoring = false
        }
        if lastSnoreEnd > 0 { liveOpenGapSec = max(0, f.t - lastSnoreEnd) }

        rollSeconds(to: f.t, f: f)
        trimSnoreTimes(floor: f.t - Self.activityWindowSec)
    }

    // MARK: 一声收口 ⇒ 判它是不是鼾

    /// 三样都过关：够一次吸气的段长、频谱够像、帧间稳（不跑共振峰）
    private func shaped(dur: Double, raw: Double, stab: Double) -> Bool {
        return SnoreSound.shapeOf(dur: dur) >= SnoreSound.shapeBar
            && raw >= config.enterScore
            && stab >= SnoreSound.stabLo
    }

    private func closeSound(at t: Double) {
        guard let d = draft else { return }
        draft = nil
        let dur = d.t1 - d.t0
        let raw = snoreMedian(d.raws) ?? 0.0
        let stab = snoreMedian(d.stabs) ?? 0.0
        let okShape = shaped(dur: dur, raw: raw, stab: stab)
        let rec = Closed(t0: d.t0, t1: d.t1, dur: dur, raw: raw, stab: stab, pk: d.pk,
                         mean: d.lvSum / Double(max(1, d.frames)), hz: snoreMedian(d.hz),
                         shapeOk: okShape)
        closed.append(rec)
        soundTotal += 1
        if okShape { soundShaped += 1 }
        let cut = t - SnoreSound.pairWindowSec
        closed = closed.filter { $0.t1 >= cut }

        // 邻鼾：往回找最近的一声，开口间隔要在一次呼吸的量级，而且它自己三样过关
        var partner: Closed?
        for c in closed.dropLast().reversed() {
            let iv = rec.t0 - c.t0
            if iv > SnoreSound.intervalHi { break }
            if iv >= SnoreSound.intervalLo && c.shapeOk {
                partner = c
                break
            }
        }
        let judged: Bool
        if okShape && partner != nil {
            judged = true
        } else if okShape && raw >= config.enterScore + SnoreSound.soloMargin {
            judged = true          // 一晚的头一声：没有邻鼾，只能靠频谱自己过硬
        } else {
            judged = false
            if okShape && partner == nil { soundLonely += 1 }
        }
        rec.snore = judged
        let mark = Mark(t0: rec.t0, t1: rec.t1, snore: judged)
        marks.append(mark)
        if judged {
            soundSnore += 1
            // 配对成功就把邻鼾也认下来：它当时只是「还没伙伴」，被暂记成别的发声了
            if let p = partner, !p.snore { flip(p) }
            addSnoreTime(rec)
            updateRun(rec)
        } else {
            if rec.pk > lastRejectedPeak {
                lastRejectedPeak = rec.pk
                loudestRejected = "最响的一声没判成鼾：\(String(format: "%.2f", rec.pk)) dBFS 峰"
                    + "／段长 \(String(format: "%.2f", rec.dur)) s（形状分 \(String(format: "%.2f", SnoreSound.shapeOf(dur: rec.dur)))）"
                    + "／频谱中位 \(String(format: "%.2f", rec.raw))（判定线 \(String(format: "%.2f", config.enterScore))）"
                    + "／稳定中位 \(String(format: "%.2f", rec.stab))（要 ≥\(String(format: "%.2f", SnoreSound.stabLo))）"
                    + "／邻鼾 \(partner == nil ? "无" : "有")"
            }
            if rec.dur >= 0.4 {
                vocalCount += 1
                emitEvent(kind: .vocal, t0: rec.t0, t1: rec.t1, dur: rec.dur,
                          peakDb: rec.pk, meanDb: rec.mean)
            }
            // 停住的那一阵里有过「别的发声」：只有收口时判成非鼾的声音才算，
            // 逐帧的「有声音」不算——复鼾那一声自己的帧先响起来，那样每条中断都会被自己标上这条。
            if lastSnoreEnd > 0 && t - lastSnoreEnd >= config.interruptGapSec {
                gapOther = true
            }
        }
        account(mark)
    }

    private var lastRejectedPeak = -120.0

    /// 一行「为什么没判成鼾」：这四个数就能分流——
    /// 过关数为 0 ⇒ 频谱/门限那一头（灵敏度、绝对门限、麦克风距离）；
    /// 过关了却全卡在「配不上邻鼾」⇒ 间隔那一档（0.4 那晚真鼾就是这样全灭的）；
    /// 判成鼾却一段发作都没有 ⇒ 发作串不起来（boutGapSec／minBoutSec）。
    var judgeSummary: String {
        return "发声 \(soundTotal) 声｜过关 \(soundShaped)｜判鼾 \(soundSnore)｜配不上邻鼾 \(soundLonely)"
    }

    /// 最响的那一声「不是鼾」的完整数字：整晚一件鼾都没判出来时，日志里靠这一行定位
    var loudestRejectedNote: String { loudestRejected }

    /// 邻鼾改判：把已经发出去的那几秒格子从「别的发声」挪到「鼾」
    private func flip(_ s: Closed) {
        if let i = marks.firstIndex(where: { $0.t0 == s.t0 && $0.t1 == s.t1 }) {
            marks[i].snore = true
        }
        s.snore = true
        soundSnore += 1
        var k = Int(floor(s.t0))
        let hi = Int(floor(s.t1))
        while k <= hi {
            if var b = recent[k] {
                let ov = Self.overlap(t0: s.t0, t1: s.t1, index: k)
                if ov > 0 {
                    b.vocalSec = max(0.0, b.vocalSec - ov)
                    b.snoreSec = min(1.0, b.snoreSec + ov)
                    recent[k] = b
                    onSecondAmend?(b)
                }
            }
            k += 1
        }
        addSnoreTime(s)
    }

    /// 补记：这一声覆盖的、已经发出去的那几秒格子。还没发出去的等它自己发时从 marks 里算，
    /// 所以一格只会把一声算一次。
    private func account(_ m: Mark) {
        let lo = Int(floor(m.t0))
        let hi = Int(floor(m.t1))
        var k = lo
        while k <= hi {
            if var b = recent[k] {
                let ov = Self.overlap(t0: m.t0, t1: m.t1, index: k)
                if ov > 0 {
                    if m.snore {
                        b.snoreSec = min(1.0, b.snoreSec + ov)
                    } else {
                        b.vocalSec = min(1.0, b.vocalSec + ov)
                    }
                    recent[k] = b
                    onSecondAmend?(b)
                }
            }
            k += 1
        }
    }

    private static func overlap(t0: Double, t1: Double, index: Int) -> Double {
        let lo = Double(index)
        return max(0.0, min(t1, lo + 1.0) - max(t0, lo))
    }

    /// 鼾帧的时长记账：判「刚才确实在打」用
    private func addSnoreTime(_ s: Closed) {
        let n = max(1, Int(((s.t1 - s.t0) / frameSec).rounded()))
        var k = 0
        while k < n {
            snoreTimes.append(s.t0 + Double(k) * frameSec)
            k += 1
        }
    }

    // MARK: 发作

    private func updateRun(_ s: Closed) {
        // 停够了才算「一次疑似中断」：起点是上一鼾结束，终点是这一鼾开始
        if lastSnoreEnd > 0 && s.t0 - lastSnoreEnd >= config.interruptGapSec
            && recentSnoreSec() >= Self.activityMinSec {
            emitGap(t0: lastSnoreEnd, t1: s.t0, resumeDb: s.pk, otherDuring: gapOther,
                    unresolved: false)
        }
        if let r = run, s.t0 - r.t1 > config.boutGapSec { closeRun() }
        if run == nil {
            var r = Run(t0: s.t0, t1: s.t1)
            r.n = 1
            r.pk = s.pk
            r.lvSum = s.mean
            r.lvN = 1
            if let hz = s.hz { r.hz.append(hz) }
            run = r
            runOnsets = [s.t0]
        } else if var r = run {
            r.t1 = s.t1
            r.n += 1
            r.pk = max(r.pk, s.pk)
            r.lvSum += s.mean
            r.lvN += 1
            if let hz = s.hz { r.hz.append(hz) }
            run = r
            runOnsets.append(s.t0)
        }
        snoreSecTotal += s.t1 - s.t0
        lastSnoreEnd = s.t1
        gapOther = false
    }

    private func closeRun() {
        guard let r = run else { return }
        run = nil
        var ivs: [Double] = []
        if runOnsets.count >= 2 {
            for i in 1..<runOnsets.count { ivs.append(runOnsets[i] - runOnsets[i - 1]) }
        }
        let mid = snoreMedian(ivs)
        let rate = (mid ?? 0) >= SnoreSound.intervalLo ? 60.0 / (mid ?? 0) : nil
        let dur = max(0, r.t1 - r.t0)
        let mean = r.lvN > 0 ? r.lvSum / Double(r.lvN) : -120.0
        if dur >= config.minBoutSec {
            boutCount += 1
            if dur > longestBout { longestBout = dur }
            lastRunMean = mean
            let e = SnoreEvent(id: nextId, kind: .bout, t0: r.t0, t1: r.t1, dur: dur,
                               peakDb: r.pk, meanDb: mean, ratePerMin: rate,
                               peakHz: snoreMedian(r.hz), preDb: nil, resumeDb: nil,
                               arousal: false, otherDuring: false, unresolved: false)
            nextId += 1
            onEvent?(e)
        }
        runOnsets = []
    }

    // MARK: 疑似中断

    private func emitGap(t0: Double, t1: Double, resumeDb: Double?, otherDuring: Bool,
                         unresolved: Bool) {
        let dur = max(0, t1 - t0)
        guard dur >= config.interruptGapSec else { return }
        // 未复鼾的那一条不进「中断」的账：鼾段结束了、人起床了、停止记录了，都不是呼吸停住。
        // 事件还是要留（【中断明细】里能看到几点结束），只是别把最长和次/小时带跑。
        if !unresolved {
            if dur > longestGap { longestGap = dur }
            gapCount += 1
        }
        let pre = lastRunMean > -119 ? lastRunMean : nil
        let arous = (resumeDb ?? -120.0) > (pre ?? -120.0) + 3.0
        let e = SnoreEvent(id: nextId, kind: .gap, t0: t0, t1: t1, dur: dur,
                           peakDb: resumeDb ?? -120.0, meanDb: -120.0, ratePerMin: nil, peakHz: nil,
                           preDb: pre, resumeDb: resumeDb, arousal: arous,
                           otherDuring: otherDuring, unresolved: unresolved)
        nextId += 1
        onEvent?(e)
        gapOther = false
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

    private func emitEvent(kind: SnoreEventKind, t0: Double, t1: Double, dur: Double,
                           peakDb: Double, meanDb: Double) {
        let e = SnoreEvent(id: nextId, kind: kind, t0: t0, t1: t1, dur: dur, peakDb: peakDb,
                           meanDb: meanDb, ratePerMin: nil, peakHz: nil, preDb: nil,
                           resumeDb: nil, arousal: false, otherDuring: false, unresolved: false)
        nextId += 1
        onEvent?(e)
    }

    // MARK: 逐秒曲线

    private func rollSeconds(to t: Double, f: SnoreFeature) {
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
        if f.score > secScoreMax { secScoreMax = f.score }
        if f.scoreNoGate > secScoreNoGateMax { secScoreNoGateMax = f.scoreNoGate }
        secFloor = f.floor
        // 回填窗口之外的格子丢掉：再晚收口的声音也照不到它们（除非一整段十几秒的长响，
        // 那种判不成鼾，形状分先否了）
        let keep = idx - Int(Self.amendWindowSec)
        if !recent.isEmpty { recent = recent.filter { $0.key >= keep } }
    }

    private func clearSecond() {
        secFrames = 0
        secLevelSum = 0.0
        secLevelMax = -120.0
        secScoreMax = 0.0
        secScoreNoGateMax = 0.0
    }

    private func emitSecond(index: Int, stale: Bool) {
        guard index >= 0 else { return }
        var sn = 0.0
        var vc = 0.0
        for m in marks {
            let ov = Self.overlap(t0: m.t0, t1: m.t1, index: index)
            if ov <= 0 { continue }
            if m.snore { sn += ov } else { vc += ov }
        }
        let b = SnoreSecond(t0: index,
                            maxDb: stale ? -120 : secLevelMax,
                            meanDb: stale ? -120 : (secFrames > 0 ? secLevelSum / Double(secFrames) : -120),
                            snoreSec: min(1.0, sn),
                            vocalSec: min(1.0, vc),
                            maxScore: secScoreMax,
                            floorDb: secFloor,
                            stale: stale,
                            maxScoreNoGate: secScoreNoGateMax)
        // 整段都在这一格以前的，后面再没有格子会叠到它，扔了
        marks = marks.filter { $0.t1 > Double(index + 1) }
        recent[index] = b
        clearSecond()
        onSecond?(b)
    }

    // MARK: 收尾

    /// 会话收尾：结掉还在响的那一声／还挂着的发作／最后那一格秒，够长的未复鼾中断也留一条。
    func finish(at t: Double) {
        if draft != nil {
            closeSound(at: t)
        }
        if run != nil { closeRun() }
        if secFrames > 0 {
            emitSecond(index: secIdx, stale: false)
            secFrames = 0
        }
        if lastSnoreEnd > 0 && (t - lastSnoreEnd) >= 30.0 {
            emitGap(t0: lastSnoreEnd, t1: t, resumeDb: nil, otherDuring: gapOther, unresolved: true)
        }
        liveOpenGapSec = 0
        liveSnoring = false
    }
}
