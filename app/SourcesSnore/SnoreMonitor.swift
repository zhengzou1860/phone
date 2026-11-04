import AVFoundation
import Combine
import Foundation
import UIKit

// MARK: - 界面与 core 之间的那一层
//
// 三条规矩都在这层立住：
// ① @Published 只在主线程改（core 递上来的回调已经是主线程了）；
// ② 读盘、汇总、发网络一律丢到 work 队列——历史页一次要翻十几个晚上的 curve.csv，
//    在主线程算就是把 Tab 划过去卡半秒；
// ③ 主线程才碰得的东西（电量、屏幕常亮）由这层喂进 SnoreEnv 缓存，拼报告的队列只读缓存。

/// 事件/曲线的时间是「会话内第几秒」，界面上要还给用户墙上时钟。
func snoreWallClock(_ start: Date, _ t: Double) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: start.addingTimeInterval(t))
}

struct SnoreNightRow: Identifiable {
    var id: String
    var meta: SnoreNightMeta
    var dayText: String       // 「11月04日 周三」
    var clockText: String      // 「23:12 → 06:40」
    var totalText: String
    var coverage: Double
    var grade: String
    var boutCount: Int
    var gapCount: Int
    var vocalCount: Int
    var longestGap: Double
    var peakText: String
    var hasReport: Bool
}

struct SnoreNightDetail: Identifiable {
    var id: String
    var meta: SnoreNightMeta
    var summary: SnoreSummary
    var chart: [SnoreChartPoint]
    var events: [SnoreEvent]
    var report: String
    var snippetIds: Set<Int>
    var dirText: String
}

final class SnoreMonitor: NSObject, ObservableObject {
    static let keepAwakeKey = "snore.keepawake"

    // 今晚
    @Published var live = SnoreLive()
    @Published var events: [SnoreEvent] = []
    @Published var notes: [String] = []
    @Published var running = false
    @Published var statusLine = ""
    /// 正在录的这一晚落在哪个目录——「今晚」页上点「听片段」要拿它拼路径。
    @Published var currentNightId = ""
    @Published var nightStart = Date()

    // 档位
    @Published var config = SnoreConfig.load()
    @Published var keepAwake = UserDefaults.standard.bool(forKey: SnoreMonitor.keepAwakeKey)

    // 历史／报告／调试
    @Published var rows: [SnoreNightRow] = []
    @Published var detail: SnoreNightDetail?
    @Published var report = ""
    @Published var facts: [String] = []
    @Published var uploadReply = ""
    @Published var uploading = false
    @Published var checks: [SnoreCaseResult] = []
    @Published var checksRunning = false

    let core = SnoreCore()
    private let work = DispatchQueue(label: "com.qoder.snorebench.ui", qos: .userInitiated)
    private var player: AVAudioPlayer?
    private var envTimer: Timer?

    override init() {
        super.init()
        core.onLive = { [weak self] snap in self?.live = snap }
        core.onEvent = { [weak self] e in
            guard let self = self else { return }
            self.events.append(e)
            // 今晚的事件表只往前翻，界面滚动才跟得上；一晚上千条也不把 List 拖垮
            if self.events.count > 400 { self.events.removeFirst(self.events.count - 400) }
        }
        core.onNote = { [weak self] text in self?.note(text) }
        applyKeepAwake()
        SnorePressureWatch.start()
        note("启动：\(SnoreFacts.machine())｜盘上可用 \(String(format: "%.1f", SnoreArchive.diskFreeMB() / 1024.0)) GB")
        // 上次没正常收尾的那一晚（闪退／被杀／没电）先补个结尾，别让它悬在历史里当「正在录」
        work.async {
            let fixed = SnoreArchive.recoverOpenNights()
            for n in fixed {
                DispatchQueue.main.async { self.note("补收 \(n.meta.id)：\(n.meta.note)") }
            }
            if !fixed.isEmpty { SnoreJournal.line("补收尾 \(fixed.count) 晚：" + fixed.map { $0.meta.id }.joined(separator: ",")) }
            self.reloadHistory()
        }
        envTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            SnoreMonitor.feedEnv()
        }
    }

    deinit { envTimer?.invalidate() }

    /// 电量与屏幕常亮：只有主线程读得到，读到就塞进缓存给后台的报表用。
    static func feedEnv() {
        let d = UIDevice.current
        let wasOn = d.isBatteryMonitoringEnabled
        if !wasOn { d.isBatteryMonitoringEnabled = true }
        let level = d.batteryLevel
        let state = d.batteryState
        if !wasOn { d.isBatteryMonitoringEnabled = false }
        let stateText: String
        switch state {
        case .full: stateText = "满"
        case .charging: stateText = "充电中"
        case .unplugged: stateText = "未接电"
        default: stateText = "未知"
        }
        let text = level < 0 ? "读不到（\(stateText)）" : "\(Int((level * 100).rounded()))% \(stateText)"
        SnoreEnv.update(batteryText: text, idleTimerDisabled: UIApplication.shared.isIdleTimerDisabled)
    }

    // MARK: 开停

    func toggleRun() {
        if running { stop() } else { start() }
    }

    func start() {
        SnoreMonitor.feedEnv()
        config.save()
        let reject = core.begin(config: config)
        guard reject.isEmpty else {
            statusLine = reject
            note("没开起来：" + reject)
            return
        }
        running = true
        events = []
        live = SnoreLive()
        report = ""
        nightStart = Date()
        statusLine = "在录。熄屏也接着录，明早点「停止」出报告。"
        // 目录名由 core 在开那一晚生成，这里回读最新的一晚拿到它（别自己再拼一次时间，差一秒就对不上）
        work.async {
            let id = SnoreArchive.list().first?.meta.id ?? ""
            DispatchQueue.main.async { self.currentNightId = id }
        }
        SnoreJournal.line("开始一晚：灵敏度 \(config.sensitivity)｜中断阈值 \(Int(config.interruptGapSec)) s"
                          + "｜发作间隔 \(config.boutGapSec) s｜门限 \(config.absGateDb) dBFS｜片段 \(config.keepSnippets)")
    }

    func stop() {
        core.end()
        running = false
        statusLine = "已收尾，报告出在「报告」页，那一晚也进了历史。"
        SnoreJournal.line("手动收尾")
        reloadHistory()
        refreshReport()
    }

    // MARK: 档位

    /// 设置页改完调这个：存盘＋让挂着的那一场就地生效（分析器和状态机都只读 config 的那几个字段）。
    func saveConfig() {
        config.save()
        core.applyConfig(config)
        note("档位已存：灵敏度 \(config.sensitivity)／中断 \(Int(config.interruptGapSec)) s／间隔 \(config.boutGapSec) s")
    }

    private func applyKeepAwake() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake
        SnoreJournal.line("屏幕常亮 \(keepAwake ? "开" : "关")")
        SnoreMonitor.feedEnv()
    }

    /// 界面上那颗开关走这里：改值＋真把防休眠设下去（@Published 没有 didSet，不能指望赋值自己生效）。
    func setKeepAwake(_ on: Bool) {
        keepAwake = on
        applyKeepAwake()
    }

    // MARK: 备注一条流水

    private func note(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        notes.append("\(f.string(from: Date())) \(text)")
        if notes.count > 120 { notes.removeFirst(notes.count - 120) }
    }

    // MARK: 历史

    func reloadHistory() {
        work.async {
            let nights = SnoreArchive.list()
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "M月d日 EEE"
            var out: [SnoreNightRow] = []
            for n in nights {
                let s = SnoreAnalyze.summarize(buckets: n.buckets, events: n.events, config: n.meta.config)
                let total = n.meta.ended ? max(0, n.meta.endDate.timeIntervalSince(n.meta.startDate))
                    : Double(n.buckets.count)
                out.append(SnoreNightRow(id: n.meta.id, meta: n.meta,
                                         dayText: dayFmt.string(from: n.meta.startDate),
                                         clockText: "\(snoreClockText(n.meta.startDate)) → \(snoreClockText(n.meta.endDate))",
                                         totalText: snoreDurText(total),
                                         coverage: s.coverage, grade: s.grade,
                                         boutCount: s.boutCount, gapCount: s.gapCount,
                                         vocalCount: s.vocalCount, longestGap: s.longestGap,
                                         peakText: SnoreCalib.text(s.peakDb, n.meta.config),
                                         hasReport: FileManager.default.fileExists(atPath: n.reportURL.path)))
            }
            DispatchQueue.main.async { self.rows = out }
        }
    }

    /// 点开某晚：整份 curve.csv 读回来＋重算一次汇总（数字和跑着的时候同一个口径）。
    func openDetail(_ id: String) {
        work.async {
            guard let root = SnoreArchive.root else { return }
            let dir = root.appendingPathComponent(id)
            guard let n = SnoreNightStore.load(dir: dir) else {
                DispatchQueue.main.async { self.statusLine = "那一晚读不出来：\(id)" }
                return
            }
            let cfg = n.meta.config
            let s = SnoreAnalyze.summarize(buckets: n.buckets, events: n.events, config: cfg)
            let gapMarks = n.events.filter { $0.kind == .gap }.map { $0.t0 }
            let vocalMarks = n.events.filter { $0.kind == .vocal }.map { $0.t0 }
            let chart = SnoreCore.decimate(n.buckets, span: Double(max(1, n.buckets.count)),
                                           gapMarks: gapMarks, vocalMarks: vocalMarks,
                                           bins: SnoreCore.chartBins)
            var ids = Set<Int>()
            for e in n.events where n.hasSnippet(e.id) { ids.insert(e.id) }
            let text = (try? String(contentsOf: n.reportURL, encoding: .utf8)) ?? ""
            let d = SnoreNightDetail(id: id, meta: n.meta, summary: s, chart: chart,
                                     events: n.events, report: text, snippetIds: ids,
                                     dirText: n.dir.lastPathComponent)
            DispatchQueue.main.async {
                self.detail = d
                if !text.isEmpty { self.report = text }
            }
        }
    }

    func deleteNight(_ id: String) {
        work.async {
            guard let root = SnoreArchive.root else { return }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
            SnoreJournal.line("删掉一晚 \(id)")
            DispatchQueue.main.async {
                if self.detail?.id == id { self.detail = nil }
                self.reloadHistory()
            }
        }
    }

    func deleteAll() {
        core.end()
        running = false
        work.async {
            SnoreArchive.deleteAll()
            SnoreJournal.line("清空所有晚上")
            DispatchQueue.main.async {
                self.detail = nil
                self.report = ""
                self.statusLine = "本地记录已清空。"
                self.reloadHistory()
            }
        }
    }

    // MARK: 片段回放

    /// 播某一晚的 s_<id>.wav。录音挂着的时候也能播：会话本来就是 playAndRecord。
    func playSnippet(nightId: String, eventId: Int) {
        stopPlayback()
        work.async {
            guard let root = SnoreArchive.root else { return }
            let url = root.appendingPathComponent(nightId).appendingPathComponent("snippets")
                .appendingPathComponent("s_\(eventId).wav")
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.prepareToPlay()
                DispatchQueue.main.async {
                    self.player = p
                    if p.play() { self.statusLine = "播放 s_\(eventId).wav（\(String(format: "%.1f", p.duration)) s）" }
                    else { self.statusLine = "点了没响：播放器起了但播不出来（可能被别的音频占着）" }
                }
            } catch {
                DispatchQueue.main.async { self.statusLine = "片段打不开：\(error)" }
            }
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
    }

    // MARK: 报告

    /// 正在录的那一场：28 800 格的汇总不能在滑动的时候于主线程算，走 core 的队列。
    func refreshReport() {
        if running {
            core.requestReport { text in self.report = text }
            return
        }
        if let d = detail {
            if !d.report.isEmpty { report = d.report; return }
            work.async {
                guard let root = SnoreArchive.root else { return }
                let dir = root.appendingPathComponent(d.id)
                guard let n = SnoreNightStore.load(dir: dir) else { return }
                let s = SnoreAnalyze.summarize(buckets: n.buckets, events: n.events, config: n.meta.config)
                let text = SnoreAnalyze.reportText(summary: s, start: n.meta.startDate, end: n.meta.endDate,
                                                   events: n.events, buckets: n.buckets, config: n.meta.config,
                                                   facts: SnoreFacts.lines(), title: "鼾声监测报告 \(n.meta.id)")
                DispatchQueue.main.async { self.report = text }
            }
            return
        }
        work.async {
            let latest = SnoreArchive.list().first
            guard let n = latest else {
                DispatchQueue.main.async { self.report = "还没有任何一晚。回「今晚」点开始按钮。" }
                return
            }
            let s = SnoreAnalyze.summarize(buckets: n.buckets, events: n.events, config: n.meta.config)
            let text = SnoreAnalyze.reportText(summary: s, start: n.meta.startDate, end: n.meta.endDate,
                                               events: n.events, buckets: n.buckets, config: n.meta.config,
                                               facts: SnoreFacts.lines(), title: "鼾声监测报告 \(n.meta.id)")
            DispatchQueue.main.async { self.report = text }
        }
    }

    func refreshFacts() {
        facts = SnoreFacts.lines()
    }

    // MARK: 发到电脑

    /// 报告＋磁盘日志尾巴＋现场读数一起发：连不上线的时候这几行就是唯一能看见的东西。
    func sendToPC() {
        guard !uploading else { return }
        uploading = true
        uploadReply = "正在发往 \(SnoreUploader.endpoint) ……"
        let body = buildUploadText()
        work.async {
            let reply = SnoreUploader.send(body)
            SnoreJournal.line(reply)
            DispatchQueue.main.async {
                self.uploadReply = reply
                self.uploading = false
            }
        }
    }

    private func buildUploadText() -> String {
        var parts: [String] = []
        parts.append(report.isEmpty ? "（报告还没生成）" : report)
        parts.append("\n------ 磁盘日志（尾 200 行）------\n" + SnoreJournal.tail(200))
        parts.append("\n------ 现场读数 ------\n" + SnoreFacts.lines().joined(separator: "\n"))
        if running {
            parts.append("\n------ 实时 ------\n已录 \(snoreDurText(live.elapsed))｜鼾 \(live.bouts)｜停 \(live.gaps)"
                + "｜说话 \(live.vocals)｜电平 \(String(format: "%.1f", live.level)) dBFS"
                + "｜本底 \(String(format: "%.1f", live.floor)) dBFS｜重连 \(live.restarts) 次")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: 算法自检

    /// 合成信号喂进真分析器＋真状态机：改了判定阈值以后按一次，就知道有没有把原来判对的判坏。
    func runSelfTest() {
        guard !checksRunning else { return }
        checksRunning = true
        checks = []
        note("算法自检开跑……")
        let cfg = config
        work.async {
            let got = SnoreCases.all(config: cfg)
            let bad = got.filter { !$0.ok }
            SnoreJournal.line("算法自检 \(got.count - bad.count)/\(got.count) 通过"
                              + (bad.isEmpty ? "" : "｜挂了：" + bad.map { $0.name }.joined(separator: "、")))
            DispatchQueue.main.async {
                self.checks = got
                self.checksRunning = false
                self.note("算法自检结束：\(got.count - bad.count)/\(got.count) 通过")
            }
        }
    }
}
