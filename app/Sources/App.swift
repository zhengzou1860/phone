import SwiftUI
import Darwin
import AVFoundation
import CoreMedia
import CoreVideo
import Vision
import PhotosUI

@main
struct HelloApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var bench = Bench()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("自建 app 已运行")
                    .font(.title2)
                    .foregroundColor(.green)

                Text(Facts.lines().joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)

                HStack(spacing: 12) {
                    Button("Vision 自检") { bench.startSelfTest() }
                    Button("选视频跑基准") { bench.showPicker = true }
                }
                .buttonStyle(.borderedProminent)
                .disabled(bench.busy)

                if bench.busy {
                    Text(bench.status)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Text(bench.log.joined(separator: "\n\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .fullScreenCover(isPresented: $bench.showPicker) {
            PickerHost(bench: bench)
        }
    }
}

@MainActor
final class Bench: ObservableObject {
    @Published var log: [String] = []
    @Published var busy = false
    @Published var status = ""
    @Published var showPicker = false

    func startSelfTest() {
        busy = true
        status = "Vision 自检中…"
        Task.detached { [weak self] in
            let report = Runner.visionSelfTest()
            await MainActor.run {
                self?.log.append(report)
                self?.busy = false
                self?.status = ""
            }
        }
    }

    func startVideo(_ url: URL) {
        showPicker = false
        busy = true
        status = "基准运行中…"
        Task.detached { [weak self] in
            let report = Runner.videoBenchmark(url: url, frameLimit: 90)
            await MainActor.run {
                self?.log.append(report)
                self?.busy = false
                self?.status = ""
            }
        }
    }

    func finishPick(url: URL?, failMessage: String?) {
        showPicker = false
        if let url = url {
            startVideo(url)
        } else {
            log.append("取文件失败\n\(failMessage ?? "未知原因")")
        }
    }
}

struct PickerHost: UIViewControllerRepresentable {
    let bench: Bench

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .videos
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(bench) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let bench: Bench

        init(_ bench: Bench) { self.bench = bench }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                Task { @MainActor in
                    self.bench.finishPick(url: nil, failMessage: "没选到文件")
                }
                return
            }
            provider.loadFileRepresentation(forTypeIdentifier: "public.movie") { file, error in
                guard let file = file else {
                    let message = "loadFileRepresentation 返回空: \(error?.localizedDescription ?? "-")"
                    Task { @MainActor in
                        self.bench.finishPick(url: nil, failMessage: message)
                    }
                    return
                }
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("pick_\(UUID().uuidString.prefix(8))")
                    .appendingPathExtension(file.pathExtension)
                do {
                    if FileManager.default.fileExists(atPath: dst.path) {
                        try FileManager.default.removeItem(at: dst)
                    }
                    try FileManager.default.copyItem(at: file, to: dst)
                    Task { @MainActor in
                        self.bench.finishPick(url: dst, failMessage: nil)
                    }
                } catch {
                    let message = "拷贝到临时目录失败: \(error)"
                    Task { @MainActor in
                        self.bench.finishPick(url: nil, failMessage: message)
                    }
                }
            }
        }
    }
}

enum Facts {
    static func lines() -> [String] {
        let info = Bundle.main.infoDictionary ?? [:]
        let pi = ProcessInfo.processInfo
        return [
            "bundleId   \(Bundle.main.bundleIdentifier ?? "-")",
            "version    \(info["CFBundleShortVersionString"] ?? "-") (\(info["CFBundleVersion"] ?? "-"))",
            "iOS        \(pi.operatingSystemVersionString)",
            "machine    \(machineName())  cores=\(pi.processorCount)",
            "memory     已用 \(Self.footprintMB()) MB / 总量 \(pi.physicalMemory / 1048576) MB",
            "bundlePath \(Bundle.main.bundlePath)",
            "documents  \(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "-")",
            "Vision     \(NSClassFromString("VNDetectFaceRectanglesRequest") != nil ? "可用" : "缺失")",
            "AVFoundation \(NSClassFromString("AVAssetReader") != nil ? "可用" : "缺失")",
            "PhotosUI   \(NSClassFromString("PHPickerViewController") != nil ? "可用" : "缺失")"
        ]
    }

    static func machineName() -> String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(bytes: raw.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "?"
        }
    }

    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint) / 1_048_576
    }
}

enum Runner {

    static func visionSelfTest() -> String {
        guard let image = syntheticImage(width: 720, height: 1280) else {
            return "Vision 自检\n生成测试图失败"
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        var times: [Double] = []
        var faceCount = -1
        for i in 0..<6 {
            let request = VNDetectFaceRectanglesRequest()
            let t0 = DispatchTime.now().uptimeNanoseconds
            do {
                try handler.perform([request])
            } catch {
                return "Vision 自检\nperform 抛错: \(error)"
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            if i > 0 { times.append(ms) }
            faceCount = request.results?.count ?? -1
        }
        return """
        Vision 自检（\(image.width)x\(image.height) 合成图，无真人脸）
        单次 detect: \(stat(times))
        检到人脸数: \(faceCount)（合成图预期 0）
        说明: 这一步只证明 Vision 在容器内能初始化并跑完一次检测，不代表速度。
        """
    }

    static func videoBenchmark(url: URL, frameLimit: Int) -> String {
        let asset = AVURLAsset(url: url)

        let ready = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { ready.signal() }
        if ready.wait(timeout: .now() + 20) == .timedOut {
            return "视频基准\n加载 tracks/duration 超时 20 s"
        }

        guard let track = asset.tracks(withMediaType: .video).first else {
            return "视频基准\n找不到视频轨（\(url.lastPathComponent)）\n路径 \(url.path)"
        }

        let readerResult: AVAssetReader?
        do {
            readerResult = try AVAssetReader(asset: asset)
        } catch {
            return "视频基准\nAVAssetReader 创建失败: \(error)"
        }
        guard let reader = readerResult else {
            return "视频基准\nAVAssetReader 创建返回 nil"
        }

        let settings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let outputResult: AVAssetReaderTrackOutput?
        do {
            outputResult = try AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        } catch {
            return "视频基准\nTrackOutput 创建失败: \(error)"
        }
        guard let output = outputResult else {
            return "视频基准\nTrackOutput 创建返回 nil（BGRA 不被支持？）"
        }
        reader.add(output)
        guard reader.startReading() else {
            return "视频基准\nstartReading 失败: \(reader.error?.localizedDescription ?? "-")"
        }

        var decodeTimes: [Double] = []
        var visionTimes: [Double] = []
        var faceTotals = 0
        var widest = 0
        var tallest = 0
        var frames = 0

        while frames < frameLimit {
            let d0 = DispatchTime.now().uptimeNanoseconds
            guard let sample = output.copyNextSampleBuffer() else { break }
            let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - d0) / 1_000_000
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { break }
            if frames == 0 {
                widest = CVPixelBufferGetWidth(buffer)
                tallest = CVPixelBufferGetHeight(buffer)
            }

            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
            let v0 = DispatchTime.now().uptimeNanoseconds
            do {
                try handler.perform([request])
            } catch {
                return "视频基准\n第 \(frames + 1) 帧 Vision 抛错: \(error)"
            }
            let visionMs = Double(DispatchTime.now().uptimeNanoseconds - v0) / 1_000_000

            if frames >= 3 {
                decodeTimes.append(decodeMs)
                visionTimes.append(visionMs)
            }
            faceTotals += request.results?.count ?? 0
            frames += 1
        }

        guard frames > 3, !visionTimes.isEmpty else {
            return "视频基准\n只解出 \(frames) 帧，不够计时（reader.status=\(reader.status.rawValue)）"
        }

        let decodeAvg = decodeTimes.reduce(0, +) / Double(decodeTimes.count)
        let visionAvg = visionTimes.reduce(0, +) / Double(visionTimes.count)
        let perFrame = decodeAvg + visionAvg
        let serialFps = 1000.0 / max(perFrame, 0.001)
        let duration = CMTimeGetSeconds(asset.duration)
        let nominal = track.nominalFrameRate
        let videoFps = nominal > 0 ? Double(nominal) : 30.0
        let realtimeFactor = serialFps / videoFps
        let wholeClip = duration * videoFps / serialFps
        let sizeBytes: Int? = {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return attrs?[.size] as? Int
        }()
        let sizeText = sizeBytes.map { "\($0 / 1048576) MB" } ?? "-"

        return """
        视频基准 \(url.lastPathComponent)
        解出 \(frames) 帧 @ \(widest)x\(tallest)，全长 \(String(format: "%.1f", duration)) s，\(String(format: "%.1f", videoFps)) fps，大小 \(sizeText)
        解码: \(stat(decodeTimes))
        Vision: \(stat(visionTimes))
        串行 \(String(format: "%.1f", perFrame)) ms/帧 = \(String(format: "%.1f", serialFps)) 帧/秒
        实时倍率 \(String(format: "%.2f", realtimeFactor)) x（>1 才比 realtime 快）
        逐帧扫完整段 \(String(format: "%.1f", duration)) s 视频需 \(String(format: "%.1f", wholeClip)) s
        检到人脸总数: \(faceTotals)
        """
    }

    static func stat(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "无数据" }
        let sorted = values.sorted()
        let avg = values.reduce(0, +) / Double(values.count)
        let med = sorted[sorted.count / 2]
        let mx = sorted.last ?? 0
        return String(format: "avg %.1f / 中位 %.1f / max %.1f", avg, med, mx) + " ms（n=\(values.count)）"
    }

    static func syntheticImage(width: Int, height: Int) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.setFillColor(CGColor(red: 0.15, green: 0.2, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let w = CGFloat(width)
        let h = CGFloat(height)
        ctx.setFillColor(CGColor(red: 0.9, green: 0.8, blue: 0.6, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w * 0.3, y: h * 0.45, width: w * 0.4, height: w * 0.4))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w * 0.4, y: h * 0.6, width: 20, height: 20))
        ctx.fillEllipse(in: CGRect(x: w * 0.55, y: h * 0.6, width: 20, height: 20))
        return ctx.makeImage()
    }
}
