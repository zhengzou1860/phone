import Foundation
import SwiftUI
import UIKit

// MARK: - 四页
//
// 今晚（挂着录）／历史（逐晚翻）／报告（读与发）／设置（档位与自检）。
// 界面只做「读快照、发指令」，判定和落盘都不在这层——所以这一页刷不刷新都不影响整晚的记录。

struct SnoreRootView: View {
    @StateObject private var mon = SnoreMonitor()

    var body: some View {
        TabView {
            TonightView(mon: mon)
                .tabItem { Label("今晚", systemImage: "moon.stars.fill") }
            HistoryView(mon: mon)
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
            ReportView(mon: mon)
                .tabItem { Label("报告", systemImage: "doc.plaintext.fill") }
            SettingsView(mon: mon)
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .onAppear { SnoreMonitor.feedEnv() }
    }
}

// MARK: - 今晚

struct TonightView: View {
    @ObservedObject var mon: SnoreMonitor
    @State private var showNotes = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    startButton

                    if !mon.statusLine.isEmpty {
                        Text(mon.statusLine)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    micWarning

                    levels

                    stats

                    SnoreChart(points: mon.live.chart, start: mon.nightStart,
                               span: max(120, mon.live.elapsed))

                    legend

                    eventsSection

                    notesSection
                }
                .padding(14)
            }
            .navigationTitle("鼾声监测")
            .onAppear { SnoreMonitor.feedEnv() }
            .refreshable { SnoreMonitor.feedEnv() }
        }
    }

    private var startButton: some View {
        Button(action: mon.toggleRun) {
            HStack {
                Image(systemName: mon.running ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 30))
                Text(mon.running ? "停止并出报告" : "开始记录今晚")
                    .font(.system(size: 20, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(mon.running ? Color.red.opacity(0.18) : Color.blue.opacity(0.18))
            .foregroundColor(mon.running ? .red : .blue)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var micWarning: some View {
        let perm = SnoreFacts.perm()
        if perm.contains("拒绝") || perm.contains("受限") {
            Label(perm, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundColor(.orange)
        }
    }

    private var levels: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("现在的电平").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(SnoreCalib.text(mon.live.level, mon.config))
                    .font(.system(size: 13, design: .monospaced))
            }
            SnoreLevelBar(level: mon.live.level, floorDb: mon.live.floor)
            HStack {
                Text(mon.live.snoring ? "判为：在打鼾" : "判为：没鼾")
                    .font(.caption)
                    .foregroundColor(mon.live.snoring ? .orange : .secondary)
                Spacer()
                Text(String(format: "像鼾分 %.2f／进门 %.2f", mon.live.score, mon.config.enterScore))
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                if mon.live.gapSec > 1 {
                    Text(String(format: "已停 %.0f s", mon.live.gapSec))
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.red)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var stats: some View {
        VStack(spacing: 10) {
            HStack {
                SnoreStat(title: "已录", value: snoreDurText(mon.live.elapsed))
                SnoreStat(title: "鼾声占比", value: String(format: "%.0f%%", mon.live.elapsed > 60 ? mon.live.snoreSec / mon.live.elapsed * 100 : 0),
                          tint: .orange)
                SnoreStat(title: "发作", value: "\(mon.live.bouts) 次")
                SnoreStat(title: "疑似中断", value: "\(mon.live.gaps) 次",
                          tint: mon.live.gaps > 0 ? .red : .primary)
            }
            HStack {
                SnoreStat(title: "说话/咳嗽", value: "\(mon.live.vocals) 次")
                SnoreStat(title: "最长一次鼾", value: snoreDurText(mon.live.longestBout))
                SnoreStat(title: "最长一次停", value: snoreDurText(mon.live.longestGap),
                          tint: mon.live.longestGap > 0 ? .red : .primary)
                SnoreStat(title: "整晚最响", value: SnoreCalib.text(mon.live.peakDb, mon.config))
            }
            HStack {
                SnoreStat(title: "本底", value: SnoreCalib.text(mon.live.floor, mon.config))
                SnoreStat(title: "分析块", value: "\(mon.live.blocks)／帧 \(mon.live.frames)")
                SnoreStat(title: "引擎重连", value: "\(mon.live.restarts) 次",
                          tint: mon.live.restarts > 3 ? .orange : .primary)
                SnoreStat(title: "电量", value: SnoreEnv.cachedBattery)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var legend: some View {
        Text("柱高＝这一格有多久在打｜柱色＝最响那声（绿→红）｜红竖线＝鼾声停住（疑似中断）｜顶上橙点＝说话一类｜灰条＝没采到")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("今晚的事件（最上面是刚发生的）").font(.headline)
                Spacer()
                if mon.running && !mon.currentNightId.isEmpty {
                    Button("停止播放") { mon.stopPlayback() }
                        .font(.caption)
                }
            }
            if mon.events.isEmpty {
                Text(mon.running ? "还没判出事件。睡着以后鼾声起来，这里一条条就出来了。"
                                 : "点了开始才会有。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            ForEach(mon.events.suffix(30).reversed()) { e in
                EventRow(event: e, start: mon.nightStart, config: mon.config,
                         hasSnippet: mon.running && !mon.currentNightId.isEmpty) {
                    mon.playSnippet(nightId: mon.currentNightId, eventId: e.id)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showNotes.toggle()
            } label: {
                HStack {
                    Text(showNotes ? "收起现场流水" : "现场流水（\(mon.notes.count) 条）")
                    Spacer()
                    Image(systemName: showNotes ? "chevron.up" : "chevron.down")
                }
                .font(.footnote)
            }
            if showNotes {
                ForEach(mon.notes.suffix(40).reversed(), id: \.self) { n in
                    Text(n).font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 一条事件

struct EventRow: View {
    let event: SnoreEvent
    let start: Date
    let config: SnoreConfig
    let hasSnippet: Bool
    let play: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(kindText).font(.system(size: 11, weight: .bold))
                    .foregroundColor(kindColor)
                    .frame(width: 62, alignment: .leading)
                Text(snoreWallClock(start, event.t0))
                    .font(.system(size: 11, design: .monospaced))
                Text("— \(snoreDurText(event.dur))").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                if hasSnippet {
                    Button("听") { play() }
                        .font(.system(size: 12, weight: .semibold))
                        .buttonStyle(.bordered)
                        .tint(.orange)
                }
            }
            HStack(spacing: 8) {
                Text("响 \(SnoreCalib.text(event.peakDb, config)) 均 \(SnoreCalib.text(event.meanDb, config))")
                if let r = event.ratePerMin { Text(String(format: "%.0f 次/分", r)) }
                if let hz = event.peakHz { Text(String(format: "%.0f Hz", hz)) }
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            if event.kind == .gap {
                Text(gapTail).font(.system(size: 10)).foregroundColor(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private var kindText: String {
        switch event.kind {
        case .bout: return "鼾发作"
        case .gap: return "停住"
        case .vocal: return "发声"
        }
    }

    private var kindColor: Color {
        switch event.kind {
        case .bout: return .orange
        case .gap: return .red
        case .vocal: return .yellow
        }
    }

    private var gapTail: String {
        var t = "停 \(snoreDurText(event.dur))"
        if let p = event.preDb { t += "｜停前 \(SnoreCalib.text(p, config))" }
        if let r = event.resumeDb { t += "｜复鼾 \(SnoreCalib.text(r, config))" }
        if event.arousal { t += "｜复鼾更响" }
        if event.otherDuring { t += "｜中间有别的声" }
        if event.unresolved { t += "｜之后再没鼾" }
        return t
    }
}

// MARK: - 历史

struct HistoryView: View {
    @ObservedObject var mon: SnoreMonitor

    var body: some View {
        NavigationStack {
            Group {
                if mon.rows.isEmpty {
                    ContentUnavailableView("还没有记录", systemImage: "moon",
                                           description: Text("回「今晚」点开始，明早这里就有一晚。"))
                } else {
                    List {
                        ForEach(mon.rows) { r in
                            Button { mon.openDetail(r.id) } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(r.dayText + "  " + r.clockText)
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        Text("录 \(r.totalText)｜鼾 \(String(format: "%.0f%%", r.coverage * 100)) \(r.grade)"
                                             + "｜发作 \(r.boutCount)｜停 \(r.gapCount)｜发声 \(r.vocalCount)")
                                            .font(.system(size: 11)).foregroundColor(.secondary)
                                        if !r.meta.ended {
                                            Text("这一晚没收到收尾（App 被杀／没电？）").font(.system(size: 10)).foregroundColor(.orange)
                                        } else if !r.meta.note.isEmpty {
                                            Text(r.meta.note).font(.system(size: 10)).foregroundColor(.orange).lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundColor(.secondary)
                                }
                            }
                            .foregroundColor(.primary)
                            .swipeActions {
                                Button("删", role: .destructive) { mon.deleteNight(r.id) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("历史（\(mon.rows.count) 晚）")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新") { mon.reloadHistory() }
                }
            }
            .onAppear { mon.reloadHistory() }
            .refreshable { mon.reloadHistory() }
            .sheet(item: $mon.detail) { d in
                NightDetailView(mon: mon, detail: d)
            }
        }
    }
}

struct NightDetailView: View {
    @ObservedObject var mon: SnoreMonitor
    let detail: SnoreNightDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        SnoreStat(title: "鼾声占比", value: detail.summary.coverageText + " " + detail.summary.grade,
                                  tint: .orange)
                        SnoreStat(title: "发作", value: detail.summary.boutsText)
                        SnoreStat(title: "疑似中断", value: detail.summary.gapsText,
                                  tint: detail.summary.gapCount > 0 ? .red : .primary)
                        SnoreStat(title: "最长停", value: snoreDurText(detail.summary.longestGap))
                    }
                    HStack {
                        SnoreStat(title: "鼾内节律", value: detail.summary.rateText)
                        SnoreStat(title: "峰值", value: SnoreCalib.text(detail.summary.peakDb, detail.meta.config))
                        SnoreStat(title: "鼾声期均值", value: SnoreCalib.text(detail.summary.snoreMeanDb, detail.meta.config))
                        SnoreStat(title: "本底中位", value: SnoreCalib.text(detail.summary.floorMedianDb, detail.meta.config))
                    }
                    HStack {
                        SnoreStat(title: "复鼾更响", value: "\(detail.summary.arousalCount) 次")
                        SnoreStat(title: "停住后没复鼾", value: "\(detail.summary.unresolvedCount) 次")
                        SnoreStat(title: "说话/咳嗽", value: "\(detail.summary.vocalCount) 次")
                        SnoreStat(title: "没采到", value: snoreDurText(Double(detail.summary.staleSec)))
                    }
                    Text(SnoreAnalyze.advice(detail.summary, detail.meta.config))
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    SnoreChart(points: detail.chart, start: detail.meta.startDate,
                               span: Double(max(120, detail.meta.seconds)))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("中断在哪几点（从长到短，最多 12 条）").font(.headline)
                        if detail.summary.gapCount == 0 {
                            Text("这一晚没判出鼾声停住。").font(.footnote).foregroundColor(.secondary)
                        }
                        ForEach(detail.events.filter { $0.kind == .gap }.sorted { $0.dur > $1.dur }.prefix(12)) { e in
                            HStack {
                                Text(snoreWallClock(detail.meta.startDate, e.t0))
                                    .font(.system(size: 12, design: .monospaced))
                                Text(snoreDurText(e.dur)).foregroundColor(.red)
                                Text(e.unresolved ? "之后没复鼾" : (e.arousal ? "复鼾更响" : "复鼾"))
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                                Spacer()
                                if detail.snippetIds.contains(e.id) {
                                    Button("听") { mon.playSnippet(nightId: detail.id, eventId: e.id) }
                                        .font(.system(size: 12, weight: .semibold))
                                        .buttonStyle(.bordered).tint(.orange)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("今晚全部事件（\(detail.events.count) 条）").font(.headline)
                        ForEach(detail.events.suffix(60).reversed()) { e in
                            EventRow(event: e, start: detail.meta.startDate, config: detail.meta.config,
                                     hasSnippet: detail.snippetIds.contains(e.id)) {
                                mon.playSnippet(nightId: detail.id, eventId: e.id)
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button("重算报告") { mon.refreshReport() }
                            .buttonStyle(.bordered)
                        Button(mon.uploading ? "发送中……" : "发到电脑") { mon.sendToPC() }
                            .buttonStyle(.borderedProminent)
                            .disabled(mon.uploading)
                        ShareLink(item: mon.report.isEmpty ? "（还没报告）" : mon.report) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                    if !mon.uploadReply.isEmpty {
                        Text(mon.uploadReply).font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if !mon.statusLine.isEmpty {
                        Text(mon.statusLine).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                .padding(14)
            }
            .navigationTitle(detail.id)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
        }
    }
}

// MARK: - 报告

struct ReportView: View {
    @ObservedObject var mon: SnoreMonitor
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Button("刷新") { mon.refreshReport() }
                            .buttonStyle(.bordered)
                        Button {
                            mon.sendToPC()
                        } label: {
                            Label(mon.uploading ? "发送中……" : "发到电脑",
                                  systemImage: "cable.connector")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(mon.uploading)
                        Button {
                            UIPasteboard.general.string = mon.report
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        ShareLink(item: mon.report.isEmpty ? "（还没报告）" : mon.report) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                    if !mon.uploadReply.isEmpty {
                        Text(mon.uploadReply)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    Text(mon.report.isEmpty ? "还没有报告。录完一晚（或从历史点开一晚）就出得来。" : mon.report)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .textSelection(.enabled)

                    Button {
                        showLog.toggle()
                    } label: {
                        HStack {
                            Text(showNotesTitle)
                            Spacer()
                            Image(systemName: showLog ? "chevron.up" : "chevron.down")
                        }
                        .font(.footnote)
                    }
                    if showLog {
                        Button("重新读现场读数") { mon.refreshFacts() }.font(.caption)
                        Text(mon.facts.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                        Text(SnoreJournal.tail(60))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
            }
            .navigationTitle("报告")
            .onAppear { mon.refreshFacts() }
        }
    }

    private var showNotesTitle: String {
        showLog ? "收起运行环境与磁盘日志" : "运行环境与磁盘日志（调试用）"
    }
}

// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var mon: SnoreMonitor
    @State private var confirmWipe = false

    var body: some View {
        NavigationStack {
            Form {
                Section("判定") {
                    Picker("灵敏度", selection: $mon.config.sensitivity) {
                        Text("低（只收明显的）").tag(0)
                        Text("中（推荐）").tag(1)
                        Text("高（轻鼾也收）").tag(2)
                    }
                    Text("进门分 \(String(format: "%.2f", mon.config.enterScore))／出门分 \(String(format: "%.2f", mon.config.exitScore))：比这两条线高就算鼾，中间晃不算断。")
                        .font(.system(size: 10)).foregroundColor(.secondary)

                    Picker("鼾声停多久算一次「疑似中断」", selection: $mon.config.interruptGapSec) {
                        Text("8 秒").tag(8.0)
                        Text("10 秒（推荐）").tag(10.0)
                        Text("15 秒").tag(15.0)
                        Text("20 秒（只报很长的）").tag(20.0)
                    }
                    Picker("一次发作允许的最大间隔", selection: $mon.config.boutGapSec) {
                        Text("2.0 秒（分得细）").tag(2.0)
                        Text("2.5 秒（推荐）").tag(2.5)
                        Text("4.0 秒（并成大段）").tag(4.0)
                    }
                    Text("鼾本来就是一鼾一鼾跳的：这一档设到 1 秒以下，一晚连续鼾会被劈成上千次「发作」，次/小时就成了废数。")
                        .font(.system(size: 10)).foregroundColor(.secondary)

                    Picker("绝对门限", selection: $mon.config.absGateDb) {
                        Text("-50 dBFS（只收响的）").tag(-50.0)
                        Text("-58 dBFS（推荐）").tag(-58.0)
                        Text("-65 dBFS（连很轻的）").tag(-65.0)
                    }
                    Picker("多短算瞬发（咳嗽/关门）", selection: $mon.config.minBoutSec) {
                        Text("0.4 秒").tag(0.4)
                        Text("0.5 秒（推荐）").tag(0.5)
                        Text("0.8 秒").tag(0.8)
                    }
                }

                Section("留什么") {
                    Toggle("事件留 6 秒音频片段（能放给医生听）", isOn: $mon.config.keepSnippets)
                    Text("一晚约 10～30 MB（存 16 k 单声道）。关掉最省盘，但第二天没法回放。")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    Picker("本地保留几晚", selection: $mon.config.keepNights) {
                        Text("7 晚").tag(7)
                        Text("14 晚").tag(14)
                        Text("30 晚").tag(30)
                    }
                }

                Section("刻度") {
                    Stepper(value: $mon.config.calOffsetDb, in: -40...40, step: 1) {
                        Text("声级计校准偏移：\(mon.config.calOffsetDb >= 0 ? "+" : "")\(Int(mon.config.calOffsetDb)) dB")
                    }
                    Text(mon.config.calOffsetDb == 0
                         ? "没接声级计就留 0：报告里所有响度都是手机麦克风的相对刻度 dBFS，不是 dB(A) SPL。"
                         : "按 \(Int(mon.config.calOffsetDb)) dB 折算，界面上会同时给「dBFS ≈ 校准后」。跨手机还是要重新对一次。")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }

                Section("跑一整晚") {
                    Toggle(isOn: Binding(get: { mon.keepAwake }, set: { mon.setKeepAwake($0) })) {
                        Text("屏幕常亮（更费电，但熄屏这一路就断了）")
                    }
                    HStack {
                        Text("麦克风权限")
                        Spacer()
                        Text(SnoreFacts.perm()).foregroundColor(.secondary)
                    }
                    HStack {
                        Text("电量")
                        Spacer()
                        Text(SnoreEnv.cachedBattery).foregroundColor(.secondary)
                    }
                    HStack {
                        Text("磁盘可用")
                        Spacer()
                        Text(String(format: "%.1f GB", SnoreArchive.diskFreeMB() / 1024.0)).foregroundColor(.secondary)
                    }
                    Text("熄屏本身不影响录音（Info 里给了 audio 后台模式）；真正会掐的是低电量模式和杀后台。充电时把「低电量模式」关掉最稳。")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }

                Section("算法自检") {
                    Button {
                        mon.runSelfTest()
                    } label: {
                        Text(mon.checksRunning ? "正在跑（合成信号喂进真分析器，几秒）……" : "跑一遍合成信号")
                    }
                    .disabled(mon.checksRunning)
                    ForEach(Array(mon.checks.enumerated()), id: \.offset) { _, c in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: c.ok ? "checkmark.seal.fill" : "xmark.seal.fill")
                                    .foregroundColor(c.ok ? .green : .red)
                                Text(c.name).font(.system(size: 12, weight: .semibold))
                            }
                            Text(c.detail).font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    Text("改过阈值以后按一次：拿合成鼾声喂进真分析器和真状态机，看事件表的数字还对不对。")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }

                Section {
                    Button("清空本地所有记录", role: .destructive) { confirmWipe = true }
                } footer: {
                    Text("把 \(mon.rows.count) 晚的曲线、事件、片段全删掉。删之前先用「发到电脑」或「分享」把要留的报告带走。")
                }
            }
            .navigationTitle("设置")
            .onChange(of: mon.config) { _, _ in mon.saveConfig() }
            .confirmationDialog("确定把本地记录全清掉？", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("全清", role: .destructive) { mon.deleteAll() }
                Button("算了", role: .cancel) {}
            }
        }
    }
}
