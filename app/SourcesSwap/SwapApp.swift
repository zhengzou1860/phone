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

/// 选片、开始换脸这一摊的状态。跑起来之后界面只靠每秒捞磁盘日志尾巴来动，
/// 后台线程不许直接碰 SwiftUI 的 @State。
struct SwapContentView: View {
    @State private var facts: [String] = []
    @State private var faceURL: URL?
    @State private var faceImg: UIImage?          // 选定时就读进来：tmp 副本当场还掉，重跑不必重选
    @State private var videoURL: URL?
    @State private var picking: String = ""          // "face" / "video"：谁的选片器开着
    @State private var running = false
    @State private var unitIdx = 0                   // 默认 units[0] = cpuOnly
    @State private var longIdx = 0                   // 默认 1920（长边上限）
    @State private var result = ""
    @State private var logTail = ""
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

    @State private var benchText = ""
    @State private var benchRunning = false
    @State private var runs = 30
    @State private var sendStatus = ""
    @State private var sending = false

    static let units: [(String, MLComputeUnits)] = [
        ("CPU(cpuOnly)", .cpuOnly),
        ("GPU(cpuAndGPU)", .cpuAndGPU),
        ("all", .all),
        ("ANE(cpuAndNeuralEngine)", .cpuAndNeuralEngine),
    ]
    static let longs = [1920, 1280, 960, 640]

    private let pulse = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("环境").font(.headline)
                    ForEach(facts, id: \.self) { Text($0).font(.caption) }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("已存的人（选他就不必再挑照片）").font(.headline)
                        Text("一人一份 18 个身份权重＋512 维身份证；点名字选中，跑片时跳过身份证＋身份包那两步。")
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
                        .disabled(running)
                        Picker("长边上限", selection: $longIdx) {
                            ForEach(0 ..< Self.longs.count, id: \.self) { i in
                                Text("\(Self.longs[i]) px").tag(i)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(running)

                        // 点下去立刻置灰 + 改文案：手机上长任务没有别的反馈手段
                        Button(running ? "换脸跑着…（别看空屏，下面在动）" : "开始换脸") {
                            startSwap()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || !hasSource || videoURL == nil)

                        // 我点的这个按钮下面就是真实流水：送达→执行→到第几帧→结果
                        Text(running ? "跑着，下面每 1 s 刷一次："
                            : (logTail.isEmpty ? "（还没跑过）" : "上一次跑完的流水尾部："))
                            .font(.caption)
                        Text(logTail.isEmpty ? "—" : logTail)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

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
                        Text("逐帧网自检（只那张最小的网，喂随机权重）").font(.headline)
                        Stepper("每次计 \(runs) 帧", value: $runs, in: 5...200, step: 5)
                            .font(.caption)
                        Button(benchRunning ? "自检跑着…" : "跑逐帧网自检") { runBench() }
                            .buttonStyle(.bordered)
                            .disabled(benchRunning || running)
                        Text(benchText.isEmpty ? "（自检还没跑过）" : benchText)
                            .font(.caption)
                            .textSelection(.enabled)
                    }

                    Divider()

                    DisclosureGroup("这一版在判什么") {
                        Text("""
                        三张 fp32 网全在包里：身份证（arcface）、每人一次的 18 个权重张量（BuildFaceSwap）、\
                        逐帧那张（MobileFaceSwapUNet）。前两张每人只算一次，这一版第一次在 A13 上量出这两步多少钱；\
                        逐帧那张 CPU 上机已经量过 12.00 ms/帧。
                        片子上机走的是「摆正后的帧→检测→对齐→224 裁片→逐帧网→回贴→重编 h264」，\
                        跑完自己存相册、成功才删沙盒那份。
                        界面上每 sampleEvery=30 帧复测一次身份余弦（PC 参照：换后<->源 0.81~0.90）——\
                        这一版质量不许降，所以三张网都是 fp32，码率按尺寸给到 6 Mbps 以上。
                        这一版多了「已存的人」：一张照片的身份（18 个权重＋512 维身份证）落进 Documents/swap_idents，\
                        以后点名字直接选他，跳过身份证＋身份包那两步（上机实测这两步 70.61 + 18.27 ms），能改名、能删，删掉就把那份字节还回磁盘。
                        贴法退回第一版：你判「反倒是第一版的参数是最好的，包括遮罩的范围」，\
                        所以这一版遮罩走官方 preprocess_mask 那一刀（>0.001 归 1→11 膨胀→11 腐蚀×2→7×7 模糊→10 px 内收衰减），\
                        补丁直接取逐帧网自己混好的 out。五官加深 γ、可调透明度遮罩、高频回填这三样是我在后面三版里加的，这一版都不在；\
                        CI 给逐帧网挂的第三个出参这一版也没有代码去取它。
                        """)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("换脸出片")
            .onAppear {
                facts = SwapFacts.lines()
                idents = SwapIdents.list()
                logTail = SwapJournal.tail(30)
            }
            .onReceive(pulse) { _ in
                if running || benchRunning { logTail = SwapJournal.tail(30) }
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
                        videoURL = u
                        SwapJournal.line("选了视频 \(u.lastPathComponent)")
                    } else {
                        SwapJournal.line("选视频没成：\(err ?? "-")")
                        result = "选视频没成：\(err ?? "-")"
                    }
                }
            }
        }
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
        running = true
        result = ""
        outURL = nil
        logTail = SwapJournal.tail(30)
        let units = Self.units[unitIdx].1
        let longEdge = Self.longs[longIdx]
        SwapJournal.line("开始整片换脸 units=\(Self.units[unitIdx].0) 长边=\(longEdge) 源=\(sourceTag) 片=\(v.lastPathComponent)")
        var args = SwapClip.Args()
        args.units = units
        args.longEdge = longEdge
        Task.detached {
            let r = SwapClip.run(person: person, video: v, args: args) { line in
                SwapJournal.line(line)
            }
            // 视频那份拷贝是输入，跑完就该还掉：手机存储不许留残料（源脸那份选定时就还了）
            if !FileManager.default.fileExists(atPath: v.path) {
                SwapJournal.line("视频副本早没了 \(v.lastPathComponent)")
            } else if (try? FileManager.default.removeItem(at: v)) == nil {
                SwapJournal.line("视频副本没删掉 \(v.lastPathComponent)")
            }
            DispatchQueue.main.async {
                outURL = r.out
                result = r.note
                running = false
                facts = SwapFacts.lines()
                idents = SwapIdents.list()
                logTail = SwapJournal.tail(30)
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

    private func runBench() {
        benchRunning = true
        benchText = ""
        SwapJournal.line("开始逐帧网自检 runs=\(runs)")
        let n = runs
        Task.detached {
            let text = SwapBench.probe(runs: n) { line in
                SwapJournal.line(line)
            }
            DispatchQueue.main.async {
                benchText = text
                benchRunning = false
            }
        }
    }

    private func sendReport() {
        sending = true
        sendStatus = "发着…"
        let facts = SwapFacts.lines().joined(separator: "\n")
        let clip = result.isEmpty ? "（整片换脸还没跑过——先点「开始换脸」）" : result
        let bench = benchText.isEmpty ? "（自检还没跑过）" : benchText
        let text = "—— 环境 ——\n" + facts
            + "\n\n—— 整片换脸 ——\n" + clip
            + "\n\n—— 逐帧网自检 ——\n" + bench
            + "\n\n—— 流水 ——\n" + SwapJournal.tail(200)
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
