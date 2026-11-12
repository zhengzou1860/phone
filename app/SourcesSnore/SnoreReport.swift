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
    var blindCells: Int = 0             // 「频谱过了盲区线、可整秒一帧都没过响度门」的秒格数（已剔除连续背景声）
    var blindSuppressed: Int = 0        // 被当成连续背景声（机器/稳态噪声）剔除的盲区候选秒数
    var staleSec: Int = 0               // 没数据的秒（引擎断过、被系统暂停过）
    var grade: String = "—"
    var tooShort = false                // 不足 1 分钟的场次：占比和分级不给（试录半分钟不该被判成「中度鼾」，
                                        // 更不该反过来被读成「没检测到鼾声」）

    /// 界面上那两格的字：拿不到节律的时候说人话，别显示「nil」或「0 次/分」。
    var rateText: String {
        guard let r = ratePerMin else { return "鼾太密，数不清" }
        return String(format: "%.1f 次/分", r)
    }

    var coverageText: String { tooShort ? "太短，不分级" : String(format: "%.1f%%", coverage * 100) }
    var boutsText: String { "\(boutCount) 次（\(String(format: "%.1f", boutsPerHour)) 每时）" }
    var gapsText: String { "\(gapCount) 次（\(String(format: "%.1f", gapsPerHour)) 每时）" }

    /// 停住密度到了「值得当回事」那一档。报告开头那句定性和【建议】共用这一条：
    /// 两处各写一遍阈值，11-07 那晚就写分裂过——开头说「建议去医院」，建议栏说「先确认手机放得够近」。
    var gapHot: Bool { gapsPerHour >= 5.0 || (gapsPerHour >= 3.0 && arousalCount >= 2) }
}

enum SnoreAnalyze {
    /// 盲区线：门以下那些秒要「频谱分至少这么高」才被数成「可能有轻鼾被门挡住了」。
    ///
    /// 这条线不能就用判定线 0.60。频谱那几项全是比例，跟响度无关，门以下少了 sLevel 那一票照样能凑分：
    /// 合成床噪（本底 −84 dBFS）115 个秒格的格子最大分是 p50 0.65／p90 0.69／天花板 0.72，
    /// 而比 −58 轻 8 dB 的合成鼾是 p10 0.79／中位 1.00。0.75 是这两堆中间那条缝，
    /// 不是拍脑袋——CI 用例⑫两头都钉着（轻鼾抓到 ≥60%、纯本底误报 ≤10%）。
    static let blindBar = 0.75

    /// 连续背景声（机器运转、房间稳态噪声）会把【轻鼾盲区】撑得虚高：它频谱像鼾、又一直压在门以下，
    /// 于是一整晚几千秒全被数成「可能有轻鼾被挡住」。11-09 那晚 26 885 s（7 h 30 min）连成一片不断，
    /// 人不可能一口气打这么久 ⇒ 是连续声源，不是轻鼾。真人打鼾是一口气一口气的，响度有起伏；机器声是平的。
    /// 两条合起来才屏蔽（单用任一条都验过不行：段长单用会误伤合成轻鼾，起伏单用剩太多）：
    ///   连着 >blindRunLen 秒都是盲区候选，且这段前后 ±blindWinSec 秒的响度起伏（p90−p10）<blindFlatDb。
    /// 又长又平才是机器。合成轻鼾虽也连着 38 s，但起伏 22 dB ⇒ 保住；持续单音起伏 0.03 dB ⇒ 屏蔽。
    /// 只动报告这一侧的计数，判定路径、absGateDb、六项打分权重一个字没改；meanDb 早已落在 curve 里，老晚上也能重算。
    static let blindRunLen = 20         // 连续候选秒超过这个长度才考虑屏蔽
    static let blindFlatDb = 10.0       // 局部响度起伏（p90−p10）低于这个值才算「平」
    static let blindWinSec = 10         // 起伏窗口：前后各 10 s

    /// 门以下「频谱像鼾」的候选秒，剔除连续背景声（机器/稳态噪声）后还剩几秒。这个数就是 blindCells。
    static func blindSeconds(_ buckets: [SnoreSecond]) -> Int {
        let live = buckets.filter { !$0.stale }
        let n = live.count
        guard n > 0 else { return 0 }
        let cand = live.map {
            $0.maxScore == 0 && $0.snoreSec == 0 && $0.vocalSec == 0 && $0.maxScoreNoGate >= SnoreAnalyze.blindBar
        }
        // 段长：t0 相邻的连续候选游程（stale 已剔掉，数据断口处 t0 跳号 ⇒ 自然断开）
        var runLen = [Int](repeating: 0, count: n)
        var i = 0
        while i < n {
            if !cand[i] { i += 1; continue }
            var j = i
            while j + 1 < n && cand[j + 1] && live[j + 1].t0 == live[j].t0 + 1 { j += 1 }
            let len = j - i + 1
            for k in i...j { runLen[k] = len }
            i = j + 1
        }
        var kept = 0
        for k in 0..<n {
            if !cand[k] { continue }
            if runLen[k] > blindRunLen {
                let a = max(0, k - blindWinSec)
                let b = min(n, k + blindWinSec + 1)
                let win = live[a..<b].map { $0.meanDb }
                let spread = (snorePercentile(win, 0.9) ?? 0) - (snorePercentile(win, 0.1) ?? 0)
                if spread < blindFlatDb { continue }   // 又长又平 ⇒ 机器/稳态噪声，不当轻鼾
            }
            kept += 1
        }
        return kept
    }

    static func summarize(buckets: [SnoreSecond], events: [SnoreEvent], config: SnoreConfig) -> SnoreSummary {
        let bouts = events.filter { $0.kind == .bout }
        let gaps = events.filter { $0.kind == .gap }
        let vocals = events.filter { $0.kind == .vocal }
        var s = SnoreSummary()
        s.totalSec = Double(buckets.count)
        var snoreSec = 0.0
        var floors: [Double] = []
        var peak = -120.0
        var stale = 0
        var blindRaw = 0               // 门以下「频谱过盲区线」的候选秒数（屏蔽前）
        for b in buckets {
            if b.stale { stale += 1; continue }
            snoreSec += b.snoreSec
            if b.floorDb > -119 { floors.append(b.floorDb) }
            if b.maxDb > peak { peak = b.maxDb }
            // 「整秒没一帧过门」看 maxScore 是不是 0：0.8 起 score 只在过门的帧上算，所以 0 就是
            // 「这一秒连一次都没够着门」；配上 maxScoreNoGate 才知道这一秒的频谱到底像不像鼾。
            if b.maxScore == 0 && b.snoreSec == 0 && b.vocalSec == 0 && b.maxScoreNoGate >= SnoreAnalyze.blindBar {
                blindRaw += 1
            }
        }
        let blind = blindSeconds(buckets)   // 剔除连续背景声（机器/稳态噪声）后剩下的轻鼾候选
        s.blindCells = blind
        s.blindSuppressed = blindRaw - blind
        s.staleSec = stale
        s.snoreSec = snoreSec
        s.tooShort = s.totalSec <= 60
        s.coverage = s.tooShort ? 0 : snoreSec / max(1.0, Double(buckets.count - stale))
        s.peakDb = peak
        s.floorMedianDb = snorePercentile(floors, 0.5) ?? -120
        s.grade = s.tooShort ? "" : gradeText(s.coverage)

        // 鼾声期间的响度：只取那些确有鼾的秒，本底和翻身不该拉低这个数
        let snoreLevels = buckets.filter { !$0.stale && $0.snoreSec > 0.3 }.map { $0.maxDb }
        s.snoreMeanDb = snoreLevels.isEmpty ? -120 : snoreMean(snoreLevels)

        s.boutCount = bouts.count
        // 「停住到收尾都没复鼾」的那一条不进【疑似中断】的计数：那是鼾自己停了（不打了、或停止记录），
        // 不是呼吸停住。0.6 那晚就有一条 14 min 33 s 的挂在中断统计里，把最长和次/小时都带跑。
        let gapsOn = gaps.filter { !$0.unresolved }
        s.gapCount = gapsOn.count
        s.unresolvedCount = gaps.count - gapsOn.count
        s.vocalCount = vocals.count
        let hours = max(0.01, s.totalSec / 3600.0)
        s.boutsPerHour = Double(bouts.count) / hours
        s.gapsPerHour = Double(gapsOn.count) / hours
        if !bouts.isEmpty {
            let durs = bouts.map { $0.dur }
            s.longestBout = durs.max() ?? 0
            s.meanBout = snoreMean(durs)
            let rates = bouts.compactMap { $0.ratePerMin }
            s.ratePerMin = snoreMedian(rates)
        }
        if !gapsOn.isEmpty {
            let durs = gapsOn.map { $0.dur }
            s.longestGap = durs.max() ?? 0
            s.meanGap = snoreMean(durs)
            s.arousalCount = gapsOn.filter { $0.arousal }.count
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
    static func hourly(buckets: [SnoreSecond], start: Date) -> [(hourDate: Date, coverage: Double, snoreSeconds: Double)] {
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
                if slot >= 0 { out.append((slotDate, total > 0 ? snore / total : 0, snore)) }
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
        out.append((slotDate, total > 0 ? snore / total : 0, snore))
        return out
    }

    /// 报告正文：写给刚睡醒的人看的，几行大白话。界面上直接摆、发给电脑也是这一份。
    ///
    /// 术语一律不进这里（dBFS、频谱分、盲区线、判定口径那六条）：0.10 以前这份报告摆了一屏，
    /// 用户原话是「太复杂，看不懂」。要重算的数字在 curve.csv 和 events.jsonl 里，程序跑成什么样在执行日志里，
    /// 电脑上自取，不必让睡醒的人先读一遍算法说明。
    static func reportText(summary s: SnoreSummary, start: Date, end: Date, events: [SnoreEvent],
                           buckets: [SnoreSecond], config: SnoreConfig, title: String) -> String {
        let hours = topHours(buckets, start: start)
        var lines: [String] = []
        lines.append("====== \(title) ======")
        lines.append("\(snoreDayText(start)) → \(snoreDayText(end))，一共记了 \(snoreDurCN(s.totalSec))")
        lines.append("")
        lines.append("【一句话】" + headline(s, hours: hours))
        lines.append("")
        if s.tooShort {
            lines.append("只记了 \(snoreDurCN(s.totalSec))（不到 1 分钟）：听到鼾 \(snoreDurCN(s.snoreSec))、分成 \(s.boutCount) 段。"
                         + "别把这一场读成「没打鼾」，占比和分级要录满 1 分钟才给。")
        } else {
            lines.append("打鼾多久：\(snoreDurCN(s.snoreSec))，\(coverageCN(s))（\(s.grade)）")
            lines.append("分几段：\(s.boutCount) 段，最长一段 \(snoreDurCN(s.longestBout))，平均 \(snoreDurCN(s.meanBout))")
            lines.append("什么时候打的：" + whenDetail(hours))
            if let loud = loudnessText(s) { lines.append("响不响：" + loud) }
            if let r = s.ratePerMin, r > 0 {
                lines.append("打鼾节奏：大约每 \(String(format: "%.0f", 60.0 / r)) 秒一声")
            }
        }
        lines.append("鼾声停住（打鼾中间安静满 \(Int(config.interruptGapSec)) 秒记一次）：\(s.gapCount) 次"
                     + (s.gapCount > 0 ? "，平均每小时 \(String(format: "%.1f", s.gapsPerHour)) 次，最长一次 \(snoreDurCN(s.longestGap))" : ""))
        if s.gapCount > 0 {
            let worst = events.filter { $0.kind == .gap && !$0.unresolved }
                .sorted { $0.dur > $1.dur }.prefix(3)
            if !worst.isEmpty {
                let f = DateFormatter()
                f.dateFormat = "HH:mm"
                lines.append("安静最久的几次：" + worst.map {
                    "\(f.string(from: start.addingTimeInterval($0.t0))) 安静 \(snoreDurCN($0.dur))"
                }.joined(separator: "、"))
            }
            if s.arousalCount > 0 {
                lines.append("其中 \(s.arousalCount) 次是停完之后猛地又打起来，比停之前还响")
            }
        }
        if s.unresolvedCount > 0 {
            // 措辞别写成「起床」：用户是整晚睡到醒的，0.6 那晚那句「多半是鼾段结束或起床」直接把人的记录带偏了。
            // 这里唯一站得住的说法是「鼾自己停了，一直到记录结束都没再出现」，为什么停交给手表/人来对，不在这里猜。
            lines.append("另外有 \(s.unresolvedCount) 次是鼾声自己停了，一直到记录结束都没再出现（不算进上面的停住次数）")
        }
        lines.append("别的动静：\(s.vocalCount) 次（不是鼾的声音，像翻身、说话、咳嗽，分不清具体是哪种）")
        if !s.tooShort && s.blindCells >= 60 {
            lines.append("很轻的声音：另有约 \(snoreDurCN(Double(s.blindCells)))的动静听着有点像鼾，但太轻，没算进上面的数"
                         + "（可能是极轻的鼾，也可能是风扇、电脑这类一直响的声音）")
        }
        if s.staleSec > 0 {
            lines.append("没录到的部分：有 \(snoreDurCN(Double(s.staleSec))) 没采到（程序断过或手机被暂停），上面的数只按录到的部分算")
        }
        lines.append("")
        lines.append("【建议】" + advice(s))
        lines.append("【怎么算的】一声一声听：像鼾、长短像一口气里的鼾、又能跟上一声配成「一鼾一口气」才算。"
                     + "空调、风扇这类一直响的声音不算鼾；隔着被子、离得远的极轻鼾会漏。")
        lines.append("【说明】「鼾声停住」量的是鼾声安静了多久，不是呼吸停了多久——几分钟那种多半是这一整段都没打鼾。"
                     + "手机只能听声音，测不到呼吸和血氧，所以这只是听出来的推断，不等于呼吸暂停，不能当诊断。"
                     + "响度是跟房间底噪比的相对值，不是医院用的分贝数；手机离得远近、枕头、体位都会改变读数。"
                     + "真要查有没有睡眠呼吸暂停，去医院做睡眠监测。")
        return lines.joined(separator: "\n")
    }

    /// 哪几个小时打得最多：按鼾声秒数从多到少，最多摆 3 个。「一句话」和「什么时候打的」共用这一份。
    private static func topHours(_ buckets: [SnoreSecond], start: Date) -> [(date: Date, sec: Double)] {
        hourly(buckets: buckets, start: start)
            .filter { $0.snoreSeconds >= 0.5 }
            .sorted { $0.snoreSeconds > $1.snoreSeconds }
            .prefix(3)
            .map { (date: $0.hourDate, sec: $0.snoreSeconds) }
    }

    /// 「凌晨 2 点」「早上 6 点」：跨零点的记录光写「2 点」看不出是凌晨还是下午。
    private static func hourCN(_ date: Date) -> String {
        let h = Calendar.current.component(.hour, from: date)
        switch h {
        case 0: return "半夜 12 点"
        case 1...5: return "凌晨 \(h) 点"
        case 6...11: return "早上 \(h) 点"
        case 12: return "中午 12 点"
        case 13...18: return "下午 \(h - 12) 点"
        default: return "晚上 \(h - 12) 点"
        }
    }

    private static func whenDetail(_ hours: [(date: Date, sec: Double)]) -> String {
        guard !hours.isEmpty else { return "整晚都没听到鼾" }
        let most = hours.map { "\(hourCN($0.date))（\(snoreDurCN($0.sec))）" }.joined(separator: "、")
        return hours.count == 1 ? "\(most)；别的时候没听到" : "最多的是 \(most)"
    }

    /// 开头那一句：打了多少、集中在几点、有没有停住，最后一句给个定性。
    /// 这里只给次数和每小时几次，不摆「最长一次」——最长那一次往往是十几分钟没打鼾，
    /// 摆在开头会被读成「憋了十几分钟」。时长留在下面那行，配着【说明】一起看。
    private static func headline(_ s: SnoreSummary, hours: [(date: Date, sec: Double)]) -> String {
        if s.tooShort { return "这一场太短，说明不了整晚的情况。" }
        let amount = s.snoreSec < 1
            ? "\(whenCN(s))几乎没打鼾"
            : "\(whenCN(s))打鼾 \(snoreDurCN(s.snoreSec))（\(coverageCN(s))）"
        let when = s.snoreSec < 1 ? "" : "，\(whenPhrase(hours))"
        let gap = s.gapCount == 0
            ? "，没有鼾声停住"
            : "，有 \(s.gapCount) 次鼾声停住（平均每小时 \(String(format: "%.1f", s.gapsPerHour)) 次）"
        return amount + when + gap + "。" + verdict(s)
    }

    private static func whenPhrase(_ hours: [(date: Date, sec: Double)]) -> String {
        guard let first = hours.first else { return "整晚都没听到" }
        if hours.count == 1 { return "都在\(hourCN(first.date))前后" }
        return "主要在" + hours.map { hourCN($0.date) }.joined(separator: "、")
    }

    /// 定性那一句。阈值跟 advice 用的是同一条（gapHot），别出现「一句话」说去医院、「建议」说先挪手机的分裂。
    private static func verdict(_ s: SnoreSummary) -> String {
        if s.gapHot && s.coverage >= 0.10 { return "停住的次数偏多，建议去医院做一次睡眠监测。" }
        if s.gapHot { return "停住的次数偏多，但鼾声本身不多，先确认手机放得够近。" }
        if s.coverage >= 0.30 { return "打得比较多，值得留意。" }
        if s.coverage >= 0.10 { return "打得有些多。" }
        if s.gapCount > 0 { return "鼾声不多，但有停住，连记几晚看看。" }
        if s.coverage < 0.005 { return "睡得挺安静。" }
        return "鼾声不算多。"
    }

    /// 「整晚」还是「录到的这段时间」：分母本来就是录到的时长，下午随手试的十几分钟写成
    /// 「占整晚 17.7%」是误导（CI 合成样例那 15 分钟就是这样）。够不上一晚就别叫一晚。
    private static func spanCN(_ s: SnoreSummary) -> String {
        s.totalSec >= 3 * 3600 ? "占整晚" : "占录到的这段时间"
    }

    /// 「昨晚」还是「这一场」，同上。
    private static func whenCN(_ s: SnoreSummary) -> String {
        s.totalSec >= 3 * 3600 ? "昨晚" : "这一场"
    }

    /// 占比那一格：不到 0.05% 就写「不到 0.1%」。「打了 4 秒（占整晚 0.0%）」读着像自相矛盾，
    /// 而那一晚（11-10）确实判到了 4 秒鼾，不是零。
    private static func coverageCN(_ s: SnoreSummary) -> String {
        let pct = s.coverage * 100
        if pct < 0.05 { return "\(spanCN(s))不到 0.1%" }
        return "\(spanCN(s)) \(String(format: "%.1f%%", pct))"
    }

    /// 「响不响」：拿鼾声期均值跟这一晚的房间底噪比，只给差值、不下「响/轻」的断语。
    /// dBFS 本身跨手机不可比；而门 = max(本底+4, −58)，房间一安静，任何判成鼾的声音都高出本底 25 dB 以上，
    /// 按差值分档会把每一晚都写成「比较响」。差值本身能连着几晚比趋势，够了。
    private static func loudnessText(_ s: SnoreSummary) -> String? {
        guard s.snoreMeanDb > -119, s.floorMedianDb > -119 else { return nil }
        let d = s.snoreMeanDb - s.floorMedianDb
        guard d > 0 else { return nil }
        return "打鼾时平均比房间底噪高 \(Int(d.rounded())) 分贝"
    }

    /// 一句「接下来做什么」。历史那一晚的详情页和报告里的【建议】都用它。
    /// 阈值挑的是筛查里常用口径的影子（停住次数/小时、鼾声占比、复鼾是否更响），
    /// 但只凭音频绝不写「你有睡眠呼吸暂停」这种话。
    static func advice(_ s: SnoreSummary) -> String {
        if s.tooShort {
            // 试录半分钟就收尾：占比那一格本来就是空的，走到底下会写成「几乎没采到鼾声」——
            // 于是「判出来 8 声鼾、2 段发作」的一场测试也被写成「没检测到鼾」。时长上面已经给过，这里只说下一步。
            if s.boutCount == 0 && s.snoreSec < 0.5 {
                return "手机离嘴 30–60 厘米、连着记满 1 分钟再看，这一场说明不了有没有鼾。"
            }
            return "判定在起作用。手机离嘴 30–60 厘米、连着记一整晚，才看得出趋势。"
        }
        if s.gapHot && s.coverage >= 0.10 {
            return "鼾声停住平均每小时 \(String(format: "%.1f", s.gapsPerHour)) 次、最长 \(snoreDurCN(s.longestGap))，"
                + "这个次数值得去睡眠门诊或呼吸科做一次正规睡眠监测，把这份报告带上。"
        }
        if s.gapHot {
            return "鼾声停住平均每小时 \(String(format: "%.1f", s.gapsPerHour)) 次，但鼾声本身不多——"
                + "先确认手机离嘴够近（30–60 厘米）、没被枕头压住，再连记几晚。"
        }
        if s.coverage >= 0.30 {
            return "鼾声占了整晚 \(String(format: "%.0f", s.coverage * 100))% 的时间（\(s.grade)），停住不算频繁："
                + "这类以鼾声为主，先管体重、侧着睡、睡前别喝酒，看两周趋势。"
        }
        if s.coverage < 0.005 && s.gapCount == 0 {
            // 别在这里质疑麦克风权限：这一晚判到了鼾、也记了别的动静，权限显然是给了的。
            // 开头说「睡得挺安静」，这里再说「可能没给权限」就自相矛盾了。
            return "\(whenCN(s))几乎没听到鼾声，先按「睡得安静」读。要是你或伴侣觉得其实打了，"
                + "把手机挪到离嘴 30–60 厘米、别被枕头压住，再连记几晚对一对。"
        }
        return "鼾声和停住都不算突出。连着记 3–5 晚看趋势，单晚的数字别当结论。"
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
