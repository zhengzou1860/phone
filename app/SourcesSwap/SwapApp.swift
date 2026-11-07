import Combine
import CoreML
import PhotosUI
import SwiftUI
import UIKit

@main
struct SwapApp: App {
    @UIApplicationDelegateAdaptor(SwapAppDelegate.self) private var delegate

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

/// 横屏只借给全屏预览那一阵，其余时候整台机器仍钉在竖屏。
/// plist 那一张表管「系统允许哪些方向」（不列横屏就 requestGeometryUpdate 转不过去），
/// 这一句管「此刻要哪个」——两边都得点头，屏幕才真的转。
final class SwapAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        SwapRotate.landscape ? .landscapeRight : .portrait
    }
}

enum SwapRotate {
    static var landscape = false

    /// 进全屏叫一次（true）、出全屏叫一次（false）。不缓存「已经转过了」：cover 刚挂上那一下请求常被系统按旧口径拒掉，
    /// 于是 onAppear 再叫一次，第二次落在新界面上——被拒那一次会留在流水里，看得到到底是哪一步没转。
    static func apply(_ want: Bool) {
        landscape = want
        guard let s = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            SwapJournal.line("全屏 没找到在前台的窗口场景：方向没改")
            return
        }
        s.requestGeometryUpdate(.iOS(interfaceOrientations: want ? .landscapeRight : .portrait)) { err in
            SwapJournal.line("全屏 方向请求被拒：\(err.localizedDescription)")
        }
        s.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
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

/// 目标表的一位：视频里要找的那张脸（照片算出来的身份）＋ 要换成的那张脸（已存的人或一张源脸照片）。
struct SwapCastSlot {
    var targetImg: UIImage?
    var targetFile = ""
    var targetEmb: [Float] = []
    var targetSide = 0.0
    var targetNote = ""
    var sourceId = ""
    var sourceName = ""
    var sourceEmb: [Float] = []
    var sourceNote = ""

    var used: Bool { targetImg != nil || !targetEmb.isEmpty || !sourceEmb.isEmpty }
}

/// 选片、开始换脸这一摊的状态。界面上不摆处理过程流水（0.25 起按他令撤掉），
/// 跑起来的实况只落在磁盘流水里、由「发到电脑」整份交出去；后台线程不许直接碰 SwiftUI 的 @State。
struct SwapContentView: View {
    @State private var facts: [String] = []
    @State private var videoURL: URL?
    @State private var picking: String = ""          // "target" / "replace" / "video"：谁的选片器开着
    @State private var pickSlot = 0                  // 选片器回来落到目标表哪一位
    @State private var running = false
    @State private var unitIdx = 0                   // 默认 units[0] = cpuOnly：0.39 上机四档实测
                                                     // CPU 890／GPU 1043／all 1045／ANE 815（每档 5 格均速），
                                                     // all 那一格跟 GPU 一模一样＝CoreML 自己挑的是 GPU，比纯 CPU 还慢 18 %，
                                                     // 而且两份网的足迹要到 854 MB；CPU 那一档全程 44 MB。
                                                     // ANE 只快 8 %，而它内部按 fp16 摆，赔多少精度等量速那一句「离 CPU 那一份几灰阶」说了再定。
    @State private var longIdx = 0                   // 默认 1920（长边上限）
    @State private var result = ""
    @State private var outURL: URL?
    /// 一按量四档算力：这一趟几十秒（每档重新装一次两张网），只在后台跑，最后一句留在界面上
    @State private var benchBusy = false
    @State private var benchText = ""

    @State private var idents: [SwapIdents.Item] = []
    @State private var identNote = ""
    @State private var renaming = false
    @State private var renameId = ""
    @State private var renameText = ""
    @State private var deleting = false
    @State private var delId = ""
    @State private var delName = ""

    /// 目标表 1–3 位。逐个上传、逐个认脸、逐个配替换脸；预览和整片都按这张表跑
    @State private var slots: [SwapCastSlot] = [SwapCastSlot(), SwapCastSlot(), SwapCastSlot()]
    @State private var castBusy = false              // 正在给某一张照片算特征
    @State private var castText = ""

    @State private var sendStatus = ""
    @State private var sending = false
    @State private var modelBusy = false

    /// 预览那一格界面上看到的东西
    @StateObject private var pv = SwapPreviewMirror()
    /// 全屏横屏那一档开着没有（开着一趟只借横屏这一阵，退出就还回竖屏）
    @State private var pvFull = false
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
                        Text("改了程序不用重下模型；模型换了才重下。盘上齐着时这个按钮只核对版本，不搬字节。")
                            .font(.caption2)
                        Button(modelBusy ? "核对中…" : (SwapStore.haveAll() ? "核对模型版本（不重下）" : "下模型")) { downloadModels() }
                            .buttonStyle(.bordered)
                            .disabled(modelBusy || running || pv.on || castBusy)
                        Text(pv.modelText.isEmpty ? SwapStore.statusLine() : pv.modelText)
                            .font(.caption)
                            .textSelection(.enabled)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("已存的人（替换脸库）").font(.headline)
                        Text("一人一份身份。目标表里每一张目标脸都可以从这里点一个当替换脸；"
                             + "也可以临时选一张源脸照片，选完自动存进来。")
                            .font(.caption2)
                        if idents.isEmpty {
                            Text("（列表空着。在目标表里上传目标照后，选一张源脸照片当替换脸就会存进来）").font(.caption)
                        }
                        ForEach(idents, id: \.id) { it in
                            HStack(spacing: 6) {
                                Text(it.name)
                                Text(it.bytes >= 1_048_576
                                    ? String(format: "%.2f MB", Double(it.bytes) / 1_048_576)
                                    : String(format: "%.1f KB", Double(it.bytes) / 1024))
                                    .font(.caption2)
                                Spacer(minLength: 4)
                                Button("改名") { startRename(it) }
                                    .buttonStyle(.borderless)
                                    .disabled(castLocked)
                                Button("删") { startDelete(it) }
                                    .buttonStyle(.borderless)
                                    .disabled(castLocked)
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
                        Text("删了就只能重挑那张照片再算一次身份；目标表里用到它的那一位要重新选。")
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("多人换脸（目标表 1–3 张）").font(.headline)
                        Text("逐张上传视频里的目标人脸：上传 → 认到那张脸 → 给它选替换脸（已存的人或一张源脸照片）。"
                             + "视频里认到哪张目标脸，就换上它对应的替换脸；没认到的不动。")
                            .font(.caption2)
                        if !castText.isEmpty {
                            Text(castText).font(.caption).textSelection(.enabled)
                        }

                        ForEach(0 ..< 3, id: \.self) { i in slotCard(i) }

                        Text("特征表（预览跑着时锁住；停了就能改）").font(.headline)
                        ForEach(0 ..< 3, id: \.self) { i in
                            if slots[i].used {
                                Text(featureRow(i)).font(.caption).textSelection(.enabled)
                            }
                        }
                        let plan = castPlan
                        if !plan.problem.isEmpty {
                            Text(plan.problem).font(.caption2).foregroundColor(.orange)
                        }

                        Button(videoURL == nil ? "② 选一条要换脸的视频（整片和预览共用）"
                                               : "② 视频：\(videoURL!.lastPathComponent)（点它换一条）") {
                            picking = "video"
                        }
                        .buttonStyle(.bordered)
                        .disabled(castLocked)

                        Picker("算力单元", selection: $unitIdx) {
                            ForEach(0 ..< Self.units.count, id: \.self) { i in
                                Text(Self.units[i].0).tag(i)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(castLocked)
                        Picker("长边上限", selection: $longIdx) {
                            ForEach(0 ..< Self.longs.count, id: \.self) { i in
                                Text("\(Self.longs[i]) px").tag(i)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(castLocked)

                        // 量速不动开始换脸那一步：只把上面那格「算力单元」该点哪一个量出来。
                        // 0.38 上机每帧 1230 ms，钱全在换脸网一次前向，四档各装各跑一遍才知道
                        // CoreML 在 A13 上给这一档挑的是哪块硬件。
                        Button(benchBusy ? "量四档算力跑着…（一行一行出数，几十秒）" : "量一下这四档算力（几十秒，不换脸）") {
                            startBench()
                        }
                        .buttonStyle(.bordered)
                        .disabled(castLocked || benchBusy)
                        if !benchText.isEmpty {
                            Text(benchText).font(.caption).textSelection(.enabled)
                        }

                        // 点下去立刻置灰 + 改文案：界面上没有流水，这一下的反馈就在按钮自己身上
                        Button(running ? "换脸跑着…（跑完这里给一句话）" : "开始整片换脸") {
                            startSwap()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || !castReady || videoURL == nil || castBusy)

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

                        // 这一格约手机屏 1/3 高：目标表里有几张脸，就在这一格里逐个换成各自的替换脸
                        ZStack {
                            Color(white: 0.10)
                            if let im = pv.img {
                                Image(uiImage: im).resizable().scaledToFit()
                            } else {
                                Text(pv.on ? "开跑了，第一格要等两张网装好" : "（还没开）")
                                    .font(.caption).foregroundColor(.gray)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 190, maxHeight: 300)
                        .clipped()

                        Text("预览吃的就是上面那张目标表。要改表先「停预览」，改完再开。").font(.caption)
                        if pv.on && !pv.person.isEmpty {
                            Text("这一趟目标表：\(pv.person)").font(.caption)
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
                        Button("全屏横屏（带声音）") { pvFull = true }
                            .buttonStyle(.bordered)
                        if !previewBlock.isEmpty { Text(previewBlock).font(.caption2) }
                        // 只递这一下点出来的那句答案（被挡／开了／停了）；跑动中的逐秒实况不再上界面
                        if !pv.status.isEmpty { Text(pv.status).font(.caption).textSelection(.enabled) }
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("换脸出片")
            // 全屏预览这一档：开的时候借横屏，关的时候还回竖屏（方向由 SwapRotate 那一句口径说了算）
            .fullScreenCover(isPresented: $pvFull) {
                SwapPreviewFull(pv: pv, block: previewBlock,
                                onToggle: { togglePreview() },
                                onSeek: { seekPreview($0) },
                                onClose: { pvFull = false })
            }
            .onChange(of: pvFull) { _, on in SwapRotate.apply(on) }
            .onAppear {
                facts = SwapFacts.lines()
                idents = SwapIdents.list()
                let mirror = pv
                let eng = SwapContentView.engine
                eng.render = { img in mirror.img = img }
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
                eng.onPerson = { label in mirror.person = label }
                eng.onFinish = { txt, d in
                    mirror.on = false
                    mirror.dragging = false
                    mirror.dur = d
                    mirror.report = txt
                }
            }
            // cover 不收场就整屏卡在选择页，必须自己关
            .fullScreenCover(isPresented: Binding(get: { picking == "target" },
                                                  set: { if !$0 { picking = "" } })) {
                SwapPickerHost(kind: .image) { url, err in
                    let who = pickSlot
                    picking = ""
                    guard let u = url else {
                        result = "选目标图没成：\(err ?? "-")"
                        SwapJournal.line("选目标\(who + 1)图片没成：\(err ?? "-")")
                        return
                    }
                    // 当场读进内存再还掉 tmp 那份：一不留残料，二不让开跑时的清扫把正在用的输入吃掉
                    let img = UIImage(contentsOfFile: u.path)
                    if FileManager.default.fileExists(atPath: u.path) { try? FileManager.default.removeItem(at: u) }
                    guard let img = img else {
                        result = "这张目标图读不进来，重选"
                        return
                    }
                    ingestTarget(who, img: img, file: u.lastPathComponent)
                }
            }
            .fullScreenCover(isPresented: Binding(get: { picking == "replace" },
                                                  set: { if !$0 { picking = "" } })) {
                SwapPickerHost(kind: .image) { url, err in
                    let who = pickSlot
                    picking = ""
                    guard let u = url else {
                        result = "选替换脸没成：\(err ?? "-")"
                        SwapJournal.line("选目标\(who + 1) 的替换脸没成：\(err ?? "-")")
                        return
                    }
                    let img = UIImage(contentsOfFile: u.path)
                    if FileManager.default.fileExists(atPath: u.path) { try? FileManager.default.removeItem(at: u) }
                    guard let img = img else {
                        result = "这张替换脸读不进来，重选"
                        return
                    }
                    ingestReplacement(who, img: img)
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

    // MARK: - 目标表

    /// 预览／整片／算特征／量速任何一项跑着，这张表都不许改
    private var castLocked: Bool { running || pv.on || castBusy || benchBusy }

    @ViewBuilder
    private func slotCard(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(slots[i].targetEmb.isEmpty
                       ? "上传目标人脸\(i + 1)图片"
                       : "目标\(i + 1)：\(slots[i].targetFile)（点它换一张）") {
                    pickSlot = i
                    picking = "target"
                }
                .buttonStyle(.bordered)
                .disabled(castLocked)
                if slots[i].used {
                    Button("清空") { clearSlot(i) }
                        .buttonStyle(.borderless)
                        .disabled(castLocked)
                }
            }
            Text(slots[i].targetNote.isEmpty
                 ? "还没上传：选一张视频里那个人的正脸照（一个人一张）"
                 : slots[i].targetNote)
                .font(.caption2)

            if !slots[i].targetEmb.isEmpty {
                Text("替换脸：\(slots[i].sourceName.isEmpty ? "还没选（点下面）" : "「\(slots[i].sourceName)」")")
                    .font(.caption)
                if !idents.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(idents, id: \.id) { it in
                                Button((slots[i].sourceId == it.id ? "◉ " : "○ ") + it.name) {
                                    chooseReplacement(slot: i, ident: it)
                                }
                                .buttonStyle(.bordered)
                                .disabled(castLocked)
                            }
                        }
                    }
                }
                Button("或选一张源脸照片当替换脸") {
                    pickSlot = i
                    picking = "replace"
                }
                .buttonStyle(.bordered)
                .disabled(castLocked)
                if !slots[i].sourceNote.isEmpty {
                    Text(slots[i].sourceNote).font(.caption2)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.12))
        .cornerRadius(8)
    }

    /// 特征表的一行：目标特征多少维／模长，替换的是谁、多少维／模长
    private func featureRow(_ i: Int) -> String {
        let s = slots[i]
        var parts = ["目标\(i + 1)"]
        if s.targetEmb.isEmpty {
            parts.append("目标特征：还没有（没认到脸）")
        } else {
            parts.append("目标特征 \(s.targetEmb.count) 维·模长 "
                + String(format: "%.2f", FsxEngine.norm(s.targetEmb))
                + "（脸短边 \(String(format: "%.0f", s.targetSide)) px）")
        }
        if s.sourceEmb.isEmpty {
            parts.append("替换：没选")
        } else {
            parts.append("替换「\(s.sourceName)」\(s.sourceEmb.count) 维·模长 "
                + String(format: "%.2f", FsxEngine.norm(s.sourceEmb)))
        }
        return parts.joined(separator: "｜")
    }

    /// 界面这张表 → 引擎要的那份。空位跳过；有目标没替换、或只有替换没目标都要说清楚。
    private var castPlan: (members: [SwapCastMember], problem: String) {
        var out: [SwapCastMember] = []
        for (i, s) in slots.enumerated() {
            if !s.used { continue }
            if s.targetEmb.isEmpty {
                return ([], "目标\(i + 1) 还没认到人脸：重新上传那张目标图片")
            }
            if s.sourceEmb.isEmpty {
                return ([], "目标\(i + 1) 还没选替换脸：点一个已存的人，或选一张源脸照片")
            }
            out.append(SwapCastMember(targetEmb: s.targetEmb, targetLabel: "目标\(i + 1)",
                                      sourceEmb: s.sourceEmb, sourceLabel: s.sourceName))
        }
        if out.isEmpty {
            return ([], "目标表是空的：先上传目标人脸1图片，认到脸以后选替换脸")
        }
        return (out, "")
    }

    private var castReady: Bool { castPlan.problem.isEmpty }

    private func castLabel(_ members: [SwapCastMember]) -> String {
        members.enumerated().map { "\($0.element.targetLabel)→「\($0.element.sourceLabel)」" }.joined(separator: "、")
    }

    private func ingestTarget(_ i: Int, img: UIImage, file: String) {
        guard !castLocked else { return }
        slots[i].targetImg = img
        slots[i].targetFile = file
        slots[i].targetEmb = []
        slots[i].targetSide = 0
        slots[i].targetNote = "正在检测目标人脸……"
        castBusy = true
        castText = "目标\(i + 1) 正在算特征（第一次要先装两张网）"
        SwapJournal.line("上传目标\(i + 1) \(file)｜开始检测")
        let slotIndex = i
        SwapCast.embed(image: img, tag: "目标\(i + 1)",
                       onLine: { line in SwapJournal.line(line) }) { emb, why in
            castBusy = false
            if let e = emb {
                slots[slotIndex].targetEmb = e.emb
                slots[slotIndex].targetSide = e.shortSide
                slots[slotIndex].targetNote = "已检测到目标人脸（\(e.note)）"
                castText = "目标\(slotIndex + 1) 已认到脸"
                SwapJournal.line("目标\(slotIndex + 1) 已认到脸｜\(e.note)")
            } else {
                slots[slotIndex].targetNote = "没认到可用的人脸：\(why)"
                castText = "目标\(slotIndex + 1) 没认到脸，换一张正脸照"
                SwapJournal.line("目标\(slotIndex + 1) 失败：\(why)")
            }
        }
    }

    private func ingestReplacement(_ i: Int, img: UIImage) {
        guard !castLocked else { return }
        castBusy = true
        castText = "目标\(i + 1) 的替换脸正在算特征"
        SwapJournal.line("目标\(i + 1) 选了一张源脸照片当替换脸")
        let slotIndex = i
        SwapCast.embed(image: img, tag: "目标\(i + 1) 的替换脸",
                       onLine: { line in SwapJournal.line(line) }) { emb, why in
            castBusy = false
            guard let e = emb else {
                slots[slotIndex].sourceNote = "这张替换脸没算成：\(why)"
                castText = "目标\(slotIndex + 1) 的替换脸没算成"
                return
            }
            let sv = SwapCast.saveSource(emb: e.emb) { line in SwapJournal.line(line) }
            slots[slotIndex].sourceId = sv.id
            slots[slotIndex].sourceName = sv.name
            slots[slotIndex].sourceEmb = e.emb
            slots[slotIndex].sourceNote = "替换脸＝刚选的照片「\(sv.name)」（已存进「已存的人」）"
            idents = SwapIdents.list()
            castText = "目标\(slotIndex + 1) 的替换脸已就位"
            SwapJournal.line("目标\(slotIndex + 1) 的替换脸已就位：「\(sv.name)」")
        }
    }

    private func chooseReplacement(slot i: Int, ident: SwapIdents.Item) {
        guard !castLocked else { return }
        guard let one = SwapIdents.load(id: ident.id) else {
            slots[i].sourceNote = "「\(ident.name)」的存档读不出来"
            return
        }
        let n = FsxEngine.norm(one.emb)
        guard one.emb.count == FsxNets.embDim, n > 0.5 else {
            slots[i].sourceNote = "「\(one.name)」这份身份证用不了（\(one.emb.count) 维／模长 "
                + String(format: "%.3f", n) + "）"
            return
        }
        slots[i].sourceId = ident.id
        slots[i].sourceName = one.name
        slots[i].sourceEmb = one.emb
        slots[i].sourceNote = "替换脸＝已存「\(one.name)」"
        castText = "目标\(i + 1) 的替换脸＝「\(one.name)」"
        SwapJournal.line("目标\(i + 1) 替换脸＝已存「\(one.name)」｜模长 \(String(format: "%.2f", n))")
    }

    private func clearSlot(_ i: Int) {
        guard !castLocked else { return }
        slots[i] = SwapCastSlot()
        castText = "清空了目标\(i + 1)"
        SwapJournal.line("清空目标\(i + 1)")
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
        let plan = castPlan
        guard plan.problem.isEmpty else {
            result = plan.problem
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
        SwapUtil.keepScreenAwake(true)
        let units = Self.units[unitIdx].1
        let longEdge = Self.longs[longIdx]
        let members = plan.members
        if SwapContentView.engine.isActive {
            SwapJournal.line("开始整片换脸：预览还开着，先叫停它并把两张网交出来（两条同跑＝两份足迹＋互相抢算力）")
        }
        SwapJournal.line("开始整片换脸 units=\(Self.units[unitIdx].0) 长边=\(longEdge) 目标表="
            + castLabel(members) + " 片=\(v.lastPathComponent)")
        var args = SwapClip.Args()
        args.units = units
        args.longEdge = longEdge
        Task.detached {
            // 预览还开着就先叫停，并等它把两张网＋两块整幅缓冲交出来再装自己这一份
            SwapContentView.engine.stop()
            var waited = 0.0
            while SwapContentView.engine.isActive && waited < 5.0 {
                Thread.sleep(forTimeInterval: 0.2)
                waited += 0.2
            }
            if waited > 0 {
                SwapJournal.line(String(format: "预览交还网络用了 %.1f s", waited))
            }
            // 注册那两张网也交回去：出片自己还要装一份，两份同时在手＝几百 MB 白吃
            SwapCast.release()
            let r = SwapClip.run(members: members, video: v, args: args) { line in
                SwapJournal.line(line)
                // 模型下载的进度往界面上递一句：0.33 起模型不在包里，第一次跑要先下几百 MB，
                // 不递的话界面上只有「换脸跑着…」，看着像卡死
                if line.hasPrefix("模型") {
                    DispatchQueue.main.async { pv.modelText = line }
                }
                // 同一句道理用在整片跑动中：0.37 上机就被当成过死机——一趟几分钟，界面上从头到尾只有
                // 「换脸跑着…」这一句。流水里本来就有按帧号报进度的那几行，原样递一行上来，版式不动。
                let head = line.trimmingCharacters(in: .whitespaces)
                if head.hasPrefix("换到第") || head.hasPrefix("预检到第") || head.hasPrefix("先跑预检")
                    || head.contains("现场编译") || head.contains(" 装包 ") {
                    DispatchQueue.main.async { result = head }
                }
            }
            // 视频那份拷贝是输入，跑完就该还掉：手机存储不许留残料（选片那份选定时就还了）
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
                SwapUtil.keepScreenAwake(false)
                facts = SwapFacts.lines()
                idents = SwapIdents.list()
            }
        }
    }

    /// 一按量四档算力：整张换脸网在每一档上各装各跑 5 格。跑的时候不许同时开换脸／预览
    /// （两份 726 MB 的换脸网同时在手里会被系统当场杀掉），所以先把预览叫停。
    private func startBench() {
        benchBusy = true
        benchText = "量速 第一档正在装两张网（用回上回编好的那一份，不重编）"
        SwapJournal.line("开始量四档算力（每档 5 格）")
        SwapUtil.keepScreenAwake(true)
        Task.detached {
            SwapContentView.engine.stop()
            var waited = 0.0
            while SwapContentView.engine.isActive && waited < 5.0 {
                Thread.sleep(forTimeInterval: 0.2)
                waited += 0.2
            }
            SwapCast.release()
            FsxBench.run { line in
                SwapJournal.line(line)
                let head = line.trimmingCharacters(in: .whitespaces)
                if head.hasPrefix("量速") {
                    DispatchQueue.main.async { benchText = head }
                }
            }
            DispatchQueue.main.async {
                benchBusy = false
                SwapUtil.keepScreenAwake(false)
                facts = SwapFacts.lines()
            }
        }
    }

    // MARK: - 已存的人

    private func startRename(_ it: SwapIdents.Item) {
        renameId = it.id
        renameText = it.name
        renaming = true
    }

    private func commitRename() {
        renaming = false
        guard !renameId.isEmpty else { return }
        let want = renameText
        identNote = SwapIdents.rename(id: renameId, to: want)
        SwapJournal.line("改名：\(identNote)")
        for i in slots.indices where slots[i].sourceId == renameId {
            slots[i].sourceName = want
            slots[i].sourceNote = "替换脸＝已存「\(want)」"
        }
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
        let gone = delId
        identNote = SwapIdents.remove(id: gone)
        SwapJournal.line("删已存的人：\(identNote)")
        for i in slots.indices where slots[i].sourceId == gone {
            slots[i].sourceId = ""
            slots[i].sourceName = ""
            slots[i].sourceEmb = []
            slots[i].sourceNote = "原来选的替换脸被删了，重新选一个"
        }
        delId = ""
        idents = SwapIdents.list()
    }

    // MARK: - 预览

    /// 「开始预览」点不下去时，原因就写在按钮旁边
    private var previewBlock: String {
        if castBusy { return "目标表正在算特征，等这一步收尾" }
        if benchBusy { return "量速跑着：先等它收尾" }
        if running { return "整片换脸正跑着：这一版预览不和它抢 CPU，先等它收尾" }
        if videoURL == nil { return "还没点②选要预览的视频（预览吃的就是②那一条）" }
        if !FileManager.default.fileExists(atPath: videoURL?.path ?? "") {
            return "②那份副本上一趟已经还掉了，重新点②选一条"
        }
        let plan = castPlan
        if !plan.problem.isEmpty { return plan.problem }
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
        guard !running, !castBusy else { return }
        guard let v = videoURL else { return }
        let plan = castPlan
        guard plan.problem.isEmpty, !plan.members.isEmpty else {
            pv.status = plan.problem
            return
        }
        guard FileManager.default.fileExists(atPath: v.path) else {
            videoURL = nil
            pv.status = "②那份副本上一趟已经还掉了，重新点②选一条"
            SwapJournal.line("预览 开始被挡：\(v.lastPathComponent) 这份副本不在了，要重新选")
            return
        }
        var c = SwapPreview.Cfg()
        c.units = Self.units[unitIdx].1
        c.unitsTxt = Self.units[unitIdx].0
        SwapCast.release()
        let reject = eng.start(video: v, members: plan.members, cfg: c)
        if !reject.isEmpty {
            pv.status = reject
            SwapJournal.line("预览 开始被挡：\(reject)")
            return
        }
        pv.on = true
        pv.img = nil
        pv.report = ""
        pv.pos = 0
        pv.dur = 0
        pv.person = ""
        pv.status = "预览开跑：先把两张网装好，第一格还要等它检测到位"
        SwapJournal.line("开始预览 units=\(c.unitsTxt) 目标表=\(castLabel(plan.members)) 片=\(v.lastPathComponent)")
    }

    private func seekPreview(_ sec: Double) {
        guard pv.on else { return }
        SwapJournal.line(String(format: "预览 拖到 %.2f s（重开 reader 跳过去，预览不缓存画面）", sec))
        SwapContentView.engine.seek(sec)
    }

    /// 下模型：两张网（带一份口径标记 chain.txt）合成一个 models.bin 挂在 release 上，下完 sha256 对得上才解包。
    /// 下到 Documents/swap_models —— 程序随便换，这一份原封不动。
    private func downloadModels() {
        let checking = SwapStore.haveAll()
        modelBusy = true
        pv.modelText = checking ? "核对模型版本（只比版本，不重下）…" : "下模型跑着…"
        SwapJournal.line(checking ? "开始核对模型版本" : "开始下模型")
        Task.detached {
            SwapCast.release()
            let g = SwapStore.ensure(force: true) { line in
                SwapJournal.line(line)
                DispatchQueue.main.async { pv.modelText = line }
            }
            SwapJournal.line((checking ? "核对模型 " : "下模型 ") + g.note)
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
        let clip = result.isEmpty ? "（整片换脸还没跑过——先点「开始整片换脸」）" : result
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

/// 全屏横屏那一档：看的还是引擎往 SwapPreviewMirror 上递的那一格画面（两处同一份，不另开一趟预览），
/// 底下只留停／开、位置、退出三样。声音不在这里——在引擎那一趟里，跟着它自己那把「素材 1 s ≈ 墙钟 1 s」的钟走。
struct SwapPreviewFull: View {
    @ObservedObject var pv: SwapPreviewMirror
    /// 开跑前那一句被挡的理由（从外面递进来：这一版预览的闸门还是 SwapContentView 那一套）
    var block: String
    var onToggle: () -> Void
    var onSeek: (Double) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.black
                if let im = pv.img {
                    Image(uiImage: im).resizable().scaledToFit()
                } else {
                    Text(block.isEmpty ? (pv.on ? "开跑了，第一格要等两张网装好" : "（还没开）") : block)
                        .font(.footnote).foregroundColor(.gray)
                        .multilineTextAlignment(.center).padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 10) {
                Button(pv.on ? "停" : "开始预览") { onToggle() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!pv.on && !block.isEmpty)
                Slider(value: $pv.pos, in: 0 ... max(0.1, pv.dur), onEditingChanged: { began in
                    pv.dragging = began
                    if !began { onSeek(pv.pos) }
                })
                .disabled(!pv.on)
                Text(String(format: "%.0f／%.0f s", pv.pos, pv.dur))
                    .font(.caption2).monospacedDigit()
                Button("退出全屏") { onClose() }.buttonStyle(.bordered)
            }
            .padding(.horizontal)
            if !pv.person.isEmpty {
                Text("这一趟目标表：\(pv.person)").font(.caption2).foregroundColor(.gray)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        // cover 挂上之后再叫一次：外面那一次是在它还没上屏时发的，系统那会儿还按竖屏的口径给拒了
        .onAppear { SwapRotate.apply(true) }
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
