import Combine
import CoreML
import PhotosUI
import SwiftUI
import UIKit

@main
struct SwapApp: App {
    init() {
        // AVFoundation 抛的是 Objective-C 异常，Swift 的 do/catch 抓不住，进程当场就没了，
        // 盘上只剩半截日志。这个钩子是唯一能在断气前把死因写进 swap_log.txt 的地方。
        NSSetUncaughtExceptionHandler { ex in
            SwapJournal.line("未捕获异常 \(ex.name.rawValue)｜\(ex.reason ?? "-")")
            for f in ex.callStackSymbols.prefix(8) { SwapJournal.line("  栈 \(f)") }
        }
    }

    var body: some Scene {
        WindowGroup {
            SwapContentView()
        }
    }
}

/// 预览往界面上递的那几样。引擎的回调只捕这一个类实例（它跟着 @StateObject 活一辈子），
/// 不捕 view 那个 struct 的副本——副本每刷新一帧就换一份，抓住旧的写 @State 就是空写。
final class SwapPreviewMirror: ObservableObject {
    @Published var img: UIImage?
    /// 只装「点了这一下」的一句话答案（被挡、停了、开跑）；处理过程的逐秒实况不再往这里递
    @Published var status = ""
    /// 这一趟的整份账：不在界面上摆，只喂「发到电脑」那一份正文
    var report = ""
    @Published var on = false
    @Published var pos = 0.0
    @Published var dur = 0.0
    @Published var person = ""
    /// 手指压在滑杆上的那一阵：位置引擎那一跳不许把 thumb 拽回去（不进 @Published，它不该引起重画）
    var dragging = false
    /// 模型下载/就位的那一句（0.33 起模型单独下到手机上，第一次用时那一下是几百 MB）
    @Published var modelText = ""
}

/// 选片、开始换脸这一摊的状态。界面上不摆处理过程流水（0.25 起按他令撤掉），
/// 跑起来的实况只落在磁盘流水里、由「发到电脑」整份交出去；后台线程不许直接碰 SwiftUI 的 @State。
struct SwapContentView: View {
    @State private var facts: [String] = []
    @State private var faceURL: URL?
    @State private var faceImg: UIImage?          // 选定时就读进来：tmp 副本当场还掉，重跑不必重选
    @State private var videoURL: URL?
    @State private var picking: String = ""          // "face" / "video"：谁的选片器开着
    @State private var running = false
    @State private var unitIdx = 0                   // 默认 units[0] = cpuOnly
    @State private var longIdx = 0                   // 默认 1920（长边上限）
    @State private var beautyIdx = 1                 // 0＝美白开，1＝关；10-22 起默认关（他肉眼判：关比开好）
    @State private var result = ""
    @State private var outURL: URL?

    @State private var idents: [SwapIdents.Item] = []
    @State private var chosenIdent: String = ""      // 已存的人：非空就跳过身份证＋身份包那两步
    @State private var identNote = ""
    @State private var renaming = false
    @State private var renameId = ""
    @State private var renameText = ""
    @State private var deleting = false
    @State private var delId = ""
    @State private var delName = ""

    @State private var sendStatus = ""
    @State private var sending = false
    @State private var modelBusy = false

    /// 预览那一格界面上看到的东西
    @StateObject private var pv = SwapPreviewMirror()
    /// 整台手机同时只跑一路预览，挂在类型上：挂在 struct 上每刷一次界面就换一个实例（新的那条队列白建）
    private static let engine = SwapPreview()

    static let units: [(String, MLComputeUnits)] = [
        ("CPU(cpuOnly)", .cpuOnly),
        ("GPU(cpuAndGPU)", .cpuAndGPU),
        ("all", .all),
        ("ANE(cpuAndNeuralEngine)", .cpuAndNeuralEngine),
    ]
    static let longs = [1920, 1280, 960, 640]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("环境").font(.headline)
                    ForEach(facts, id: \.self) { Text($0).font(.caption) }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("模型").font(.headline)
                        Text("先从同一张网上的电脑拿模型（手机直连 GitHub 慢得离谱），"
                             + "第一次会问「允许访问本地网络」，点允许。电脑不在就走 GitHub 那条。")
                            .font(.caption2)
                        Text("改了程序不用重下模型；模型换了才重下。")
                            .font(.caption2)
                        Button(modelBusy ? "下模型跑着…" : (SwapStore.haveAll() ? "查模型版本" : "下模型")) { downloadModels() }
                            .buttonStyle(.bordered)
                            .disabled(modelBusy || running)
                        Text(pv.modelText.isEmpty ? SwapStore.statusLine() : pv.modelText)
                            .font(.caption)
                            .textSelection(.enabled)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("已存的人").font(.headline)
                        Text("一人一份身份；点名字选中，跑片时跳过算身份那两步。")
                            .font(.caption2)
                        if idents.isEmpty {
                            Text("（列表空着。①选一张源脸照片跑一次，跑的时候自动存进来）").font(.caption)
                        }
                        ForEach(idents, id: \.id) { it in
                            HStack(spacing: 6) {
                                Button((chosenIdent == it.id ? "◉ " : "○ ") + it.name) { pickIdent(it) }
                                    .buttonStyle(.borderless)
                                    .disabled(running)
                                Text(String(format: "%.2f MB", Double(it.bytes) / 1_048_576))
                                    .font(.caption2)
                                Spacer(minLength: 4)
                                Button("改名") { startRename(it) }
                                    .buttonStyle(.borderless)
                                    .disabled(running)
                                Button("删") { startDelete(it) }
                                    .buttonStyle(.borderless)
                                    .disabled(running)
                            }
                            .font(.caption)
                        }
                        if !identNote.isEmpty { Text(identNote).font(.caption).textSelection(.enabled) }
                    }
                    .alert("改名", isPresented: $renaming) {
                        TextField("名字", text: $renameText)
                        Button("存") { commitRename() }
                        Button("取消", role: .cancel) { renameId = "" }
                    }
                    .alert("删掉「\(delName)」？", isPresented: $deleting) {
                        Button("删", role: .destructive) { commitDelete() }
                        Button("留着", role: .cancel) { delId = "" }
                    } message: {
                        Text("删了就只能重挑那张照片再算一次身份。")
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("整片换脸").font(.headline)
                        Button(faceURL == nil ? "① 选一张源脸照片" : "① 源脸：\(faceURL!.lastPathComponent)（点它换一张）") {
                            picking = "face"
                        }
                        .buttonStyle(.bordered)
                        .disabled(running)
                        Text(sourceLine).font(.caption)
                        Button(videoURL == nil ? "② 选一条要换脸的视频" : "② 视频：\(videoURL!.lastPathComponent)（点它换一条）") {
                            picking = "video"
                        }
                        .buttonStyle(.bordered)
                        .disabled(running)

                        Picker("算力单元", selection: $unitIdx) {
                            ForEach(0 ..< Self.units.count, id: \.self) { i in
                                Text(Self.units[i].0).tag(i)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(running || pv.on)
                        Picker("长边上限", selection: $longIdx) {
                            ForEach(0 ..< Self.longs.count, id: \.self) { i in
                                Text("\(Self.longs[i]) px").tag(i)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(running)
                        Picker("补丁美白", selection: $beautyIdx) {
                            Text("开").tag(0)
                            Text("关").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .disabled(running)
                        Text("默认关。开＝在补丁上做一档提亮。")
                            .font(.caption2)

                        // 点下去立刻置灰 + 改文案：界面上没有流水，这一下的反馈就在按钮自己身上
                        Button(running ? "换脸跑着…（跑完这里给一句话）" : "开始换脸") {
                            startSwap()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || !hasSource || videoURL == nil)

                        if !result.isEmpty {
                            Text(result).font(.caption).textSelection(.enabled)
                        }
                        if let o = outURL {
                            Button("成片留在沙盒：\(o.lastPathComponent)（点开路径）") {
                                result = o.path
                            }
                            .buttonStyle(.bordered)
                        }
                        Button(sending ? "发送中…" : "发到电脑") { sendReport() }
                            .buttonStyle(.bordered)
                            .disabled(sending)
                        if !sendStatus.isEmpty { Text(sendStatus).font(.caption) }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("换脸预览（只看、不导出、手机侧一个字节都不写）").font(.headline)

                        // 这一格约手机屏 1/3 高：逐个「已存的人」贴进来就是在这里比谁像
                        ZStack {
                            Color(white: 0.10)
                            if let im = pv.img {
                                Image(uiImage: im).resizable().scaledToFit()
                            } else {
                                Text(pv.on ? "开跑了，第一格要等四张网装好" : "（还没开）")
                                    .font(.caption).foregroundColor(.gray)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 190, maxHeight: 300)
                        .clipped()

                        Text("换一个人：点名字选中，然后点下面的「开始预览」。预览跑着时这里改不动，要换人先「停预览」。").font(.caption)
                        if idents.isEmpty {
                            Text("（列表空着：预览只吃「已存的人」，先用上面①②跑一次整片换脸存下一个人）")
                                .font(.caption2)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(idents, id: \.id) { it in
                                    Button((chosenIdent == it.id ? "◉ " : "○ ") + it.name) { pickIdent(it) }
                                        .buttonStyle(.bordered)
                                        .disabled(pv.on || running)
                                }
                            }
                        }
                        if pv.on && !pv.person.isEmpty {
                            Text("画面里现在的人：「\(SwapIdents.displayName(pv.person))」（这一趟就是他，不换）")
                                .font(.caption)
                        }

                        HStack(spacing: 6) {
                            Text("位置").font(.caption)
                            Slider(value: $pv.pos, in: 0 ... max(0.1, pv.dur), onEditingChanged: { began in
                                pv.dragging = began
                                if !began { seekPreview(pv.pos) }
                            })
                            .disabled(!pv.on)
                            Text(String(format: "共 %.0f s", pv.dur)).font(.caption)
                        }
                        .font(.caption)

                        Button(pv.on ? "停预览" : "开始预览") { togglePreview() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!pv.on && !previewBlock.isEmpty)
                        if !previewBlock.isEmpty { Text(previewBlock).font(.caption2) }
                        // 只递这一下点出来的那句答案（被挡／开了／停了）；跑动中的逐秒实况不再上界面
                        if !pv.status.isEmpty { Text(pv.status).font(.caption).textSelection(.enabled) }
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("换脸出片")
            .onAppear {
                facts = SwapFacts.lines()
                idents = SwapIdents.list()
                let mirror = pv
                let eng = SwapContentView.engine
                eng.render = { img in mirror.img = img }
                eng.onShow = { s in mirror.status = s }
                eng.log = { line in
                    SwapJournal.line(line)
                    if line.hasPrefix("模型") {
                        DispatchQueue.main.async { mirror.modelText = line }
                    }
                }
                eng.onProgress = { s, d in
                    mirror.dur = d
                    if !mirror.dragging { mirror.pos = s }
                }
                eng.onPerson = { pid in mirror.person = pid }
                eng.onFinish = { txt, d in
                    mirror.on = false
                    mirror.dragging = false
                    mirror.dur = d
                    mirror.report = txt
                }
            }
            // cover 不收场就整屏卡在选择页，必须自己关
            .fullScreenCover(isPresented: Binding(get: { picking == "face" },
                                                  set: { if !$0 { picking = "" } })) {
                SwapPickerHost(kind: .image) { url, err in
                    picking = ""
                    if let u = url {
                        // 当场读进内存再还掉 tmp 那份：一不留残料，二不让开跑时的清扫把正在用的输入吃掉
                        let img = UIImage(contentsOfFile: u.path)
                        if FileManager.default.fileExists(atPath: u.path) { try? FileManager.default.removeItem(at: u) }
                        faceImg = img
                        faceURL = img == nil ? nil : u
                        if img != nil {
                            chosenIdent = ""
                            identNote = "这一趟用刚选的这张照片的身份（跑完自动存进「已存的人」）"
                        }
                        SwapJournal.line("选了源脸 \(u.lastPathComponent)｜"
                            + (img == nil ? "这张照片读不进来，重选" : "已读进内存，tmp 副本当场还掉"))
                    } else {
                        SwapJournal.line("选源脸没成：\(err ?? "-")")
                        result = "选源脸没成：\(err ?? "-")"
                    }
                }
            }
            .fullScreenCover(isPresented: Binding(get: { picking == "video" },
                                                  set: { if !$0 { picking = "" } })) {
                SwapPickerHost(kind: .video) { url, err in
                    picking = ""
                    if let u = url {
                        let reclaimed = reclaimOldPicks(keep: u)
                        videoURL = u
                        SwapJournal.line("选了视频 \(u.lastPathComponent)"
                            + (reclaimed > 0 ? "｜顺手还掉旧选片 \(String(format: "%.1f", Double(reclaimed) / 1_048_576)) MB" : ""))
                    } else {
                        SwapJournal.line("选视频没成：\(err ?? "-")")
                        result = "选视频没成：\(err ?? "-")"
                    }
                }
            }
        }
    }

    /// 只认自己那批前缀：选片副本一条比一条大，预览又不走出片那条的清扫，
    /// 不在这里还就一直在 tmp 里堆着。半成品（swap_时间戳.mp4）仍归出片那一趟自己清。
    private func reclaimOldPicks(keep: URL) -> Int {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        var bytes = 0
        for one in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [])) ?? [] {
            guard one.lastPathComponent.hasPrefix("swap_video_") else { continue }
            guard one.lastPathComponent != keep.lastPathComponent else { continue }
            let sz = (try? one.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if (try? fm.removeItem(at: one)) != nil { bytes += sz }
        }
        return bytes
    }

    private func startSwap() {
        let person: SwapClip.Person
        if !chosenIdent.isEmpty {
            person = .saved(chosenIdent)
        } else if let img = faceImg {
            person = .photo(img)
        } else {
            result = "源身份没在手上了：在「已存的人」里点一个，或者①重选一张源脸照片"
            return
        }
        guard let v = videoURL else {
            result = "②还没选要换脸的视频"
            return
        }
        // 上一趟跑完已经把那份拷贝还掉了，按钮下面留着的 URL 指向一个没了的文件：
        // 直接再点开始只会在几秒后报「源 没有视频轨」（上机实测三次，全是他重按那一下）
        if !FileManager.default.fileExists(atPath: v.path) {
            videoURL = nil
            result = "②那份视频副本上一趟已经还掉了，重新点②选一条"
            SwapJournal.line("开始被挡：\(v.lastPathComponent) 这份副本不在了，要重新选")
            return
        }
        running = true
        result = ""
        outURL = nil
        let units = Self.units[unitIdx].1
        let longEdge = Self.longs[longIdx]
        let beautyTxt = beautyIdx == 0 ? "开" : "关"
        if SwapContentView.engine.isActive {
            SwapJournal.line("开始整片换脸：预览还开着，先叫停它并把四张网交出来（两条同跑＝两份足迹＋互相抢 CPU）")
        }
        SwapJournal.line("开始整片换脸 units=\(Self.units[unitIdx].0) 长边=\(longEdge) 美白=\(beautyTxt) 源=\(sourceTag) 片=\(v.lastPathComponent)")
        var args = SwapClip.Args()
        args.units = units
        args.longEdge = longEdge
        args.whiten = beautyIdx == 0
        Task.detached {
            // 预览还开着就先叫停，并等它把四张网＋两块整幅缓冲交出来再装自己这一份
            SwapContentView.engine.stop()
            var waited = 0.0
            while SwapContentView.engine.isActive && waited < 5.0 {
                Thread.sleep(forTimeInterval: 0.2)
                waited += 0.2
            }
            if waited > 0 {
                SwapJournal.line(String(format: "预览交还网络用了 %.1f s", waited))
            }
            let r = SwapClip.run(person: person, video: v, args: args) { line in
                SwapJournal.line(line)
                // 模型下载的进度往界面上递一句：0.33 起模型不在包里，第一次跑要先下几百 MB，
                // 不递的话界面上只有「换脸跑着…」，看着像卡死
                if line.hasPrefix("模型") {
                    DispatchQueue.main.async { pv.modelText = line }
                }
            }
            // 视频那份拷贝是输入，跑完就该还掉：手机存储不许留残料（源脸那份选定时就还了）
            if !FileManager.default.fileExists(atPath: v.path) {
                SwapJournal.line("视频副本早没了 \(v.lastPathComponent)")
            } else if (try? FileManager.default.removeItem(at: v)) == nil {
                SwapJournal.line("视频副本没删掉 \(v.lastPathComponent)")
            }
            DispatchQueue.main.async {
                outURL = r.out
                // 整份账只进「发到电脑」的正文；界面上成了一句、没成把 fail 那一句（账的最后一行）递上来
                result = r.out != nil ? "换脸跑完，成片在沙盒"
                    : (r.note.split(separator: "\n").last.map(String.init) ?? "换脸没成")
                running = false
                videoURL = nil
                facts = SwapFacts.lines()
                idents = SwapIdents.list()
            }
        }
    }

    // MARK: - 已存的人

    /// 这一趟的源身份是谁：界面贴在 ① 下面，日志里同一句话进流水。
    private var sourceLine: String {
        if !chosenIdent.isEmpty { return "源身份：已存的人「\(SwapIdents.displayName(chosenIdent))」，跑的时候跳过身份证＋身份包" }
        if faceImg != nil { return "源身份：刚选的这张照片，要跑身份证＋身份包那两步" }
        return "源身份：还没定——在「已存的人」里点一个，或①选一张源脸照片"
    }

    private var hasSource: Bool { !chosenIdent.isEmpty || faceImg != nil }

    private var sourceTag: String {
        chosenIdent.isEmpty ? (faceURL?.lastPathComponent ?? "-") : "已存「\(SwapIdents.displayName(chosenIdent))」"
    }

    private func pickIdent(_ it: SwapIdents.Item) {
        chosenIdent = it.id
        faceImg = nil
        faceURL = nil
        identNote = "选中「\(it.name)」：这一趟不用照片，身份直接从盘上装"
        SwapJournal.line(identNote)
    }

    private func startRename(_ it: SwapIdents.Item) {
        renameId = it.id
        renameText = it.name
        renaming = true
    }

    private func commitRename() {
        renaming = false
        guard !renameId.isEmpty else { return }
        identNote = SwapIdents.rename(id: renameId, to: renameText)
        SwapJournal.line("改名：\(identNote)")
        renameId = ""
        idents = SwapIdents.list()
    }

    private func startDelete(_ it: SwapIdents.Item) {
        delId = it.id
        delName = it.name
        deleting = true
    }

    private func commitDelete() {
        deleting = false
        guard !delId.isEmpty else { return }
        identNote = SwapIdents.remove(id: delId)
        SwapJournal.line("删已存的人：\(identNote)")
        if chosenIdent == delId { chosenIdent = "" }
        delId = ""
        idents = SwapIdents.list()
    }

    // MARK: - 预览

    /// 「开始预览」点不下去时，原因就写在按钮旁边
    private var previewBlock: String {
        if running { return "整片换脸正跑着：这一版预览不和它抢 CPU，先等它收尾" }
        if videoURL == nil { return "还没点②选要预览的视频（预览吃的就是②那一条）" }
        if chosenIdent.isEmpty { return "预览只吃「已存的人」：先在「已存的人」里点一个名字" }
        if !FileManager.default.fileExists(atPath: videoURL?.path ?? "") {
            return "②那份副本上一趟已经还掉了，重新点②选一条"
        }
        return ""
    }

    private func togglePreview() {
        let eng = SwapContentView.engine
        if pv.on {
            SwapJournal.line("预览 点了停预览")
            eng.stop()
            pv.status = "停预览点了：这一格收尾就停"
            return
        }
        guard !running else { return }
        guard let v = videoURL else { return }
        guard !chosenIdent.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: v.path) else {
            videoURL = nil
            pv.status = "②那份副本上一趟已经还掉了，重新点②选一条"
            SwapJournal.line("预览 开始被挡：\(v.lastPathComponent) 这份副本不在了，要重新选")
            return
        }
        var c = SwapPreview.Cfg()
        c.units = Self.units[unitIdx].1
        c.unitsTxt = Self.units[unitIdx].0
        c.whiten = beautyIdx == 0
        let reject = eng.start(video: v, personId: chosenIdent, cfg: c)
        if !reject.isEmpty {
            pv.status = reject
            SwapJournal.line("预览 开始被挡：\(reject)")
            return
        }
        let whitenTxt = c.whiten ? "开" : "关"
        pv.on = true
        pv.img = nil
        pv.report = ""
        pv.pos = 0
        pv.dur = 0
        pv.person = ""
        pv.status = "预览开跑：先把四张网装好，第一格还要等它检测到位"
        SwapJournal.line("开始预览 units=\(c.unitsTxt) 美白=\(whitenTxt) "
            + "人=\(SwapIdents.displayName(chosenIdent)) 片=\(v.lastPathComponent)")
    }

    private func seekPreview(_ sec: Double) {
        guard pv.on else { return }
        SwapJournal.line(String(format: "预览 拖到 %.2f s（重开 reader 跳过去，预览不缓存画面）", sec))
        SwapContentView.engine.seek(sec)
    }

    /// 下模型：四张网合成一个 models.bin 挂在 release 上，下完 sha256 对得上才解包。
    /// 下到 Documents/swap_models —— 程序随便换，这一份原封不动。
    private func downloadModels() {
        modelBusy = true
        pv.modelText = "下模型跑着…"
        SwapJournal.line("开始下模型")
        Task.detached {
            let g = SwapStore.ensure(force: true) { line in
                SwapJournal.line(line)
                DispatchQueue.main.async { pv.modelText = line }
            }
            SwapJournal.line("下模型 " + g.note)
            DispatchQueue.main.async {
                pv.modelText = g.note
                modelBusy = false
                facts = SwapFacts.lines()
            }
        }
    }

    private func sendReport() {
        sending = true
        sendStatus = "发着…"
        let facts = SwapFacts.lines().joined(separator: "\n")
        let clip = result.isEmpty ? "（整片换脸还没跑过——先点「开始换脸」）" : result
        let prev = pv.report.isEmpty ? "（预览还没跑过——先点「开始预览」）" : pv.report
        let text = "—— 环境 ——\n" + facts
            + "\n\n—— 整片换脸 ——\n" + clip
            + "\n\n—— 预览 ——\n" + prev
            + "\n\n—— 流水 ——\n" + SwapJournal.tail(200)
            + "\n\n—— 每趟判决（不滚动，一条片子冲不掉）——\n" + SwapJournal.runs(160)
        Task.detached {
            let r = SwapUploader.send(text)
            SwapJournal.line("发到电脑：\(r)")
            DispatchQueue.main.async {
                sendStatus = r
                sending = false
            }
        }
    }
}

enum SwapPickKind { case image, video }

/// PHPicker 只给 itemProvider，文件在系统自己的临时目录里、回调一返回就被收走，
/// 所以先按自己的前缀拷进容器 tmp（跑完由上面那段还掉）。
struct SwapPickerHost: UIViewControllerRepresentable {
    let kind: SwapPickKind
    let onDone: (URL?, String?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = kind == .video ? .videos : .images
        let p = PHPickerViewController(configuration: config)
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(kind, onDone) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let kind: SwapPickKind
        let onDone: (URL?, String?) -> Void

        init(_ kind: SwapPickKind, _ onDone: @escaping (URL?, String?) -> Void) {
            self.kind = kind
            self.onDone = onDone
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let cb = onDone
            guard let provider = results.first?.itemProvider else {
                Task { @MainActor in cb(nil, "没选到文件") }
                return
            }
            let typeID = kind == .video ? "public.movie" : "public.image"
            let prefix = kind == .video ? "swap_video_" : "swap_face_"
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { file, error in
                guard let file = file else {
                    let m = "loadFileRepresentation 返回空: \(error?.localizedDescription ?? "-")"
                    Task { @MainActor in cb(nil, m) }
                    return
                }
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent(prefix + String(UUID().uuidString.prefix(8)))
                    .appendingPathExtension(file.pathExtension)
                do {
                    if FileManager.default.fileExists(atPath: dst.path) {
                        try FileManager.default.removeItem(at: dst)
                    }
                    try FileManager.default.copyItem(at: file, to: dst)
                    Task { @MainActor in cb(dst, nil) }
                } catch {
                    Task { @MainActor in cb(nil, "拷贝到临时目录失败: \(error)") }
                }
            }
        }
    }
}
