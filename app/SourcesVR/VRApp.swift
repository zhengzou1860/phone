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
                Text("VR3D 验证件 v0.1")
                    .font(.title2)
                    .foregroundColor(.green)

                Text(VRFacts.lines().joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)

                Picker("抽帧数", selection: $job.frames) {
                    Text("6 帧").tag(6)
                    Text("10 帧").tag(10)
                    Text("20 帧").tag(20)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                Picker("送检短边", selection: $job.shortSide) {
                    Text("252").tag(252)
                    Text("392").tag(392)
                    Text("504").tag(504)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

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
                    Text("all").tag(0)
                    Text("GPU").tag(1)
                    Text("ANE").tag(2)
                    Text("CPU").tag(3)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                HStack(spacing: 10) {
                    Button("环境自检") { job.startCheck() }
                    Button("深度自检") { job.startProbe() }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
                .disabled(job.busy)

                HStack(spacing: 10) {
                    Button("选视频出试片") { job.showVideoPicker = true }
                    Button("发到电脑") { job.sendReport() }
                }
                .buttonStyle(.borderedProminent)
                .font(.footnote)
                .disabled(job.busy)

                if job.busy {
                    Text(job.status)
                        .font(.footnote)
                        .foregroundColor(.secondary)
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
    @Published var shortSide = 392
    @Published var eyeLong = 540
    @Published var bpct = 5
    @Published var unitTag = 0

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
        let short = shortSide
        status = "深度自检中…（四个计算单元各加载一遍再跑 30 次，第一次可能要现场编译模型）"
        Task.detached { [weak self] in
            let r = VRDepth.probe(runs: 30, shortSide: short)
            await MainActor.run { self?.finish(r) }
        }
    }

    func startPilot(_ url: URL) {
        showVideoPicker = false
        busy = true
        let n = frames
        let short = shortSide
        let eye = eyeLong
        let b = Float(bpct)
        let u = VRJob.unit(unitTag)
        VRPressure.reset()
        status = "出试片中…（抽 \(n) 帧 × 3 个零视差面，深度和形变都要现跑）"
        Task.detached { [weak self] in
            let r = VRPilot.run(url: url, frames: n, shortSide: short, bpct: b, eyeLong: eye,
                                zps: [0.15, 0.50, 0.85], outFps: 5.0, units: u)
            await MainActor.run { self?.finish(r) }
        }
    }

    func finishPick(url: URL?, failMessage: String?) {
        showVideoPicker = false
        guard let url = url else {
            log.append("取文件失败\n\(failMessage ?? "未知原因")")
            return
        }
        startPilot(url)
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
