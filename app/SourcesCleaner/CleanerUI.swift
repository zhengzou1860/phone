import Combine
import SwiftUI

@MainActor
final class CleanerModel: ObservableObject {
    let env: CleanerEnv

    @Published var categories: Set<CleanCategory> = [.junk, .model] {
        didSet { scan() }
    }

    @Published var historyDays: Int = 30 {
        didSet {
            if categories.contains(.history) { scan() }
        }
    }

    @Published var historyDaysText: String = "30"

    @Published private(set) var items: [CleanItem] = []
    @Published private(set) var notes: [String] = []
    @Published private(set) var selected: Set<String> = []
    @Published private(set) var scanning = false
    @Published private(set) var deleting = false
    @Published private(set) var resultLines: [String] = []
    @Published private(set) var lastSummary = "还没扫描"
    @Published private(set) var lastScanDate: Date?
    @Published var showDeleteConfirm = false
    @Published private(set) var verdicts = CleanerVerdictMap()
    @Published private(set) var verdictAt = ""
    @Published private(set) var pcBusy = false
    @Published private(set) var pcStatus = ""

    private var scanTask: Task<Void, Never>?
    private var generation = 0

    init() {
        env = CleanerDiscovery.discover()
        scan()
    }

    var selectedBytes: Int64 {
        items.filter { selected.contains($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
    }

    func hasCategory(_ cat: CleanCategory) -> Bool { categories.contains(cat) }

    func setCategory(_ cat: CleanCategory, on: Bool) {
        if on {
            categories.insert(cat)
        } else {
            categories.remove(cat)
        }
    }

    func isSelected(_ item: CleanItem) -> Bool { selected.contains(item.id) }

    func toggleSelection(_ item: CleanItem) {
        if selected.contains(item.id) {
            selected.remove(item.id)
        } else {
            selected.insert(item.id)
        }
    }

    func selectAll() { selected = Set(items.map(\.id)) }

    func clearSelection() { selected.removeAll() }

    // 保留几天由人填：只收数字，按「应用」或收起键盘时才真正扫描。
    func setHistoryDaysText(_ text: String) {
        historyDaysText = String(text.filter { $0.isNumber }.prefix(6))
    }

    func applyHistoryDaysText() {
        guard let value = Int(historyDaysText) else {
            historyDaysText = historyDays == 0 ? "" : "\(historyDays)"
            return
        }
        if value == 0 {
            historyDaysText = "0"
            historyDays = 0
            return
        }
        historyDaysText = "\(value)"
        historyDays = value
    }

    func setHistoryUnlimited(_ on: Bool) {
        if on {
            historyDays = 0
        } else {
            let restore = historyDaysText.isEmpty ? "30" : historyDaysText
            historyDaysText = restore
            historyDays = Int(restore) ?? 30
        }
    }

    func verdict(for item: CleanItem) -> CleanerVerdictEntry? { verdicts[item.id] }

    var recommendedCount: Int {
        items.reduce(0) { $0 + (verdicts[$1.id]?.kind == .delete ? 1 : 0) }
    }

    // 只按电脑结论改勾选，删不删还是人按「删除」那一刻决定。
    func selectRecommended() {
        selected = Set(items.filter { verdicts[$0.id]?.kind == .delete }.map(\.id))
    }

    func sendReport() {
        guard !pcBusy else { return }
        let items = self.items
        let notes = self.notes
        let cats = categories
        let days = historyDays
        let lcHome = env.lcHome?.path
        pcBusy = true
        pcStatus = "发到电脑中…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let text = CleanerReportBuilder.make(
                items: items, notes: notes, categories: cats, historyDays: days, lcHome: lcHome
            )
            let message = text.isEmpty ? "发到电脑：清单生成失败" : CleanerPC.sendReport(text)
            await MainActor.run {
                self?.pcBusy = false
                self?.pcStatus = message
            }
        }
    }

    func fetchVerdict() {
        guard !pcBusy else { return }
        pcBusy = true
        pcStatus = "取回结论中…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CleanerPC.fetchVerdict()
            await MainActor.run {
                guard let self else { return }
                self.pcBusy = false
                self.pcStatus = result.message
                if let file = result.verdict {
                    self.verdicts = CleanerVerdictMap(file: file)
                    self.verdictAt = file.generatedAt ?? ""
                }
            }
        }
    }

    func count(_ cat: CleanCategory) -> Int {
        items.reduce(0) { $0 + ($1.category == cat ? 1 : 0) }
    }

    func bytes(_ cat: CleanCategory) -> Int64 {
        items.reduce(Int64(0)) { $0 + ($1.category == cat ? $1.bytes : 0) }
    }

    func scan() {
        guard !deleting else { return }
        let cats = categories
        let days = historyDays
        generation += 1
        let gen = generation
        scanTask?.cancel()
        scanning = true
        let env = self.env
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Cleaner(env: env).scan(categories: cats, historyDays: days)
            await MainActor.run {
                guard let self, gen == self.generation else { return }
                self.apply(result)
                self.scanning = false
            }
        }
    }

    func deleteSelected() {
        guard !selected.isEmpty, !deleting else { return }
        let chosen = items.filter { selected.contains($0.id) }
        let cats = categories
        let days = historyDays
        let env = self.env
        deleting = true
        scanTask?.cancel()
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Cleaner(env: env).delete(items: chosen, categories: cats, historyDays: days)
            await MainActor.run {
                guard let self else { return }
                self.deleting = false
                self.apply(outcome.fresh)
                self.resultLines = outcome.lines
                self.resultLines.insert(
                    "这次删掉 \(outcome.deleted) 项，回收 \(CleanFormat.bytes(outcome.freed))；失败 \(outcome.failed)，跳过 \(outcome.skipped)",
                    at: 0
                )
                self.resultLines.append(
                    "删除后重新扫描：还剩 \(outcome.fresh.items.count) 项｜\(CleanFormat.bytes(outcome.fresh.totalBytes))"
                )
            }
        }
    }

    private func apply(_ result: ScanResult) {
        items = result.items
        notes = result.notes
        // 判不出归属的共享 .tmp 不默认勾选，避免顺手删到别的 app 正在用的临时文件。
        selected = Set(result.items.filter { !$0.needsConfirm }.map(\.id))
        lastSummary = "\(result.items.count) 项｜\(CleanFormat.bytes(result.totalBytes))"
        lastScanDate = Date()
    }
}

struct CleanerRootView: View {
    @StateObject private var model = CleanerModel()

    private struct AppGroup: Identifiable {
        let name: String
        let items: [CleanItem]
        var bytes: Int64 { items.reduce(Int64(0)) { $0 + $1.bytes } }
        var id: String { name }
    }

    private var groups: [AppGroup] {
        let dict = Dictionary(grouping: model.items, by: { $0.appName })
        return dict.keys.sorted().map { AppGroup(name: $0, items: dict[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    environmentCard
                    categoryCard
                    actionCard
                    if !model.items.isEmpty || model.scanning {
                        listCard
                    }
                    if !model.notes.isEmpty {
                        notesCard
                    }
                    if !model.resultLines.isEmpty {
                        resultCard
                    }
                    safetyCard
                    Text("清理助手 0.4｜只清你写在 LiveContainer 里的 app，不碰 LiveContainer 和 SideStore 自己的文件")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 8)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("清理助手")
            .refreshable { model.scan() }
            .alert("确认删除这 \(model.selected.count) 项？", isPresented: $model.showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { model.deleteSelected() }
            } message: {
                Text("合计 \(CleanFormat.bytes(model.selectedBytes))。删除前会重新扫描并复核容器身份，刚被改过的文件会自动跳过；删掉的文件不进系统「最近删除」。")
            }
        }
        .tint(.orange)
    }

    // MARK: 环境

    private var environmentCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: model.env.insideLC ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.env.insideLC ? Color.green : Color.orange)
                    Text(model.env.insideLC ? "已找到 LiveContainer 主目录" : "没找到 LiveContainer 主目录")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                Text("白名单 \(CleanerDiscovery.apps.count) 个 app｜找到 \(model.env.containerCount) 个数据容器")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.env.insideLC {
                    Text("清理助手必须和被清理的 app 装在同一个 LiveContainer 里；它看不到别的 LiveContainer，也不会去碰 LiveContainer / SideStore 自己的目录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup("路径与环境说明") {
                    VStack(alignment: .leading, spacing: 8) {
                        labeledPath("LC 主目录", model.env.lcHome?.path ?? "—")
                        ForEach(model.env.dataRoots, id: \.path) { labeledPath("数据目录", $0.path) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("只认这些包名（完全相等）：").font(.caption2).foregroundStyle(.secondary)
                            Text(CleanerDiscovery.apps.map { "\($0.name)　\($0.bundleID)" }.joined(separator: "\n"))
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                        if !model.env.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(model.env.notes, id: \.self) { note in
                                    Text("• \(note)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labeledPath(_ label: String, _ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(path)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 范围

    private var categoryCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("清理范围").font(.headline)
                ForEach(CleanCategory.allCases) { cat in
                    Toggle(isOn: Binding(
                        get: { model.hasCategory(cat) },
                        set: { model.setCategory(cat, on: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cat.title).font(.subheadline.weight(.medium))
                            Text(cat.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(model.scanning || model.deleting)
                }
                if model.categories.contains(.history) {
                    Divider()
                    Text(model.historyDays == 0
                        ? "历史：不限天数，所有视频和旧记录都会列；鼾声最新 3 晚永远保留"
                        : "历史保留：只列 \(model.historyDays) 天以前的东西；鼾声最新 3 晚永远保留")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("不限天数（全部）", isOn: Binding(
                        get: { model.historyDays == 0 },
                        set: { model.setHistoryUnlimited($0) }
                    ))
                    .toggleStyle(.switch)
                    .disabled(model.scanning || model.deleting)
                    if model.historyDays != 0 {
                        HStack(spacing: 8) {
                            Text("只列")
                                .font(.caption)
                            TextField("天数", text: Binding(
                                get: { model.historyDaysText },
                                set: { model.setHistoryDaysText($0) }
                            ))
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 76)
                            .multilineTextAlignment(.center)
                            .disabled(model.scanning || model.deleting)
                            Text("天以前")
                                .font(.caption)
                            Button("应用") { model.applyHistoryDaysText() }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .disabled(model.scanning || model.deleting)
                            Spacer()
                        }
                        Text("天数自己填，想查多久填多久；填 0 或不限天数＝全部。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 动作与统计

    private var actionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        model.scan()
                    } label: {
                        Label(model.scanning ? "扫描中…" : "扫描", systemImage: "magnifyingglass")
                            .frame(minWidth: 72)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.scanning || model.deleting)

                    Button(role: .destructive) {
                        model.showDeleteConfirm = true
                    } label: {
                        Label(model.deleting ? "删除中…" : "删除勾选（\(model.selected.count)）", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.selected.isEmpty || model.scanning || model.deleting)

                    Spacer()
                }

                HStack {
                    Text(model.lastSummary).font(.footnote.monospacedDigit())
                    Spacer()
                    if let d = model.lastScanDate {
                        Text(CleanFormat.date(d))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    ForEach(CleanCategory.allCases) { cat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cat.title).font(.caption2).foregroundStyle(.secondary)
                            Text("\(model.count(cat)) 项｜\(CleanFormat.bytes(model.bytes(cat)))")
                                .font(.caption2.monospacedDigit())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                if !model.items.isEmpty {
                    HStack(spacing: 12) {
                        Button("全选") { model.selectAll() }
                        Button("全不选") { model.clearSelection() }
                        Spacer()
                        Text("勾选 \(model.selected.count) / \(model.items.count)｜\(CleanFormat.bytes(model.selectedBytes))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .disabled(model.scanning || model.deleting)
                }

                Divider()

                HStack(spacing: 10) {
                    Button {
                        model.sendReport()
                    } label: {
                        Label("发到电脑", systemImage: "paperplane")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.pcBusy || model.items.isEmpty)

                    Button {
                        model.fetchVerdict()
                    } label: {
                        Label("取回结论", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.pcBusy)

                    Spacer()
                }

                Text("只发清单（路径、大小、时间），不发文件内容。电脑上的结论只标在行上，不会自动删任何东西；要删还是你核对后按「删除勾选」。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !model.pcStatus.isEmpty {
                    Text(model.pcStatus)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !model.verdicts.isEmpty {
                    HStack(spacing: 10) {
                        Text("电脑结论\(model.verdictAt.isEmpty ? "" : "（\(model.verdictAt)）")：可删 \(model.recommendedCount) 项")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("按结论勾选") { model.selectRecommended() }
                            .font(.caption)
                            .disabled(model.recommendedCount == 0 || model.scanning || model.deleting)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 清单

    private var listCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("清单").font(.headline)
                    Spacer()
                    Text("点一行取消／重新勾选")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if model.items.isEmpty {
                    if model.scanning {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在扫描…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        ContentUnavailableView(
                            "没有发现可清理的东西",
                            systemImage: "checkmark.circle",
                            description: Text("当前勾选的范围里没有符合规则的项。")
                        )
                        .frame(minHeight: 120)
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(group.name).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("\(group.items.count) 项｜\(CleanFormat.bytes(group.bytes))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(group.items) { item in
                                    row(item)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ item: CleanItem) -> some View {
        Button {
            model.toggleSelection(item)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: model.isSelected(item) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.isSelected(item) ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(alignment: .top, spacing: 6) {
                        Text(item.category.title)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(Capsule())
                        if item.needsConfirm {
                            Text("需确认")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.18))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                        if let verdict = model.verdict(for: item) {
                            Text(verdict.kind.title)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(verdictColor(verdict.kind).opacity(0.16))
                                .foregroundStyle(verdictColor(verdict.kind))
                                .clipShape(Capsule())
                        }
                        Text(item.note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let verdict = model.verdict(for: item),
                       let reason = verdict.reason, !reason.isEmpty {
                        Text("电脑：\(reason)")
                            .font(.caption2)
                            .foregroundStyle(verdictColor(verdict.kind))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 4)
                Text(CleanFormat.bytes(item.bytes))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.deleting)
    }

    // MARK: 说明与回执

    private var notesCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("扫描说明").font(.headline)
                ForEach(model.notes, id: \.self) { note in
                    Text("• \(note)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var resultCard: some View {
        GroupBox {
            DisclosureGroup("删除回执（\(model.resultLines.count) 行）") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.resultLines.enumerated()), id: \.offset) { pair in
                        Text(pair.element)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func verdictColor(_ kind: CleanVerdictKind) -> Color {
        switch kind {
        case .keep: return .green
        case .delete: return .red
        case .unsure: return .orange
        }
    }

    private var safetyCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("安全边界", systemImage: "lock.shield")
                    .font(.headline)
                bullet("只认白名单里完全相等的包名：com.qoder.hellolc / snorebench / swapbench / vr3d / voice / liveswap。LiveContainer（com.kdt.*）和 SideStore / AltStore（com.SideStore.* / com.rileytestut.*）即使看起来是垃圾也不列、不删。")
                bullet("容器身份只认 LCContainerInfo.plist 的 appIdentifier；每次删除前重读一次，对不上就跳过。没有这个 plist 的容器不进清单。")
                bullet("符号链接一律跳过；1 小时内被改过的文件不动，历史文件按天数算。")
                bullet("LC 会把 <容器>/tmp 做成指向共享临时区的符号链接，这种目录只跳过、不跟随，避免同一批文件被扫两遍；只有 app 自己重建的真实 tmp 目录才逐个清。")
                bullet("共享临时区认 swap_ / vr3d_ / pick_ / cut_ / LiveIn 五个前缀，另外列顶层后缀 .tmp 的中断下载；都要求 6 小时内没有改动。名字里带 livecontainer / sidestore / altstore 的一律不列。")
                bullet("容器 Documents 和 Library/Caches 里散落的 .tmp 只删文件；voice_models、nights、samples、swap_idents 和 .mlpackage / .mlmodelc 内部不进去。")
                bullet("视频按后缀 .mov / .mp4 / .m4v / .avi / .mkv / .webm / .3gp / .mts / .ts 递归扫，改名、放子目录、落在真实 tmp 里都能列出来；开「不限天数」时不限天数。模型包、nights、voice_models、samples、swap_idents、Cookies、Preferences、SystemData、LCAppGroup、Inbox 不进去。")
                bullet("换脸只删非当前版本的模型包和编译缓存；fsx_arc / fsx_swap、version.txt、chain.txt、archive.part、swap_idents 和语音模型目录都保留，避免重复下载。")
                bullet("删除前会按同一套规则重新扫描，只有仍然在清单里的路径才会被删；删掉的文件不进系统「最近删除」。")
                bullet("「发到电脑」只发清单（路径、大小、时间），不发文件内容。电脑回的「保留／可删／待定」只标在行上，app 不会照着自动删；要删还是人核对后按「删除勾选」，删除时照样重扫和复核容器身份。")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").font(.caption)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
