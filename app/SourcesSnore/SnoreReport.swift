import Foundation

// MARK: - 一晚的账汇总成一份能给医生看的报告
//
// 只从「逐秒曲线 + 事件表」这两样重算，不另存中间态：这样报告永远和盘上的原始数据对得上，
// 哪怕 App 半夜被系统杀掉、只写到最后一格，重启后读到的也是那之前的真实数字。

struct SnoreSummary {
    var totalSec: Double = 0
    var snoreSec: Double = 0
    var coverage: Double = 0            // snoreSec / totalSec
    var boutCount: Int = 0
    var boutsPerHour: Double = 0
    var longestBout: Double = 0
    var meanBout: Double = 0
    var ratePerMin: Double?             // 发作内节律的中位（次/分）
    var gapCount: Int = 0
    var gapsPerHour: Double = 0
    var longestGap: Double = 0
    var meanGap: Double = 0
    var arousalCount: Int = 0           // 复鼾明显比中断前响的那几次
    var unresolvedCount: Int = 0        // 到收尾都没复鼾的（不等同于中断）
    var vocalCount: Int = 0
    var peakDb: Double = -120
    var snoreMeanDb: Double = -120
    var floorMedianDb: Double = -120
    var staleSec: Int = 0               // 没数据的秒（引擎断过、被系统暂停过）
    var grade: String = "—"

    /// 界面上那两格的字：拿不到节律的时候说人话，别显示「nil」或「0 次/分」。
    var rateText: String {
        guard let r = ratePerMin else { return "鼾太密，数不清" }
        return String(format: "%.1f 次/分", r)
    }

    var coverageText: String { String(format: "%.1f%%", coverage * 100) }
    var boutsText: String { "\(boutCount) 次（\(String(format: "%.1f", boutsPerHour)) 每时）" }
    var gapsText: String { "\(gapCount) 次（\(String(format: "%.1f", gapsPerHour)) 每时）" }
}

enum SnoreAnalyze {
    static func summarize(buckets: [SnoreSecond], events: [SnoreEvent], config: SnoreConfig) -> SnoreSummary {
        let bouts = events.filter { $0.kind == .bout }
        let gaps = events.filter { $0.kind == .gap }
        let vocals = events.filter { $0.kind == .vocal }
        var s = SnoreSummary()
        s.totalSec = Double(buckets.count)
        var snoreSec = 0.0
        var levels: [Double] = []
        var floors: [Double] = []
        var peak = -120.0
        var stale = 0
        for b in buckets {
            if b.stale { stale += 1; continue }
            snoreSec += b.snoreSec
            levels.append(b.maxDb)
            if b.floorDb > -119 { floors.append(b.floorDb) }
            if b.maxDb > peak { peak = b.maxDb }
        }
        s.staleSec = stale
        s.snoreSec = snoreSec
        s.coverage = s.totalSec > 60 ? snoreSec / max(1.0, Double(buckets.count - stale)) : 0
        s.peakDb = peak
        s.floorMedianDb = snorePercentile(floors, 0.5) ?? -120
        s.grade = gradeText(s.coverage)

        // 鼾声期间的响度：只取那些确有鼾的秒，本底和翻身不该拉低这个数
        let snoreLevels = buckets.filter { !$0.stale && $0.snoreSec > 0.3 }.map { $0.maxDb }
        s.snoreMeanDb = snoreLevels.isEmpty ? -120 : snoreMean(snoreLevels)

        s.boutCount = bouts.count
        s.gapCount = gaps.count
        s.vocalCount = vocals.count
        let hours = max(0.01, s.totalSec / 3600.0)
        s.boutsPerHour = Double(bouts.count) / hours
        s.gapsPerHour = Double(gaps.count) / hours
        if !bouts.isEmpty {
            let durs = bouts.map { $0.dur }
            s.longestBout = durs.max() ?? 0
            s.meanBout = snoreMean(durs)
            let rates = bouts.compactMap { $0.ratePerMin }
            s.ratePerMin = snoreMedian(rates)
        }
        if !gaps.isEmpty {
            let durs = gaps.map { $0.dur }
            s.longestGap = durs.max() ?? 0
            s.meanGap = snoreMean(durs)
            s.arousalCount = gaps.filter { $0.arousal }.count
            s.unresolvedCount = gaps.filter { $0.unresolved }.count
        }
        return s
    }

    /// 鼾声占比分级。口径按「一晚里有多少时间在打」，不是医学标准，界面上写明了是参考。
    static func gradeText(_ coverage: Double) -> String {
        if coverage < 0.005 { return "几乎没鼾" }
        if coverage < 0.10 { return "轻微" }
        if coverage < 0.30 { return "轻—中度" }
        if coverage < 0.50 { return "中度" }
        return "重度"
    }

    /// 逐小时格子：按墙上时钟的小时归桶（跨零点也接得上），给报告里那一行「逐小时」和柱状图用。
    ///
    /// 一晚上 28 800 格，别每格都调 Calendar（那是几百次 dateComponents 的量级）：
    /// 只在开头问一次「会话起点落在这一小时的第几秒」，后面纯加法。国内没有夏令时，
    /// 真跨了调令的那一晚最坏是把一格归到相邻小时里，不影响总时长。
    static func hourly(buckets: [SnoreSecond], start: Date) -> [(hourDate: Date, coverage: Double, seconds: Double)] {
        var out: [(Date, Double, Double)] = []
        guard !buckets.isEmpty else { return out }
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: start)
        let hourStart = cal.date(from: comps) ?? start
        let intoHour = start.timeIntervalSince(hourStart)
        var slot = -1
        var snore = 0.0
        var total = 0.0
        var slotDate = start
        for b in buckets {
            let s = Int((Double(b.t0) + intoHour) / 3600.0)
            if s != slot {
                if slot >= 0 { out.append((slotDate, total > 0 ? snore / total : 0, total)) }
                slot = s
                snore = 0
                total = 0
                slotDate = start.addingTimeInterval(Double(s) * 3600.0 - intoHour)
            }
            if !b.stale {
                total += 1
                snore += b.snoreSec
            }
        }
        out.append((slotDate, total > 0 ? snore / total : 0, total))
        return out
    }

    /// 报告的正文。一行一句，界面上直接摆、发给电脑也是这一份。
    static func reportText(summary s: SnoreSummary, start: Date, end: Date, events: [SnoreEvent],
                           buckets: [SnoreSecond], config: SnoreConfig, facts: [String],
                           title: String) -> String {
        var lines: [String] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("====== \(title) ======")
        lines.append("时段     \(df.string(from: start)) → \(df.string(from: end))（\(snoreDurText(s.totalSec))）")
        lines.append("")
        lines.append("【鼾声占比】\(String(format: "%.1f", s.coverage * 100))%（\(snoreDurText(s.snoreSec))）→ \(s.grade)")
        lines.append("【发作次数】\(s.boutCount) 次，每小时 \(String(format: "%.1f", s.boutsPerHour)) 次；"
                     + "最长一次 \(snoreDurText(s.longestBout))，平均 \(snoreDurText(s.meanBout))")
        if let r = s.ratePerMin {
            lines.append("【鼾声节律】发作内 \(String(format: "%.1f", r)) 次/分（约每 \(String(format: "%.1f", 60.0 / r)) 秒一鼾）")
        } else {
            lines.append("【鼾声节律】没数出稳定的鼾间隔（发作太短或鼾太密，间隔不足 1 s）")
        }
        lines.append("【响度】峰值 \(SnoreCalib.text(s.peakDb, config))｜鼾声期均值 \(SnoreCalib.text(s.snoreMeanDb, config))"
                     + "｜本底中位 \(SnoreCalib.text(s.floorMedianDb, config))")
        lines.append("")
        lines.append("【疑似中断】≥\(Int(config.interruptGapSec)) s 的鼾声停住：\(s.gapCount) 次，"
                     + "每小时 \(String(format: "%.1f", s.gapsPerHour)) 次")
        lines.append("　　　　　最长 \(snoreDurText(s.longestGap))，平均 \(snoreDurText(s.meanGap))；"
                     + "其中 \(s.arousalCount) 次以明显更响的复鼾结束，\(s.unresolvedCount) 次停住后再没复鼾")
        lines.append("【其他发声】说话/咳嗽样 \(s.vocalCount) 次")
        lines.append("【看一眼】\(advice(s, config))")
        if s.staleSec > 0 {
            lines.append("【数据缺口】有 \(snoreDurText(Double(s.staleSec))) 没采到（引擎断过或手机被暂停），统计按采到的部分算")
        }

        let hour = hourly(buckets: buckets, start: start)
        if hour.count > 1 {
            var row = "【逐小时】"
            for (date, cov, _) in hour {
                let h = DateFormatter()
                h.dateFormat = "HH"
                row += " \(h.string(from: date))时\(Int((cov * 100).rounded()))%"
            }
            lines.append(row)
        }

        // 最要紧的几条中断单独列出来：医生问「最长那次几点」的时候要能马上答
        let shown = events.filter { $0.kind == .gap }.sorted { $0.dur > $1.dur }.prefix(8)
        if !shown.isEmpty {
            lines.append("")
            lines.append("【中断明细】（按停住的时长从长到短，最多 8 条）")
            for e in shown {
                let d = start.addingTimeInterval(e.t0)
                let f2 = DateFormatter()
                f2.dateFormat = "HH:mm:ss"
                var tail = e.unresolved ? "未复鼾" : "复鼾 \(SnoreCalib.text(e.resumeDb ?? -120, config))"
                if e.arousal { tail += "（比停住前响）" }
                if e.otherDuring { tail += "｜期间有别的发声" }
                lines.append("  \(f2.string(from: d))  停 \(snoreDurText(e.dur))  \(tail)")
            }
        }

        lines.append("")
        lines.append("【口径与限度】")
        lines.append("  · 只有麦克风：测不到气流、胸腹运动和血氧，所以「疑似中断」是鼾声停住的间接推断，"
                     + "不等于呼吸暂停，更不能当诊断。")
        lines.append("  · 响度是手机麦克风的相对刻度 dBFS；不接声级计换算就不是 dB(A) SPL，"
                     + "跨设备比较要留意。")
        lines.append("  · 判鼾要过两关：声音的频谱形状，加上「一开一合」跟着呼吸的节律（一鼾 0.4–0.8 s、"
                     + "间隔 1–6 s）。数不出节律的持续声（嗡鸣、说话）不算鼾；反过来说，极轻或隔着被子的鼾可能整段漏判。")
        lines.append("  · 距离、枕头、体位、同床者翻身都会改变读数；本 App 统计的是「采到的声音」，不是「你打得多厉害」的绝对量。")
        lines.append("  · 真要看有没有睡眠呼吸暂停，去做多导睡眠监测（PSG）或医生开的便携睡眠呼吸监测。")
        if !facts.isEmpty {
            lines.append("")
            lines.append("【运行环境】")
            for f in facts { lines.append("  " + f) }
        }
        return lines.joined(separator: "\n")
    }

    /// 一句「接下来做什么」。界面上顶在第一行，报告里跟着【看一眼】。
    /// 阈值挑的是筛查里常用的那几条口径的影子（次数/小时、占比、复鼾是否更响），
    /// 但只凭音频绝不写「你有睡眠呼吸暂停」这种话。
    static func advice(_ s: SnoreSummary, _ config: SnoreConfig) -> String {
        let gapHot = s.gapsPerHour >= 5.0 || (s.gapsPerHour >= 3.0 && s.arousalCount >= 2)
        if gapHot && s.coverage >= 0.10 {
            return "鼾声停住 \(String(format: "%.1f", s.gapsPerHour)) 次/小时、最长 \(snoreDurText(s.longestGap))，"
                + "这个密度值得去睡眠门诊或呼吸科做一次正规睡眠监测；把这份报告和音频片段一起带上。"
        }
        if gapHot {
            return "鼾声停住 \(String(format: "%.1f", s.gapsPerHour)) 次/小时，但鼾声本身不多——"
                + "先确认手机放得离嘴够近（30–60 cm）、没被枕头压住，再连记几晚。"
        }
        if s.coverage >= 0.30 {
            return "鼾声占了 \(String(format: "%.0f", s.coverage * 100))% 的时间（\(s.grade)），"
                + "停住不算频繁；这类以鼾声为主，管体重、侧睡、睡前别喝酒先看两周趋势。"
        }
        if s.coverage < 0.005 && s.gapCount == 0 {
            return "这一晚几乎没采到鼾声。要么确实没打，要么手机离得太远/被压住/麦克风权限没给。"
        }
        return "鼾声和停住都不算突出。建议连着记 3–5 晚看趋势，单晚的数字别当结论。"
    }
}

// MARK: - 校准换算

enum SnoreCalib {
    /// 界面上那一条响度：没填校准偏移就是 dBFS 本身；填了就同时给一个「校准后」的数。
    /// 填了声级计对照值也不等于 dB(A)——手机麦克风是全频带平坦响应，没有 A 计权。
    static func text(_ db: Double, _ config: SnoreConfig) -> String {
        if db <= -119 { return "无数据" }
        if abs(config.calOffsetDb) < 0.05 { return String(format: "%.1f dBFS", db) }
        return String(format: "%.1f dBFS ≈ %.1f dB（＋校准 %.0f）", db, db + config.calOffsetDb, config.calOffsetDb)
    }
}
