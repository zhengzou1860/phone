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
            "PhotosUI   \(NSClassFromString("PHPickerViewController") != nil ? "可用" : "缺失")",
            "身份 API   VNGenerateIdentity=\(cls("VNGenerateIdentityRequest")) "
                + "VNIdentityObs=\(cls("VNIdentityObservation"))",
            "替身 API   ImageFeaturePrint=\(cls("VNGenerateImageFeaturePrintRequest")) "
                + "FaceCaptureQuality=\(cls("VNDetectFaceCaptureQualityRequest"))",
            "分割 API   PersonSegmentation=\(cls("VNGeneratePersonSegmentationRequest")) "
                + "FaceLandmarks=\(cls("VNDetectFaceLandmarksRequest"))"
        ]
    }

    static func cls(_ name: String) -> String {
        return NSClassFromString(name) != nil ? "有" : "无"
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
        -> (first: Double, rest: [Double], count: Int, detail: String) {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        var first = -1.0
        var rest: [Double] = []
        var count = -1
        var detail = "-"
        for i in 0..<runs {
            let request = VNDetectFaceRectanglesRequest()
            let t0 = DispatchTime.now().uptimeNanoseconds
            do {
                try handler.perform([request])
            } catch {
                return (first, rest, -999, "perform 抛错: \(error)")
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            if i == 0 { first = ms } else { rest.append(ms) }
            let found = request.results ?? []
            count = found.count
            if let found_first = found.first {
                detail = "置信 \(found_first.confidence) 框 \(found_first.boundingBox)"
            }
        }
        return (first, rest, count, detail)
    }

    static func visionSelfTest() -> String {
        guard let image = syntheticImage(width: 720, height: 1280) else {
            return "Vision 自检\n生成测试图失败"
        }
        let r = detectRuns(image, runs: 6)
        return """
        合成图自检（\(image.width)x\(image.height)，里面没有真人脸）
        冷启动一次: \(ms(r.first))；同图再跑 5 次: \(stat(r.rest))
        检到人脸数: \(r.count)（预期 0）
        注意: 同一张图重复请求会命中 Vision 的结果缓存，后面那几个 ms 不是单价，冷启动那个才是量级参考。
        """
    }

    static func photoControl(url: URL) -> String {
        guard let loaded = UIImage(contentsOfFile: url.path), let base = loaded.cgImage else {
            return "照片正对照\n读不出这张图片（\(url.lastPathComponent)）"
        }
        var summary: [String] = []
        var best: (first: Double, rest: [Double], count: Int, detail: String, deg: Int, w: Int, h: Int)?
        var found = false
        for deg in [0, 90, 180, 270] {
            let candidate = deg == 0 ? base : (rotated(base, degrees: deg) ?? base)
            let r = detectRuns(candidate, runs: 4)
            summary.append("\(deg)°→\(r.count)")
            if r.count > 0 && !found {
                best = (r.first, r.rest, r.count, r.detail, deg, candidate.width, candidate.height)
                found = true
            }
        }
        var curve: [String] = []
        for longEdge in [max(base.width, base.height), 960, 640, 480, 320] {
            let small = scaled(base, longEdge: longEdge)
            let r = detectRuns(small, runs: 3)
            curve.append("\(small.width)x\(small.height):\(ms(r.first))/检\(r.count)")
        }
        guard let hit = best else {
            return """
            照片正对照 \(url.lastPathComponent)  \(base.width)x\(base.height) exif方向=\(loaded.imageOrientation.rawValue)
            四个方向检出: \(summary.joined(separator: " "))
            尺寸曲线(送检尺寸:冷启动ms/检到数): \(curve.joined(separator: " | "))
            结论: 一张照片四个方向都检不到脸。若这张照片里确实有正脸 ⇒ 容器里的 Vision 并没有真的推理，只是没报错。
            """
        }
        return """
        照片正对照 \(url.lastPathComponent)  原始 \(base.width)x\(base.height) exif方向=\(loaded.imageOrientation.rawValue)
        检出方向 \(hit.deg)°，送检尺寸 \(hit.w)x\(hit.h)，四个方向检出: \(summary.joined(separator: " "))
        检到 \(hit.count) 张脸  \(hit.detail)
        冷启动: \(ms(hit.first))；同图再跑 3 次: \(stat(hit.rest))
        尺寸曲线(送检尺寸:冷启动ms/检到数): \(curve.joined(separator: " | "))
        """
    }

    static func scaled(_ image: CGImage, longEdge: Int) -> CGImage {
        let srcLong = max(image.width, image.height)
        guard longEdge > 0, longEdge < srcLong else { return image }
        let ratio = CGFloat(longEdge) / CGFloat(srcLong)
        let w = max(1, Int(round(CGFloat(image.width) * ratio)))
        let h = max(1, Int(round(CGFloat(image.height) * ratio)))
        guard let ctx = CGContext(data: nil,
                                  width: w,
                                  height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage() ?? image
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
            return "视频基准\n找不到视频轨（\(url.lastPathComponent)）"
        }

        let duration = CMTimeGetSeconds(asset.duration)
        let nominal = track.nominalFrameRate
        let videoFps = nominal > 0 ? Double(nominal) : 30.0
        let sizeBytes: Int? = {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return attrs?[.size] as? Int
        }()
        let sizeText = sizeBytes.map { "\($0 / 1048576) MB" } ?? "-"

        let onlyDecode = videoPass(asset: asset, track: track, limit: frameLimit,
                                   target: nil, detect: false, videoFps: videoFps,
                                   duration: duration, tag: "只解码不检测")
        let native = videoPass(asset: asset, track: track, limit: frameLimit,
                               target: nil, detect: true, videoFps: videoFps,
                               duration: duration, tag: "解码+检测")
        var small = videoPass(asset: asset, track: track, limit: frameLimit,
                              target: nil, detect: true, videoFps: videoFps,
                              duration: duration, tag: "小尺寸(未启用)")
        let longSide = max(native.w, native.h)
        if longSide > 640 {
            let ratio = 640.0 / Double(longSide)
            let tw = max(16, Int(Double(native.w) * ratio)) & ~1
            let th = max(16, Int(Double(native.h) * ratio)) & ~1
            small = videoPass(asset: asset, track: track, limit: frameLimit,
                              target: (w: tw, h: th), detect: true, videoFps: videoFps,
                              duration: duration, tag: "解码+检测, 让解码器直出 \(tw)x\(th)")
        }

        return """
        视频基准 \(url.lastPathComponent)
        全长 \(String(format: "%.1f", duration)) s，\(String(format: "%.1f", videoFps)) fps，大小 \(sizeText)
        \(onlyDecode.text)
        \(native.text)
        \(small.text)
        """
    }

    static func videoPass(asset: AVURLAsset, track: AVAssetTrack, limit: Int,
                          target: (w: Int, h: Int)?, detect: Bool, videoFps: Double,
                          duration: Double, tag: String) -> (text: String, w: Int, h: Int) {
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if let target = target {
            settings[kCVPixelBufferWidthKey as String] = target.w
            settings[kCVPixelBufferHeightKey as String] = target.h
        }

        let readerResult: AVAssetReader?
        do {
            readerResult = try AVAssetReader(asset: asset)
        } catch {
            return ("[\(tag)] AVAssetReader 创建失败: \(error)", 0, 0)
        }
        guard let reader = readerResult else {
            return ("[\(tag)] AVAssetReader 返回 nil", 0, 0)
        }
        let outputResult: AVAssetReaderTrackOutput?
        do {
            outputResult = try AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        } catch {
            return ("[\(tag)] TrackOutput 创建失败: \(error)", 0, 0)
        }
        guard let output = outputResult else {
            return ("[\(tag)] TrackOutput 返回 nil（这套 outputSettings 不被支持）", 0, 0)
        }
        reader.add(output)
        guard reader.startReading() else {
            return ("[\(tag)] startReading 失败: \(reader.error?.localizedDescription ?? "-")", 0, 0)
        }

        var decodeTimes: [Double] = []
        var visionTimes: [Double] = []
        var faceTotals = 0
        var widest = 0
        var tallest = 0
        var frames = 0

        while frames < limit {
            let d0 = DispatchTime.now().uptimeNanoseconds
            guard let sample = output.copyNextSampleBuffer() else { break }
            let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - d0) / 1_000_000
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { break }
            if frames == 0 {
                widest = CVPixelBufferGetWidth(buffer)
                tallest = CVPixelBufferGetHeight(buffer)
            }

            var visionMs = 0.0
            if detect {
                let request = VNDetectFaceRectanglesRequest()
                let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
                let v0 = DispatchTime.now().uptimeNanoseconds
                do {
                    try handler.perform([request])
                } catch {
                    return ("[\(tag)] 第 \(frames + 1) 帧 Vision 抛错: \(error)", widest, tallest)
                }
                visionMs = Double(DispatchTime.now().uptimeNanoseconds - v0) / 1_000_000
                faceTotals += request.results?.count ?? 0
            }

            if frames >= 3 {
                decodeTimes.append(decodeMs)
                if detect { visionTimes.append(visionMs) }
            }
            frames += 1
        }

        guard frames > 3 else {
            return ("[\(tag)] 只解出 \(frames) 帧，不够计时（status=\(reader.status.rawValue)）", widest, tallest)
        }
        let decodeAvg = decodeTimes.reduce(0, +) / Double(decodeTimes.count)
        let visionAvg = visionTimes.isEmpty ? 0 : visionTimes.reduce(0, +) / Double(visionTimes.count)
        let perFrame = decodeAvg + visionAvg
        let serialFps = 1000.0 / max(perFrame, 0.001)
        let realtimeFactor = serialFps / videoFps
        let wholeClip = duration * videoFps / serialFps

        var line = "[\(tag)] \(frames) 帧 @ \(widest)x\(tallest)  取帧 \(stat(decodeTimes))"
        if detect {
            line += "\n  Vision \(stat(visionTimes))  检到脸 \(faceTotals)/\(frames) 帧"
        }
        line += "\n  合计 \(String(format: "%.1f", perFrame)) ms/帧 = \(String(format: "%.1f", serialFps)) 帧/秒 = \(String(format: "%.2f", realtimeFactor))x 实时；扫完整段 \(String(format: "%.1f", duration)) s 需 \(String(format: "%.1f", wholeClip)) s"
        return (line, widest, tallest)
    }

    static func ms(_ value: Double) -> String {
        return String(format: "%.2f ms", value)
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
