import Foundation

// MARK: - 出包前的算法闸门（在 CI 那台 mac 上跑，不是手机上跑）
//
// 本机是 Windows，没有 Swift 工具链；判定这一整套（FFT → 逐帧特征 → 「一次发声」收口判定 → 事件表）
// 从来没被真编译器跑过，更没被验过数。所以出包前在 mac 上拿合成信号跑一遍真通路：
// 判据不看「听着像不像」，看事件表里的数字落在不在该在的区间。
// 手机上「设置 → 算法自检」跑的是同一份 SnoreCases.all，两边不可能各说一套。

let config = SnoreConfig()
let t0 = DispatchTime.now().uptimeNanoseconds
let results = SnoreCases.all(config: config)
let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0

var bad = 0
for r in results {
    if !r.ok { bad += 1 }
    print("CASE \(r.ok ? "OK  " : "FAIL") \(r.name)｜\(r.detail)")
}
let badCases = bad     // 这批用例的；合成夜那几条另加，别把「10/11」这种数字打错

// 把一份完整报告打进 CI 日志：文案（口径、限度、分级那几行）改错了，这里当场就能看见，
// 不必等第二天早上在手机上调出来。起点钉死，日志才可重复比对。
do {
    let sr = SnoreCases.rate
    /// 把一小段信号叠进整晚的底子里（合成鼾是一段一段的，不是从某点开始一直响到底）
    func lay(_ piece: [Double], into target: inout [Double], at sec: Double) {
        let i0 = Int(sec * sr)
        guard i0 >= 0 else { return }
        var i = 0
        while i < piece.count && i0 + i < target.count {
            target[i0 + i] += piece[i]
            i += 1
        }
    }
    func snorePiece(_ dur: Double, period: Double, f0: Double, level: Double, seed: UInt64,
                    duty: Double = 0.45) -> [Double] {
        SnoreSynth.snore(count: Int(sr * dur), sampleRate: sr, periodSec: period, f0: f0,
                         level: level, duty: duty, seed: seed)
    }

    var s = SnoreSynth.bed(count: Int(sr * 900), level: 0.0006, seed: 31)
    // 六段鼾，段间的空档都明显长于 10 s 阈值 ⇒ 每道空档该出一条「疑似中断」；
    // 说话放在 170→260 那一道空档里 ⇒ 那一条要带「期间有别的发声」；
    // 敲击三下 ⇒ 不该变成发作，也不该变成中断。
    // 420 s 那一段刻意摆成「一鼾一口气」（周期 7 s、一声只 0.45 s、还偏轻）：
    // 用户手机那一晚就是这个形状，旧写法整晚一件鼾都没判出来，而其余五段周期都在 4 s 内，
    // 天生照不出这条——所以稀疏那段必须由这里钉住。
    lay(snorePiece(40, period: 3.0, f0: 130, level: 0.10, seed: 5), into: &s, at: 30)
    lay(snorePiece(60, period: 3.4, f0: 145, level: 0.12, seed: 6), into: &s, at: 110)
    lay(SnoreSynth.speech(count: Int(sr * 25), sampleRate: sr, level: 0.09, seed: 11), into: &s, at: 180)
    lay(snorePiece(90, period: 2.8, f0: 120, level: 0.14, seed: 7), into: &s, at: 260)
    lay(snorePiece(100, period: 7.0, f0: 160, level: 0.08, seed: 8, duty: 0.45 / 7.0), into: &s, at: 420)
    lay(snorePiece(160, period: 3.1, f0: 135, level: 0.11, seed: 9), into: &s, at: 700)
    lay(SnoreSynth.clicks(count: s.count, sampleRate: sr, level: 0.25, at: [400, 650, 660]), into: &s, at: 0)

    let tr = SnoreTracker(frameSec: Double(SnoreAnalyzer.defaultWindow) / sr, config: config)
    let got = SnoreCases.run(samples: s, sampleRate: sr, config: config, into: tr)
    let summary = SnoreAnalyze.summarize(buckets: got.seconds, events: got.events, config: config)
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    let text = SnoreAnalyze.reportText(summary: summary, start: start,
                                       end: start.addingTimeInterval(900),
                                       events: got.events, buckets: got.seconds, config: config,
                                       facts: [], title: "鼾声监测报告（CI 合成样例）")
    print("------ 合成样例报告 ------")
    print(text)
    print("------ 样例账目：事件 \(got.events.count) 条（发作 \(summary.boutCount)／停 \(summary.gapCount)／发声 \(summary.vocalCount)）"
        + "／逐秒 \(got.seconds.count) 格／帧 \(got.frames) ------")
    // 这一晚是「该看见东西的一晚」：一件都没判出来就说明通路断了（比如喂块尺寸变了、门限写反了）
    if summary.boutCount == 0 || summary.gapCount == 0 {
        bad += 1
        print("CASE FAIL 合成样例里鼾发作或停住没判出来（发作 \(summary.boutCount)／停 \(summary.gapCount)）")
    }
    // 说话夹在 169→260 那道空档里 ⇒ 至少一条中断要带「期间有别的发声」；不带就说明记账时机写回了「开停时看一眼」
    if !got.events.contains(where: { $0.kind == .gap && $0.otherDuring }) {
        bad += 1
        print("CASE FAIL 合成样例里没有一条中断带「期间有别的发声」")
    }
    // 一晚只有一段说话：敲击三下都不该各记一条，鼾段开头那半秒更不该（旧写法一晚能凭空多出五六条假梦话）
    if summary.vocalCount > 3 {
        bad += 1
        print("CASE FAIL 合成样例里「其他发声」出了 \(summary.vocalCount) 条（只摆了一段说话，要 ≤3）")
    }
    // 420–520 那段稀疏鼾：要判成一段发作，且节律数得出 6–12 次/分（一口气 5–10 s）。
    // 这一条就是 0.4 那晚的守门员：旧写法在这里是「发作 0 段、鼾声占 0.0%」。
    let sparse = got.events.filter { $0.kind == .bout && $0.t0 >= 400 && $0.t1 <= 560 }
    let sparseRates = sparse.compactMap { $0.ratePerMin }
    if sparse.count != 1 || !sparseRates.contains(where: { $0 >= 6.0 && $0 <= 12.0 }) {
        bad += 1
        print("CASE FAIL 稀疏鼾那段判成 \(sparse.count) 段（要 1）／节律 \(sparseRates)（要有一段落在 6–12）")
    }
    // 收尾那一条「停住到 900 s 都没复鼾」要留在事件表里（【中断明细】要能看到几点结束的），
    // 但不进【疑似中断】的计数：用户 0.6 那晚就是被这种尾巴挂出一条 14 min 33 s，把最长和
    // 次/小时全带跑了。这里两头都钉住：少一条不行，混进计数也不行。
    let gapEvents = got.events.filter { $0.kind == .gap }
    let unresolvedEvents = gapEvents.filter { $0.unresolved }
    if unresolvedEvents.isEmpty {
        bad += 1
        print("CASE FAIL 合成样例收尾没留「未复鼾」那条事件（最后一段鼾到 900 s 空了 40 s）")
    }
    if summary.gapCount != gapEvents.count - unresolvedEvents.count
        || summary.unresolvedCount != unresolvedEvents.count {
        bad += 1
        print("CASE FAIL 中断记账串了：计数 \(summary.gapCount)／未复鼾 \(summary.unresolvedCount)"
            + "／事件共 \(gapEvents.count) 条（其中未复鼾 \(unresolvedEvents.count)）")
    }
}

print("SNORE-VERDICT \(bad == 0 ? "PASS" : "FAIL") 用例 \(results.count - badCases)/\(results.count)"
    + "／合成夜 \(bad == badCases ? "OK" : "FAIL")"
    + "｜耗时 \(String(format: "%.0f", elapsedMs)) ms")
exit(bad == 0 ? 0 : 1)
