import SwiftUI
import Foundation
import UIKit
import AVFoundation
import CoreML
import PhotosUI

@main
struct VR3DApp: App {
    var body: some Scene {
        WindowGroup {
            VRMainView()
        }
    }
}

struct VRMainView: View {
    @StateObject private var job = VRJob()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("VR3D 验证件 v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")")
                    .font(.title2)
                    .foregroundColor(.green)

                Text(VRFacts.lines().joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)

                Picker("出片模式", selection: $job.fullMode) {
                    Text("试片 几秒").tag(false)
                    Text("全片 整条").tag(true)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                if job.fullMode {
                    Picker("全片出几条", selection: $job.fullZps) {
                        Text("1 条 zp0.15").tag(1)
                        Text("3 条 zp.15/.50/.85").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .font(.footnote)

                    Text("全片不限时长：一趟扫（深度落盘 0.77 MB/帧＝518x392 的 Float32，按 30 fps 约 23 MB/秒素材）"
                         + "＋每条一趟出片。开跑前先看磁盘闸门报的那一行：够就往下跑，不够就直接告诉你还能塞多少秒。"
                         + "整片 p1/p99（PC 的 m6 口径）、时域平滑 0.4 都在这条路上，跟抽帧数的 6.6 s 样片无关\n"
                         + "按 10-10 实测单价折：扫约 0.25 s/帧、出片约 0.15 s/帧 ⇒ 3 分钟片 1 条约 35 分钟、3 条约 1 小时"
                         + "（这数是按单价乘出来的，全片这条链路本身还没上机跑过）")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.orange)
                } else {
                    Picker("抽帧数", selection: $job.frames) {
                        Text("6 帧").tag(6)
                        Text("10 帧").tag(10)
                        Text("20 帧").tag(20)
                    }
                    .pickerStyle(.segmented)
                    .font(.footnote)

                    Text("送检尺寸不可调：模型声明「只认 518x392」（上机实测）\n"
                         + "竖屏画面等比进去只占约 215~220 px 宽，左右是黑边 ⇒ 深度单价与「每眼」档无关")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.orange)
                }

                Picker("送检朝向", selection: $job.feedRot) {
                    Text("摆正").tag(false)
                    Text("转 90°").tag(true)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                Text("尺寸动不了，朝向能换画面在框里占多少：每眼 540x960 摆正 86k px（上机实测）／转 90° 按信箱公式算 151k px（+75%，这版自己会在报告里报「本次实占」）")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                Picker("每眼长边", selection: $job.eyeLong) {
                    Text("540").tag(540)
                    Text("720").tag(720)
                    Text("960").tag(960)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                Picker("视差上限", selection: $job.bpct) {
                    Text("3%").tag(3)
                    Text("5%").tag(5)
                    Text("8%").tag(8)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                Picker("试片计算单元", selection: $job.unitTag) {
                    Text("CPU").tag(3)
                    Text("all").tag(0)
                    Text("GPU").tag(1)
                    Text("ANE").tag(2)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                Text("上机实测 518x392：CPU 184 ms/帧（加载 0.43 s）｜GPU 461｜ANE 697（加载 122 s）｜all 853（加载 132 s）")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                HStack(spacing: 10) {
                    Button("环境自检") { job.startCheck() }
                    Button("深度自检") { job.startProbe() }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
                .disabled(job.busy)

                HStack(spacing: 10) {
                    Button(job.fullMode ? "选视频出全片" : "选视频出试片") { job.showVideoPicker = true }
                    Button("发到电脑") { job.sendReport() }
                }
                .buttonStyle(.borderedProminent)
                .font(.footnote)
                .disabled(job.busy)

                if job.busy {
                    Text(job.status)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    if job.fullRunning && VRFull.totalFrames > 0 {
                        ProgressView(value: Double(VRFull.doneFrames), total: Double(VRFull.totalFrames))
                            .tint(.green)
                    }
                }
                if job.fullRunning && !job.stopPressed {
                    Button("停止（已扫的和已出的照样收）") { job.stopFull() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .font(.footnote)
                }

                Text(job.log.joined(separator: "\n\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                DisclosureGroup("磁盘日志（闪退后重开还在）") {
                    Text(VRJournal.tail(12))
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
            }
            .padding()
        }
        .fullScreenCover(isPresented: $job.showVideoPicker) {
            VRPickerHost { url, msg in job.finishPick(url: url, failMessage: msg) }
        }
    }
}

@MainActor
final class VRJob: ObservableObject {
    @Published var log: [String] = []
    @Published var busy = false
    @Published var status = ""
    @Published var showVideoPicker = false
    @Published var frames = 10
    @Published var eyeLong = 540
    @Published var bpct = 5
    /// 默认 CPU：10-10 上机实测 184 ms/帧，比 all 的 853 ms 快 4.6 倍，且不交 ANE 那 122 s 的加载税
    @Published var unitTag = 3
    /// 默认摆正：所有已测数字都是这个口径下测的，换朝向要靠同一素材两版对看
    @Published var feedRot = false
    /// 试片（抽 N 帧、只出几秒，指标全）／全片（整条，深度落盘跑两趟）
    @Published var fullMode = false
    /// 1 条 = PC m6 那个出货档 zp0.15；3 条 = 上中下三个零视差面对比
    @Published var fullZps = 1
    @Published var fullRunning = false
    @Published var stopPressed = false
    private var ticker: Timer?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        VRJournal.line("=== 启动 v\(info["CFBundleShortVersionString"] ?? "-") ===")
        VRPressure.start()
    }

    static func unit(_ tag: Int) -> MLComputeUnits {
        switch tag {
        case 1: return .cpuAndGPU
        case 2: return .cpuAndNeuralEngine
        case 3: return .cpuOnly
        default: return .all
        }
    }

    func finish(_ report: String) {
        ticker?.invalidate()
        ticker = nil
        fullRunning = false
        log.append(report)
        if log.count > 8 { log.removeFirst(log.count - 8) }
        busy = false
        status = ""
        VRJournal.line("界面 " + report.replacingOccurrences(of: "\n", with: " ／ "))
    }

    func startCheck() {
        busy = true
        status = "环境自检中…（Metal + 色彩往返 + 白线实验）"
        Task.detached { [weak self] in
            let r = VRCheck.all()
            await MainActor.run { self?.finish(r) }
        }
    }

    func startProbe() {
        busy = true
        status = "深度自检中…（四单元各加载一遍＋预热 5＋正式 30 次；带 ANE 的两个单元各自加载要 2 分钟，整轮实测 345 s）"
        Task.detached { [weak self] in
            let r = VRDepth.probe(runs: 30)
            await MainActor.run { self?.finish(r) }
        }
    }

    func startPilot(_ url: URL) {
        showVideoPicker = false
        busy = true
        let n = frames
        let eye = eyeLong
        let b = Float(bpct)
        let u = VRJob.unit(unitTag)
        let rot = feedRot
        let rn = rot ? "转90°" : "摆正"
        VRPressure.reset()
        status = "出试片中…（抽 \(n) 帧 × 3 个零视差面；送检\(rn)；深度单元 \(VRPilot.unitsName(u))，单价见上方实测那行）"
        Task.detached { [weak self] in
            let r = VRPilot.run(url: url, frames: n, bpct: b, eyeLong: eye,
                                zps: [0.15, 0.50, 0.85], outFps: 5.0, units: u, rot: rot)
            await MainActor.run { self?.finish(r) }
        }
    }

    func startFull(_ url: URL) {
        showVideoPicker = false
        busy = true
        fullRunning = true
        stopPressed = false
        let b = Float(bpct)
        let eye = eyeLong
        let u = VRJob.unit(unitTag)
        let rot = feedRot
        let zps: [Float] = fullZps == 3 ? [0.15, 0.50, 0.85] : [0.15]
        VRPressure.reset()
        status = "全片起手…（读几何、载模型、过磁盘闸门）"
        ticker = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.busy else { return }
                let p = VRFull.progress
                guard !p.isEmpty else { return }
                self.status = (VRFull.cancelRequested ? "正在收兵｜" : "") + p
            }
        }
        Task.detached { [weak self] in
            let r = VRFull.run(url: url, bpct: b, eyeLong: eye, zps: zps, smooth: 0.4, units: u, rot: rot)
            await MainActor.run { self?.finish(r) }
        }
    }

    func stopFull() {
        VRFull.requestCancel()
        stopPressed = true
        status = "正在收兵：把手上这一帧/这一条做完就停，已扫的深度和已出的成片照样报"
    }

    func finishPick(url: URL?, failMessage: String?) {
        showVideoPicker = false
        guard let url = url else {
            log.append("取文件失败\n\(failMessage ?? "未知原因")")
            return
        }
        if fullMode { startFull(url) } else { startPilot(url) }
    }

    func sendReport() {
        busy = true
        status = "正在发往电脑…"
        let text = VRFacts.lines().joined(separator: "\n") + "\n\n"
            + log.joined(separator: "\n\n")
            + "\n\n—— 磁盘日志最近 150 行 ——\n" + VRJournal.tail(150)
        Task.detached { [weak self] in
            let r = VRUploader.send(text)
            await MainActor.run { self?.finish(r) }
        }
    }
}

struct VRPickerHost: UIViewControllerRepresentable {
    let onDone: (URL?, String?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .videos
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onDone: (URL?, String?) -> Void

        init(_ onDone: @escaping (URL?, String?) -> Void) { self.onDone = onDone }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                done(nil, "没选到文件")
                return
            }
            provider.loadFileRepresentation(forTypeIdentifier: "public.movie") { file, error in
                guard let file = file else {
                    self.done(nil, "loadFileRepresentation 返回空: \(error?.localizedDescription ?? "-")")
                    return
                }
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("vr3d_\(UUID().uuidString.prefix(8))")
                    .appendingPathExtension(file.pathExtension)
                do {
                    if FileManager.default.fileExists(atPath: dst.path) {
                        try FileManager.default.removeItem(at: dst)
                    }
                    try FileManager.default.copyItem(at: file, to: dst)
                    self.done(dst, nil)
                } catch {
                    self.done(nil, "拷贝到临时目录失败: \(error)")
                }
            }
        }

        private func done(_ url: URL?, _ failMessage: String?) {
            let onDone = self.onDone
            Task { @MainActor in onDone(url, failMessage) }
        }
    }
}
