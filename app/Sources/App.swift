import SwiftUI
import Foundation
import Darwin
import UIKit
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

enum PickTarget { case video, photo }

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

                HStack(spacing: 10) {
                    Button("合成图自检") { bench.startSelfTest() }
                    Button("照片正对照") { bench.showPhotoPicker = true }
                }
                HStack(spacing: 10) {
                    Button("选视频跑基准") { bench.showVideoPicker = true }
                    Button("发到电脑") { bench.sendReport() }
                }
                .buttonStyle(.borderedProminent)
                .font(.footnote)
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
        .fullScreenCover(isPresented: $bench.showVideoPicker) {
            PickerHost(bench: bench, target: .video)
        }
        .fullScreenCover(isPresented: $bench.showPhotoPicker) {
            PickerHost(bench: bench, target: .photo)
        }
    }
}

@MainActor
final class Bench: ObservableObject {
    @Published var log: [String] = []
    @Published var busy = false
    @Published var status = ""
    @Published var showVideoPicker = false
    @Published var showPhotoPicker = false

    func finish(_ report: String) {
        log.append(report)
        busy = false
        status = ""
    }

    func startSelfTest() {
        busy = true
        status = "合成图自检中…"
        Task.detached { [weak self] in
            let report = Runner.visionSelfTest()
            await MainActor.run { self?.finish(report) }
        }
    }

    func startVideo(_ url: URL) {
        showVideoPicker = false
        busy = true
        status = "视频基准运行中…"
        Task.detached { [weak self] in
            let report = Runner.videoBenchmark(url: url, frameLimit: 90)
            await MainActor.run { self?.finish(report) }
        }
    }

    func startPhoto(_ url: URL) {
        showPhotoPicker = false
        busy = true
        status = "照片正对照中…"
        Task.detached { [weak self] in
            let report = Runner.photoControl(url: url)
            await MainActor.run { self?.finish(report) }
        }
    }

    func sendReport() {
        showVideoPicker = false
        showPhotoPicker = false
        busy = true
        status = "正在发往电脑…"
        let text = Facts.lines().joined(separator: "\n") + "\n\n"
            + log.joined(separator: "\n\n")
        Task.detached { [weak self] in
            let report = Uploader.send(text)
            await MainActor.run { self?.finish(report) }
        }
    }

    func finishPick(url: URL?, failMessage: String?, target: PickTarget) {
        showVideoPicker = false
        showPhotoPicker = false
        guard let url = url else {
            log.append("取文件失败\n\(failMessage ?? "未知原因")")
            return
        }
        switch target {
        case .video: startVideo(url)
        case .photo: startPhoto(url)
        }
    }
}

struct PickerHost: UIViewControllerRepresentable {
    let bench: Bench
    let target: PickTarget

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = target == .video ? .videos : .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(bench, target) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let bench: Bench
        let target: PickTarget

        init(_ bench: Bench, _ target: PickTarget) {
            self.bench = bench
            self.target = target
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                report(nil, "没选到文件")
                return
            }
            let typeID = target == .video ? "public.movie" : "public.image"
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { file, error in
                guard let file = file else {
                    self.report(nil, "loadFileRepresentation 返回空: \(error?.localizedDescription ?? "-")")
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
                    self.report(dst, nil)
                } catch {
                    self.report(nil, "拷贝到临时目录失败: \(error)")
                }
            }
        }

        private func report(_ url: URL?, _ failMessage: String?) {
            let target = self.target
            Task { @MainActor in
                self.bench.finishPick(url: url, failMessage: failMessage, target: target)
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
            "memory     驻留 \(residentMB()) MB / 物理 \(pi.physicalMemory / 1048576) MB",
            "endpoint   \(Uploader.endpoint)",
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

    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)
            / mach_msg_type_number_t(MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.resident_size) / 1_048_576
    }
}

enum Uploader {
    static let endpoint = "http://192.168.31.99:8712/report"

    static func send(_ text: String) -> String {
        guard let url = URL(string: endpoint) else { return "发送失败: 地址非法" }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = text.data(using: .utf8)

        let done = DispatchSemaphore(value: 0)
        var code = -1
        var reply = ""
        var failure = ""
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error { failure = "\(error)" }
            if let response = response as? HTTPURLResponse { code = response.statusCode }
            if let data = data { reply = String(data: data, encoding: .utf8) ?? "?" }
            done.signal()
        }.resume()

        if done.wait(timeout: .now() + 20) == .timedOut {
            return "发到电脑：超时 20 s 无回音（手机到 192.168.31.99:8712 不通？电脑上的接收端没开？）"
        }
        if code < 0 { return "发到电脑：失败 \(failure)" }
        return "发到电脑：HTTP \(code) 回执 \(reply)（送出 \(text.count) 字符）"
    }
}

enum Runner {

    static func detectRuns(_ image: CGImage, runs: Int)
        -> (times: [Double], count: Int, detail: String) {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        var times: [Double] = []
        var count = -1
        var detail = "-"
        for i in 0..<runs {
            let request = VNDetectFaceRectanglesRequest()
            let t0 = DispatchTime.now().uptimeNanoseconds
            do {
                try handler.perform([request])
            } catch {
                return (times, -999, "perform 抛错: \(error)")
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            if i > 0 { times.append(ms) }
            let found = request.results ?? []
            count = found.count
            if let first = found.first {
                detail = "置信 \(first.confidence) 框 \(first.boundingBox)"
            }
        }
        return (times, count, detail)
    }

    static func visionSelfTest() -> String {
        guard let image = syntheticImage(width: 720, height: 1280) else {
            return "Vision 自检\n生成测试图失败"
        }
        let r = detectRuns(image, runs: 6)
        return """
        合成图自检（\(image.width)x\(image.height)，里面没有真人脸）
        单次 detect: \(stat(r.times))
        检到人脸数: \(r.count)（预期 0）
        这条只是地板值：证明"没有脸时代码路径跑得完"。判 Vision 是否真在工作要靠「照片正对照」。
        """
    }

    static func photoControl(url: URL) -> String {
        guard let loaded = UIImage(contentsOfFile: url.path), let base = loaded.cgImage else {
            return "照片正对照\n读不出这张图片（\(url.lastPathComponent)）"
        }
        var summary: [String] = []
        var best: (times: [Double], count: Int, detail: String, deg: Int, w: Int, h: Int)?
        var found = false
        for deg in [0, 90, 180, 270] {
            let candidate = deg == 0 ? base : (rotated(base, degrees: deg) ?? base)
            let r = detectRuns(candidate, runs: 4)
            summary.append("\(deg)°→\(r.count)")
            if r.count > 0 && !found {
                best = (r.times, r.count, r.detail, deg, candidate.width, candidate.height)
                found = true
            }
        }
        guard let hit = best else {
            let zero = detectRuns(base, runs: 5)
            return """
            照片正对照 \(url.lastPathComponent)  \(base.width)x\(base.height) exif方向=\(loaded.imageOrientation.rawValue)
            四个方向检出: \(summary.joined(separator: " "))
            单次 detect: \(stat(zero.times))
            结论: 一张照片四个方向都检不到脸。若这张照片里确实有正脸 ⇒ 容器里的 Vision 并没有真的推理，只是没报错。
            """
        }
        return """
        照片正对照 \(url.lastPathComponent)  原始 \(base.width)x\(base.height) exif方向=\(loaded.imageOrientation.rawValue)
        检出方向 \(hit.deg)°，送检尺寸 \(hit.w)x\(hit.h)，四个方向检出: \(summary.joined(separator: " "))
        检到 \(hit.count) 张脸  \(hit.detail)
        单次 detect: \(stat(hit.times))
        结论: Vision 在容器里确实在推理，上面的 ms 数才是真实单价。
        """
    }

    static func rotated(_ image: CGImage, degrees: Int) -> CGImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let size = (degrees == 90 || degrees == 270)
            ? CGSize(width: h, height: w)
            : CGSize(width: w, height: h)
        guard let ctx = CGContext(data: nil,
                                  width: Int(size.width),
                                  height: Int(size.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.rotate(by: CGFloat(degrees) * .pi / 180)
        ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage()
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
        return String(format: "avg %.2f / 中位 %.2f / max %.2f", avg, med, mx) + " ms（n=\(values.count)）"
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
