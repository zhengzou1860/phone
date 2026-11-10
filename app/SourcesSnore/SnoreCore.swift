import AVFoundation
import Foundation
import UIKit

// MARK: - 今晚这一场的总管
//
// 线程口径：音频块从 SnoreAudio 的分析队列递过来，一律再 hop 进 core 这一条串行队列——
// FFT、判定、落盘都在这条队列上按顺序发生，没有第二处写者。界面上读的那份是快照，
// 由 core 每 1 s 整份递回主线程（不是逐帧推：一晚 28 800 格每帧都刷会把界面拖死）。

/// 图上的一格（整晚最多 720 格，屏宽就那么点）
struct SnoreChartPoint {
    var t0: Double       // 这一格起点（会话内秒）
    var dur: Double      // 这一格跨度（秒）
    var cov: Double      // 0…1 鼾声占比
    var maxDb: Double
    var score: Double
    var hasGap: Bool
    var hasVocal: Bool
    var stale: Bool
}

/// 递回主线程的那一份实时快照
struct SnoreLive {
    var elapsed = 0.0
    var level = -120.0
    var floor = -75.0
    var score = 0.0
    var snoring = false
    var gapSec = 0.0
    var bouts = 0
    var gaps = 0
    var vocals = 0
    var snoreSec = 0.0
    var longestBout = 0.0
    var longestGap = 0.0
    var peakDb = -120.0
    var frames = 0
    var blocks = 0
    var restarts = 0
    var chart: [SnoreChartPoint] = []
}

final class SnoreCore {
    /// 下面三个回调都已经被递到主线程
    var onLive: ((SnoreLive) -> Void)?
    var onEvent: ((SnoreEvent) -> Void)?
    var onNote: ((String) -> Void)?

    static let chartBins = 720

    private let queue = DispatchQueue(label: "com.qoder.snorebench.core", qos: .utility)
    private let audio = SnoreAudio()

    private var analyzer: SnoreAnalyzer?
    private var tracker: SnoreTracker?
    private var store: SnoreNightStore?
    /// 收尾那一刻的判定账目：tracker 收尾以后就放了，之后再发执行日志得有这份才不至于只写「没起来」
    private var judgeSnapshot = ""

    private var config = SnoreConfig()
    private var running = false
    private var frames = 0
    private var lastEndTime = 0.0
    private var lastPublish = -1.0
    private var lastFlush = -1.0
    private var lastHeartbeat = -1.0
    private var peakDb = -120.0
    private var gapMarks: [Double] = []
    private var vocalMarks: [Double] = []

    // MARK: 开停

    /// 返回空串＝可以开始；非空是把按钮按下去的那句拒绝。
    func begin(config: SnoreConfig) -> String {
        let free = SnoreArchive.diskFreeMB()
        // 只落逐秒曲线＋事件＋报告，一晚 1 MB 量级；60 MB 够十几晚周转，不必再为音频留半 G。
        let need = 60.0
        if free >= 0 && free < need {
            return "磁盘只剩 \(String(format: "%.0f", free)) MB，这条线要 \(Int(need)) MB 才敢开整晚。先清掉旧晚再来。"
        }
        queue.sync {
            guard !running else { return }
            running = true
            self.config = config
            frames = 0
            peakDb = -120
            gapMarks = []
            vocalMarks = []
            lastEndTime = 0
            lastPublish = -1
            lastFlush = 0
            lastHeartbeat = 0
            analyzer = nil
            tracker = nil
            store = SnoreArchive.openNight(start: Date(), config: config,
                                           sampleRate: audio.sampleRate,
                                           device: SnoreFacts.machine())
            audio.onBlock = { [weak self] samples, t in
                self?.queue.async { self?.process(samples: samples, endTime: t) }
            }
            audio.onNote = { [weak self] text in self?.post(text) }
        }
        audio.start()
        return ""
    }

    /// 收尾顺序要紧：先让音频别再递块进来，再把队列里已排着的块跑完，最后才结帐。
    func end() {
        audio.stop()
        queue.sync {
            guard running else { return }
            running = false
            let t = lastEndTime
            tracker?.finish(at: t + 0.1)
            judgeSnapshot = tracker.map { Self.judgeLine($0) } ?? ""
            if let store = store {
                store.meta.endMs = Date().timeIntervalSince1970 * 1000.0
                store.meta.restarts = audio.restarts
                store.meta.blocks = audio.blocksDelivered
                store.meta.seconds = store.buckets.count
                store.meta.ended = true
                store.meta.config = config
                store.flush()
                store.writeReport(reportTextNow())
                let removed = SnoreArchive.prune(keepNights: config.keepNights)
                SnoreJournal.line("收尾 \(store.meta.id)：录了 \(snoreDurText(t))，格 \(store.buckets.count)，"
                                  + "事件 \(store.events.count)，重连 \(audio.restarts) 次"
                                  + "｜" + judgeSnapshot
                                  + (removed.isEmpty ? "" : "｜顺手清掉旧晚 " + removed.joined(separator: ",")))
                post("今晚的记录收在 \(store.dir.lastPathComponent)，报告已生成")
            }
            store = nil
            analyzer = nil
            tracker = nil
        }
    }

    /// 设置页改了档位：整晚挂着的时候也要就地生效。
    func applyConfig(_ c: SnoreConfig) {
        queue.async {
            self.config = c
            self.analyzer?.config = c
            self.tracker?.config = c
            self.store?.meta.config = c
        }
    }

    var isRunning: Bool {
        var v = false
        queue.sync { v = running }
        return v
    }

    /// 「为什么一件鼾都没判出来」的一行账：发执行日志时挂在最上面，不必 guess
    var judgeNote: String {
        var v = "分析器还没起来（没开始录，或第一块音频没到手）"
        queue.sync {
            if let t = tracker {
                v = Self.judgeLine(t)
            } else if !judgeSnapshot.isEmpty {
                // 收尾以后 tracker 已经放了：这时候发日志，读的是收尾那一刻留下的那份
                v = "上一场收尾时：" + judgeSnapshot
            }
        }
        return v
    }

    private static func judgeLine(_ t: SnoreTracker) -> String {
        return t.judgeSummary + (t.loudestRejectedNote.isEmpty ? "" : "｜" + t.loudestRejectedNote)
    }

    // MARK: 处理一块

    private func process(samples: [Double], endTime: Double) {
        guard running else { return }
        lastEndTime = endTime
        let sr = audio.sampleRate
        if analyzer == nil || abs((analyzer?.sampleRate ?? 0) - sr) > 1 {
            let a = SnoreAnalyzer(sampleRate: sr, config: config)
            let tr = SnoreTracker(frameSec: a.frameSec, config: config)
            analyzer = a
            tracker = tr
            wireTracker()
            SnoreJournal.line("分析器就位：\(Int(sr)) Hz／窗 \(a.n) ⇒ 每帧 \(String(format: "%.3f", a.frameSec)) s"
                              + "（每秒 \(String(format: "%.1f", 1.0 / a.frameSec)) 帧）")
        }
        guard let analyzer = analyzer, let tracker = tracker else { return }

        frames += 1
        analyzer.feed(samples, endTime: endTime) { f in
            tracker.accept(f)
            if f.peak > self.peakDb { self.peakDb = f.peak }
        }

        if endTime - lastFlush >= 30.0 {
            lastFlush = endTime
            store?.flush()
        }
        if endTime - lastHeartbeat >= 60.0 {
            lastHeartbeat = endTime
            SnoreJournal.line("心跳 \(snoreDurText(endTime))：本底 \(String(format: "%.1f", tracker.liveFloor)) dBFS"
                              + "｜鼾 \(tracker.boutCount)｜停 \(tracker.gapCount)｜说话 \(tracker.vocalCount)"
                              + "｜" + tracker.judgeSummary
                              + "｜块 \(audio.blocksDelivered)｜重连 \(audio.restarts)"
                              + "｜足迹 \(SnoreFacts.footprintMB()) MB")
        }
        if endTime - lastPublish >= 1.0 {
            lastPublish = endTime
            publish(at: endTime)
        }
    }

    private func wireTracker() {
        tracker?.onSecond = { [weak self] b in
            self?.store?.add(b)
        }
        tracker?.onSecondAmend = { [weak self] b in
            self?.store?.amend(b)
        }
        tracker?.onEvent = { [weak self] e in
            guard let self = self, let store = self.store else { return }
            store.add(e)
            if e.kind == .gap { self.gapMarks.append(e.t0) }
            if e.kind == .vocal { self.vocalMarks.append(e.t0) }
            let copy = e
            DispatchQueue.main.async { self.onEvent?(copy) }
        }
    }

    // MARK: 快照

    private func publish(at t: Double) {
        guard let tracker = tracker, let store = store else { return }
        var live = SnoreLive()
        live.elapsed = t
        live.level = tracker.liveLevel
        live.floor = tracker.liveFloor
        live.score = tracker.liveScore
        live.snoring = tracker.liveSnoring
        live.gapSec = tracker.liveOpenGapSec
        live.bouts = tracker.boutCount
        live.gaps = tracker.gapCount
        live.vocals = tracker.vocalCount
        live.snoreSec = tracker.snoreSecTotal
        live.longestBout = tracker.longestBout
        live.longestGap = tracker.longestGap
        live.peakDb = peakDb
        live.frames = frames
        live.blocks = audio.blocksDelivered
        live.restarts = audio.restarts
        live.chart = SnoreCore.decimate(store.buckets, span: t, gapMarks: gapMarks,
                                        vocalMarks: vocalMarks, bins: SnoreCore.chartBins)
        DispatchQueue.main.async { self.onLive?(live) }
    }

    /// 逐秒格 → 最多 bins 格。整晚 8 小时时一格约 40 s，够看清「哪一段在打、什么时候停的」。
    ///
    /// 历史页读盘上的 curve.csv 也走这同一条，所以「跑着的时候看的图」和「第二天看的图」是同一个口径。
    static func decimate(_ buckets: [SnoreSecond], span: Double, gapMarks: [Double],
                         vocalMarks: [Double], bins: Int) -> [SnoreChartPoint] {
        guard !buckets.isEmpty else { return [] }
        let binSec = max(1.0, span / Double(max(60, bins)))
        var out: [SnoreChartPoint] = []
        var gi = 0
        var vi = 0
        var idx = 0
        while idx < buckets.count {
            let startT = Double(buckets[idx].t0)
            let endT = startT + binSec
            var cov = 0.0
            var n = 0.0
            var mx = -120.0
            var sc = 0.0
            var stale = false
            while idx < buckets.count && Double(buckets[idx].t0) < endT {
                let b = buckets[idx]
                if b.stale {
                    stale = true
                } else {
                    cov += b.snoreSec
                    if b.maxDb > mx { mx = b.maxDb }
                    if b.maxScore > sc { sc = b.maxScore }
                }
                n += 1
                idx += 1
            }
            let dur = max(1.0, n)
            while gi < gapMarks.count && gapMarks[gi] < startT { gi += 1 }
            while vi < vocalMarks.count && vocalMarks[vi] < startT { vi += 1 }
            let hasGap = gi < gapMarks.count && gapMarks[gi] < endT
            let hasVocal = vi < vocalMarks.count && vocalMarks[vi] < endT
            out.append(SnoreChartPoint(t0: startT, dur: dur, cov: cov / dur, maxDb: mx, score: sc,
                                       hasGap: hasGap, hasVocal: hasVocal, stale: stale))
        }
        return out
    }

    // MARK: 报告

    /// 当前的报告（还没收尾也出得来，按已经采到的部分算）。只在 core 队列上读。
    func reportTextNow() -> String {
        guard let store = store else { return "这一场还没开，没得可报。" }
        let cfg = store.meta.config
        let summary = SnoreAnalyze.summarize(buckets: store.buckets, events: store.events, config: cfg)
        return SnoreAnalyze.reportText(summary: summary, start: store.meta.startDate, end: Date(),
                                       events: store.events, buckets: store.buckets, config: cfg,
                                       title: "鼾声监测报告 \(store.meta.id)")
    }

    /// 界面按「刷新报告」时走的这条路：不在主线程算 28 800 格。
    func requestReport(_ done: @escaping (String) -> Void) {
        queue.async {
            let text = self.reportTextNow()
            DispatchQueue.main.async { done(text) }
        }
    }

    private func post(_ text: String) {
        DispatchQueue.main.async { self.onNote?(text) }
    }
}
