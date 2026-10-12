import CoreML
import PhotosUI
import SwiftUI
import UIKit

@main
struct SwapApp: App {
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
    @State private var videoURL: URL?
    @State private var picking: String = ""          // "face" / "video"：谁的选片器开着
    @State private var running = false
    @State private var unitIdx = 0                   // 默认 units[0] = cpuOnly
    @State private var longIdx = 0                   // 默认 1920（长边上限）
    @State private var result = ""
    @State private var logTail = ""
    @State private var outURL: URL?

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
                        Text("整片换脸").font(.headline)
                        Button(faceURL == nil ? "① 选一张源脸照片" : "① 源脸：\(faceURL!.lastPathComponent)（点它换一张）") {
                            picking = "face"
                        }
                        .buttonStyle(.bordered)
                        .disabled(running)
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
                        .disabled(running || faceURL == nil || videoURL == nil)

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
                        faceURL = u
                        SwapJournal.line("选了源脸 \(u.lastPathComponent)")
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
        guard let f = faceURL, let v = videoURL, let img = UIImage(contentsOfFile: f.path) else {
            result = "源脸照片读不进来（重新选一张）"
            return
        }
        running = true
        result = ""
        outURL = nil
        logTail = SwapJournal.tail(30)
        let units = Self.units[unitIdx].1
        let longEdge = Self.longs[longIdx]
        SwapJournal.line("开始整片换脸 units=\(Self.units[unitIdx].0) 长边=\(longEdge) 源=\(f.lastPathComponent) 片=\(v.lastPathComponent)")
        var args = SwapClip.Args()
        args.units = units
        args.longEdge = longEdge
        Task.detached {
            let r = SwapClip.run(source: img, video: v, args: args) { line in
                SwapJournal.line(line)
            }
            // 选片时拷进 tmp 的那两份是输入，跑完就该还掉：手机存储不许留残料
            for u in [f, v] {
                if (try? FileManager.default.removeItem(at: u)) == nil { SwapJournal.line("输入副本没删掉 \(u.lastPathComponent)") }
            }
            DispatchQueue.main.async {
                outURL = r.out
                result = r.note
                running = false
                facts = SwapFacts.lines()
                logTail = SwapJournal.tail(30)
            }
        }
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
