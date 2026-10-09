import SwiftUI
import Foundation
import Darwin
import UIKit
import AVFoundation
import CoreMedia
import CoreVideo
import Vision
import CoreML
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

struct BenchView: View {
    @ObservedObject var bench: Bench

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
                Picker("单趟取帧上限", selection: $bench.frameLimit) {
                    Text("90 帧").tag(90)
                    Text("600 帧").tag(600)
                    Text("2000 帧").tag(2000)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                Picker("同一条连跑遍数", selection: $bench.repeatCount) {
                    Text("1 遍").tag(1)
                    Text("3 遍").tag(3)
                    Text("6 遍").tag(6)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                Picker("扫描出图尺寸", selection: $bench.scanLongEdge) {
                    Text("满尺寸").tag(0)
                    Text("长边 960").tag(960)
                    Text("长边 640").tag(640)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                Picker("reader 分块", selection: $bench.chunkFrames) {
                    Text("整片一个").tag(0)
                    Text("每 300 帧").tag(300)
                    Text("每 100 帧").tag(100)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                HStack(spacing: 10) {
                    Button("选视频跑基准") { bench.showVideoPicker = true }
                    Button("尺子自检") { bench.startModel() }
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

                DisclosureGroup("磁盘日志（闪退后重开还在）") {
                    Text(Journal.tail(12))
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
            }
            .padding()
        }
        .fullScreenCover(isPresented: $bench.showVideoPicker) {
            // onPicked 留空是故意的：自检页现在能用，finishPick 自己会收 cover，这轮不动它的行为
            PickerHost(target: .video, onPicked: {}) { url, msg in bench.finishPick(url: url, failMessage: msg, target: .video) }
        }
        .fullScreenCover(isPresented: $bench.showPhotoPicker) {
            PickerHost(target: .photo, onPicked: {}) { url, msg in bench.finishPick(url: url, failMessage: msg, target: .photo) }
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
    @Published var frameLimit = 90
    @Published var repeatCount = 1
    @Published var scanLongEdge = 0
    @Published var chunkFrames = 0

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        Journal.line("=== 启动 v\(info["CFBundleShortVersionString"] ?? "-") ===")
        PressureWatch.start()
    }

    func finish(_ report: String) {
        log.append(report)
        if log.count > 8 { log.removeFirst(log.count - 8) }
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
        let limit = frameLimit
        let times = repeatCount
        let edge = scanLongEdge
        let chunk = chunkFrames
        PressureWatch.reset()
        status = "视频基准运行中…（上限 \(limit) 帧 ×\(times) 遍，"
            + "\(edge == 0 ? "满尺寸" : "长边\(edge)")，\(chunk == 0 ? "不分块" : "每\(chunk)帧换 reader")）"
        Task.detached { [weak self] in
            let report = Runner.videoBenchmark(url: url, frameLimit: limit, repeatCount: times,
                                               longEdge: edge, chunkFrames: chunk)
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

    func startModel() {
        busy = true
        status = "尺子自检中…（加载 + 200 次 predict）"
        Task.detached { [weak self] in
            let report = ModelBench.probe(runs: 200)
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
            + "\n\n—— 磁盘日志最近 150 行 ——\n" + Journal.tail(150)
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
    let target: PickTarget
    /// 刚选完、后台还在把文件拷出相册时回调一次。相册拷贝对大视频能有十几秒，
    /// cover 不等它就立刻收起，主界面先显示"取文件中…"，不然看着像卡死在选择页。
    let onPicked: () -> Void
    let onDone: (URL?, String?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = target == .video ? .videos : .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(target, onPicked, onDone) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let target: PickTarget
        let onPicked: () -> Void
        let onDone: (URL?, String?) -> Void

        init(_ target: PickTarget, _ onPicked: @escaping () -> Void, _ onDone: @escaping (URL?, String?) -> Void) {
            self.target = target
            self.onPicked = onPicked
            self.onDone = onDone
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                report(nil, "没选到文件")
                return
            }
            let cb = self.onPicked
            Task { @MainActor in cb() }
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
            let onDone = self.onDone
            Task { @MainActor in
                onDone(url, failMessage)
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
            "memory     足迹 \(footprintMB()) / 驻留 \(residentMB()) MB / 物理 \(pi.physicalMemory / 1048576) MB",
            "endpoint   \(Uploader.endpoint)",
            "Vision     \(NSClassFromString("VNDetectFaceRectanglesRequest") != nil ? "可用" : "缺失")",
            "AVFoundation \(NSClassFromString("AVAssetReader") != nil ? "可用" : "缺失")",
            "PhotosUI   \(NSClassFromString("PHPickerViewController") != nil ? "可用" : "缺失")",
            "包内尺子   \(modelNote())",
            "身份尺候选 VNGenerateIdentityFeaturePrint=\(cls("VNGenerateIdentityFeaturePrintRequest")) "
                + "VNFeaturePrintObs=\(cls("VNFeaturePrintObservation"))",
            "替身 API   ImageFeaturePrint=\(cls("VNGenerateImageFeaturePrintRequest")) "
                + "FaceCaptureQuality=\(cls("VNDetectFaceCaptureQualityRequest"))",
            "分割 API   PersonSegmentation=\(cls("VNGeneratePersonSegmentationRequest")) "
                + "FaceLandmarks=\(cls("VNDetectFaceLandmarksRequest"))"
        ]
    }

    /// 只认包里有哪个文件，绝不在主线程调 locate()——那可能触发一次现场编译。
    static func modelNote() -> String {
        if Bundle.main.url(forResource: "mbf", withExtension: "mlmodelc") != nil {
            return "mbf.mlmodelc 在包里"
        }
        if Bundle.main.url(forResource: "mbf", withExtension: "mlpackage") != nil {
            return "mbf.mlpackage 在包里（点自检时才现场编译）"
        }
        return "包里没有模型：CI 那轮 onnx→CoreML 没成"
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

    /// jetsam 判杀用的是 phys_footprint，不是 resident_size。上一版我只读了后者，
    /// 于是"峰值 348 MB 离 1500 MB 还远"这句根本不成立——两把尺子不是一回事。
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size)
            / mach_msg_type_number_t(MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint) / 1_048_576
    }
}

/// 每一步都往 Documents/hello_log.txt 追加一行（带内存水位）。
/// 闪退不会清掉它，重开就能看到"死在第几步、当时驻留多少 MB"——
/// 没有 Mac 时这是唯一能拿到的现场证据。写盘失败一律不许把 app 带崩。
enum Journal {
    static var url: URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("hello_log.txt")
    }

    static func load() -> String {
        guard let url = url else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func line(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        // 一条一行：日志是按行发给电脑的，条目里夹 \n 会把后半句丢在传输外（0.9 的「朝向」那半句就这么没了）
        let oneLine = text.replacingOccurrences(of: "\n", with: " ／ ")
        let entry = "\(f.string(from: Date())) 足迹\(Facts.footprintMB())/驻留\(Facts.residentMB())MB \(oneLine)"
        guard let url = url else { return }
        var lines = load().split(separator: "\n").map(String.init)
        lines.append(entry)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        guard let data = lines.joined(separator: "\n").appending("\n").data(using: .utf8) else { return }
        try? data.write(to: url)
    }

    static func tail(_ n: Int) -> String {
        let lines = load().split(separator: "\n").map(String.init)
        if lines.isEmpty { return "磁盘日志是空的（\(url?.path ?? "拿不到 documents 目录")）" }
        return lines.suffix(n).joined(separator: "\n")
    }
}

/// 闪退取证第二道闸：系统真要杀，通常会先喊内存压力。喊过 → 内存成因；
/// 一声没喊就死 → 不是内存，得换方向查（原生崩溃 / 容器层）。
enum PressureWatch {
    static var sources: [DispatchSourceMemoryPressure] = []
    static var sawPressure = false

    static func reset() { sawPressure = false }

    static func start() {
        guard sources.isEmpty else { return }
        watch(.warning, "警告")
        watch(.critical, "严重")
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            sawPressure = true
            Journal.line("didReceiveMemoryWarning 足迹\(Facts.footprintMB())MB")
        }
    }

    private static func watch(_ level: DispatchSource.MemoryPressureEvent, _ label: String) {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: level, queue: .main)
        src.setEventHandler {
            if level.contains(.critical) { sawPressure = true }
            Journal.line("内存压力\(label) 足迹\(Facts.footprintMB())MB")
        }
        src.resume()
        sources.append(src)
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

    /// 帧循环里 autoreleasepool 闭包只能"记个原因再 return"，用它把原因带到循环外面判定。
    private enum FrameStop {
        case none
        case sourceEnd
        case broken(String)
        case memoryStop(String)
    }

    /// 0.6.4 实测：满尺寸解码+检测那一趟足迹涨到 1682 MB 时系统才喊压力。
    /// 收兵线取它的一半多一点——真到 1682 才停就要赌系统先喊还是先杀。
    static let footprintStopMB = 900

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

    /// 动态起一个 feature print 请求。返回 nil = 这个系统里根本没这个类。
    static func featurePrint(_ name: String, _ image: CGImage)
        -> (obs: [Any], ms: Double, note: String)? {
        guard let cls = NSClassFromString(name) as? NSObject.Type else { return nil }
        let made = cls.init()
        guard let vn = made as? VNRequest else {
            return ([], -1, "有类但不是 VNRequest，交不给 handler")
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            try handler.perform([vn])
        } catch {
            return ([], -1, "perform 抛错: \(error)")
        }
        let spent = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        let raw = (vn.value(forKey: "results") as? [Any]) ?? []
        return (raw, spent, "-")
    }

    static func vecOf(_ observation: Any) -> [Double] {
        guard let fp = observation as? VNFeaturePrintObservation else { return [] }
        return fp.data.withUnsafeBytes { raw in
            raw.bindMemory(to: Float32.self).map { Double($0) }
        }
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -9 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return -9 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// 同一张脸的几种轻微变化，print 之间还剩多少一致性
    static func printProbe(_ images: [(String, CGImage)]) -> String {
        var out: [String] = ["feature print 探测（同一张脸做变化，余弦越接近 1 越像“身份不变”）"]
        for name in ["VNGenerateIdentityFeaturePrintRequest", "VNGenerateImageFeaturePrintRequest"] {
            guard let first = featurePrint(name, images[0].1) else {
                out.append("  \(name): 系统里没有这个类")
                continue
            }
            if first.note != "-" {
                out.append("  \(name): \(first.note)")
                continue
            }
            guard let obs = first.obs.first else {
                out.append("  \(name): 跑通 \(ms(first.ms))，但 observation 0 条（这张图里没它要的东西）")
                continue
            }
            var vecs: [(String, [Double])] = [(images[0].0, vecOf(obs))]
            for (label, img) in images.dropFirst() {
                guard let r = featurePrint(name, img), let o = r.obs.first else { continue }
                vecs.append((label, vecOf(o)))
            }
            let baseVec = vecs[0].1
            let pairs = vecs.dropFirst().map { "\($0.0) vs 基准 = \($0.1.isEmpty || baseVec.isEmpty ? "无data" : String(format: "%.4f", cosine(baseVec, $0.1)))" }
            out.append("  \(name): 跑通 \(ms(first.ms)) obs=\(first.obs.count) "
                + "类型 \(type(of: obs)) data=\((obs as? VNFeaturePrintObservation)?.data.count ?? -1)B")
            for p in pairs { out.append("      \(p)") }
        }
        return out.joined(separator: "\n")
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
        \(printProbe([("合成图", image)]))
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
        \(facePrintProbe(base, degrees: hit.deg))
        """
    }

    static func facePrintProbe(_ base: CGImage, degrees: Int) -> String {
        let candidate = degrees == 0 ? base : (rotated(base, degrees: degrees) ?? base)
        let req = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: candidate, orientation: .up, options: [:])
                .perform([req])) != nil,
              let box = req.results?.first?.boundingBox else {
            return "feature print 探测\n  重检 boundingBox 失败"
        }
        let rect = CGRect(x: box.minX * CGFloat(candidate.width),
                          y: box.minY * CGFloat(candidate.height),
                          width: box.width * CGFloat(candidate.width),
                          height: box.height * CGFloat(candidate.height))
        guard let face = candidate.cropping(to: rect.integral), face.width > 20, face.height > 20 else {
            return "feature print 探测\n  脸太小裁不出来（\(Int(rect.width))x\(Int(rect.height))）"
        }
        return printProbe([("脸\(face.width)x\(face.height)", face),
                           ("右旋15°", rotated(face, degrees: 15) ?? face),
                           ("缩小一半", scaled(face, longEdge: max(face.width, face.height) / 2))])
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

    static func videoBenchmark(url: URL, frameLimit: Int, repeatCount: Int = 1,
                               longEdge: Int = 0, chunkFrames: Int = 0) -> String {
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
        let nat = track.naturalSize.applying(track.preferredTransform)
        let natW = abs(Double(nat.width)), natH = abs(Double(nat.height))
        let sizeBytes: Int? = {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return attrs?[.size] as? Int
        }()
        let sizeText = sizeBytes.map { "\($0 / 1048576) MB" } ?? "-"
        let memBegin = Facts.footprintMB()
        Journal.line("视频基准 开始 \(url.lastPathComponent) 源 \(String(format: "%.0fx%.0f", natW, natH)) "
                     + "\(String(format: "%.1f", duration))s@\(String(format: "%.0f", videoFps))fps \(sizeText)"
                     + " 上限\(frameLimit)帧×\(repeatCount)遍 尺寸\(longEdge == 0 ? "满" : "长边\(longEdge)")"
                     + " 块\(chunkFrames == 0 ? "不分" : "\(chunkFrames)帧") 足迹\(memBegin)MB")

        // 地板：满尺寸只解码不检测，一个 reader 到底。0.6.3 实测这一趟 2000 帧很稳，
        // 死的全部是"解码+检测"那一趟，所以它留作对照，不参与尺寸/分块开关。
        let onlyDecode = videoPass(asset: asset, track: track, limit: frameLimit,
                                   target: nil, detect: false, videoFps: videoFps,
                                   duration: duration, tag: "只解码不检测（地板）")

        let target: (w: Int, h: Int)?
        if longEdge == 0 {
            target = max(natW, natH) > 1920 ? fitSize(Int(natW), Int(natH), longEdge: 1920) : nil
        } else {
            target = fitSize(Int(natW), Int(natH), longEdge: longEdge)
        }
        let baseTag = target.map { "解码+检测 直出\($0.w)x\($0.h)" } ?? "解码+检测 满尺寸"

        var passTexts: [String] = []
        for it in 1...max(1, repeatCount) {
            if PressureWatch.sawPressure {
                passTexts.append("[第 \(it) 遍没跑] 前面已经把系统逼到内存压力，再跑就是找死")
                break
            }
            let r = videoPass(asset: asset, track: track, limit: frameLimit,
                              target: target, detect: true, videoFps: videoFps, duration: duration,
                              tag: repeatCount > 1 ? "\(baseTag) 第\(it)/\(repeatCount)遍" : baseTag,
                              chunkFrames: chunkFrames)
            passTexts.append(r.text)
            if r.frames == 0 { break }
        }

        let memEnd = Facts.footprintMB()
        Journal.line("视频基准 结束 \(url.lastPathComponent) 足迹 \(memEnd) MB（进这条时 \(memBegin)）")
        return """
        视频基准 \(url.lastPathComponent)
        源尺寸 \(String(format: "%.0fx%.0f", natW, natH))，全长 \(String(format: "%.1f", duration)) s，\(String(format: "%.1f", videoFps)) fps，大小 \(sizeText)
        \(onlyDecode.text)
        \(passTexts.joined(separator: "\n"))
        这条跑完 足迹 \(memBegin)→\(memEnd) MB（+\(memEnd - memBegin)）
        """
    }

    /// 按长边等比缩放，宽高都取偶数（解码器对小数的处理不一致，钉成整数才可比）
    static func fitSize(_ w: Int, _ h: Int, longEdge: Int) -> (w: Int, h: Int) {
        let long = max(w, h)
        guard long > longEdge else { return (w & ~1, h & ~1) }
        let ratio = Double(longEdge) / Double(long)
        return (max(16, Int(Double(w) * ratio)) & ~1, max(16, Int(Double(h) * ratio)) & ~1)
    }

    static func videoPass(asset: AVURLAsset, track: AVAssetTrack, limit: Int,
                          target: (w: Int, h: Int)?, detect: Bool, videoFps: Double,
                          duration: Double, tag: String,
                          chunkFrames: Int = 0) -> (text: String, w: Int, h: Int, frames: Int) {
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if let target = target {
            settings[kCVPixelBufferWidthKey as String] = target.w
            settings[kCVPixelBufferHeightKey as String] = target.h
        }

        var decodeTimes: [Double] = []
        var visionTimes: [Double] = []
        var faceTotals = 0
        var facePx: [Double] = []
        var widest = 0
        var tallest = 0
        var frames = 0
        var chunks = 0
        var failNote = ""
        let mem0 = Facts.footprintMB()
        var memMax = mem0
        var stopReason = ""
        let chunk = chunkFrames > 0 ? chunkFrames : limit
        // 一趟只造一个 request。0.6.4 每帧新建 request/handler，这些 ObjC 中间对象全落在
        // 自动释放池里，要等整趟结束才回收——足迹就是这么涨到 1682 MB 的。
        let request = VNDetectFaceRectanglesRequest()

        while frames < limit {
            let readerResult: AVAssetReader?
            do {
                readerResult = try AVAssetReader(asset: asset)
            } catch {
                failNote = "AVAssetReader 建不起来: \(error)"
                break
            }
            guard let reader = readerResult else {
                failNote = "AVAssetReader 返回 nil"
                break
            }
            let outputResult: AVAssetReaderTrackOutput?
            do {
                outputResult = try AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            } catch {
                failNote = "TrackOutput 创建失败: \(error)"
                break
            }
            guard let output = outputResult else {
                failNote = "TrackOutput 返回 nil（这套 outputSettings 不被支持）"
                break
            }
            chunks += 1
            let from = Double(frames) / max(videoFps, 1)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: from, preferredTimescale: 600),
                duration: CMTime(seconds: Double(min(chunk, limit - frames)) / max(videoFps, 1) + 0.2,
                                 preferredTimescale: 600))
            reader.add(output)
            guard reader.startReading() else {
                failNote = "第 \(chunks) 块 startReading 失败: \(reader.error?.localizedDescription ?? "-")"
                break
            }
            Journal.line("块 \(chunks) 起于 \(String(format: "%.2f", from))s 足迹\(Facts.footprintMB())MB")

            var inChunk = 0
            var exhausted = false
            while frames < limit {
                // autoreleasepool 按帧回收：池子在这一行结束时就清空，Vision 那一帧的中间对象不会活到趟末
                var stop: FrameStop = .none
                autoreleasepool {
                    let d0 = DispatchTime.now().uptimeNanoseconds
                    guard let sample = output.copyNextSampleBuffer() else {
                        stop = .sourceEnd
                        return
                    }
                    let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - d0) / 1_000_000
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                        stop = .broken("第 \(frames + 1) 帧 sample 里没有像素缓冲")
                        return
                    }
                    if frames == 0 {
                        widest = CVPixelBufferGetWidth(buffer)
                        tallest = CVPixelBufferGetHeight(buffer)
                    }

                    var visionMs = 0.0
                    if detect {
                        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
                        let v0 = DispatchTime.now().uptimeNanoseconds
                        do {
                            try handler.perform([request])
                        } catch {
                            stop = .broken("第 \(frames + 1) 帧 Vision 抛错: \(error)")
                            return
                        }
                        visionMs = Double(DispatchTime.now().uptimeNanoseconds - v0) / 1_000_000
                        let faces = request.results ?? []
                        faceTotals += faces.count
                        var bestW = 0.0
                        var bestH = 0.0
                        for f in faces {
                            let pw = Double(f.boundingBox.width) * Double(widest)
                            let ph = Double(f.boundingBox.height) * Double(tallest)
                            if pw * ph > bestW * bestH { bestW = pw; bestH = ph }
                        }
                        if bestW > 0 { facePx.append(min(bestW, bestH)) }
                    }

                    if frames >= 3 {
                        decodeTimes.append(decodeMs)
                        if detect { visionTimes.append(visionMs) }
                    }
                    frames += 1
                    inChunk += 1
                    let now = Facts.footprintMB()
                    if now > memMax { memMax = now }
                    if PressureWatch.sawPressure {
                        stop = .memoryStop("系统已喊内存压力，足迹 \(now) MB")
                        return
                    }
                    if now > Runner.footprintStopMB {
                        stop = .memoryStop("足迹 \(now) MB 超过收兵线 \(Runner.footprintStopMB) MB")
                        return
                    }
                    if frames % 30 == 0 {
                        Journal.line("心跳 \(tag) 第\(frames)帧 足迹\(now)MB")
                    }
                }
                switch stop {
                case .none: continue
                case .sourceEnd: exhausted = true
                case .broken(let msg):
                    failNote = msg
                    Journal.line("趟 中止 \(tag) \(failNote)")
                case .memoryStop(let msg):
                    stopReason = msg + "（第 \(frames) 帧收兵）"
                    Journal.line("趟 收兵 \(tag) \(stopReason)")
                }
                break
            }
            reader.cancelReading()
            if exhausted || !stopReason.isEmpty || !failNote.isEmpty || inChunk == 0 { break }
        }
        Journal.line("趟 结束 \(tag) 帧=\(frames) 块=\(chunks) 峰值足迹=\(memMax)MB"
                     + (stopReason.isEmpty ? "" : "（\(stopReason)）")
                     + (failNote.isEmpty ? "" : " \(failNote)"))

        guard frames > 3 else {
            return ("[\(tag)] 只解出 \(frames) 帧\(failNote.isEmpty ? "" : "，\(failNote)")", widest, tallest, frames)
        }
        let decodeAvg = decodeTimes.reduce(0, +) / Double(decodeTimes.count)
        let visionAvg = visionTimes.isEmpty ? 0 : visionTimes.reduce(0, +) / Double(visionTimes.count)
        let perFrame = decodeAvg + visionAvg
        let serialFps = 1000.0 / max(perFrame, 0.001)
        let realtimeFactor = serialFps / videoFps
        let wholeClip = duration * videoFps / serialFps

        var line = "[\(tag)] \(frames) 帧 @ \(widest)x\(tallest)（\(chunks) 块） 取帧 \(stat(decodeTimes))"
        let slope = frames > 5 ? Double(memMax - mem0) / Double(frames) : 0
        line += "\n  足迹 \(mem0)→\(Facts.footprintMB()) MB，本趟峰值 \(memMax) MB"
            + "（每帧约 \(String(format: slope < 0.1 ? "%.2f" : "%.1f", slope)) MB）"
        if !stopReason.isEmpty {
            line += "\n  半趟收兵：\(stopReason)"
        }
        if !failNote.isEmpty { line += "｜\(failNote)" }
        if detect {
            line += "\n  Vision \(stat(visionTimes))  检到脸 \(faceTotals)/\(frames) 帧"
            if facePx.isEmpty {
                line += "\n  脸短边 px：这 \(frames) 帧一张脸都没检到"
            } else {
                let sp = facePx.sorted()
                var below = 0
                for v in facePx where v < 96 { below += 1 }
                line += "\n  脸短边 px（直出尺寸下量）最小 \(String(format: "%.0f", sp[0]))"
                    + " 中位 \(String(format: "%.0f", sp[sp.count / 2]))"
                    + " 最大 \(String(format: "%.0f", sp[sp.count - 1]))"
                    + "｜低于 96 px 的 \(below)/\(sp.count) 帧"
            }
        }
        line += "\n  合计 \(String(format: "%.1f", perFrame)) ms/帧 = \(String(format: "%.1f", serialFps)) 帧/秒 = \(String(format: "%.2f", realtimeFactor))x 实时；扫完整段 \(String(format: "%.1f", duration)) s 需 \(String(format: "%.1f", wholeClip)) s"
        return (line, widest, tallest, frames)
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

/// 包里的身份尺（CI 用 onnx2coreml 现转的 mbf）能不能在 A13 上加载、每个 compute unit
/// 谁接、一次多少钱。这是"系统不认这个模型"这句话唯一的判据——PC 上转得再顺，
/// 加载不了就是零。
enum ModelBench {

    static var seed: UInt64 = 0x9E3_779B9_7F4A_7C15

    static func rand01() -> Double {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return Double(seed % 100_000) / 100_000.0
    }

    static var cachedModel: (url: URL?, note: String)?

    static func locate() -> (url: URL?, note: String) {
        if let c = cachedModel { return c }
        let found: (url: URL?, note: String)
        if let u = Bundle.main.url(forResource: "mbf", withExtension: "mlmodelc") {
            found = (u, "包里带的是已编译 mlmodelc")
        } else if let u = Bundle.main.url(forResource: "mbf", withExtension: "mlpackage") {
            do {
                found = (try MLModel.compileModel(at: u), "包里是 mlpackage，现场编译成功")
            } catch {
                found = (nil, "mlpackage 现场编译失败: \(error)")
            }
        } else {
            found = (nil, "包里没有 mbf.mlmodelc 也没有 mbf.mlpackage")
        }
        cachedModel = found
        return found
    }

    /// 按模型自己声明的输入形状造数据：浮点多数组就喂 [-1,1]（对应 (像素-127.5)/128），
    /// 图像输入就喂随机 BGRA。造好几份轮换着用，同一份输入反复 predict 会命中缓存。
    static func makeInputs(_ model: MLModel, count: Int) -> (list: [MLFeatureProvider], note: String) {
        let md = model.modelDescription
        guard let name = md.inputDescriptionsByName.keys.first,
              let desc = md.inputDescriptionsByName[name] else {
            return ([], "模型没有输入描述")
        }
        var list: [MLFeatureProvider] = []
        if desc.type == .multiArray, let c = desc.multiArrayConstraint {
            let dims = c.shape.map { max(1, $0.intValue) }
            let total = dims.reduce(1, *)
            for _ in 0..<count {
                let arr: MLMultiArray
                do {
                    arr = try MLMultiArray(shape: dims.map { NSNumber(value: $0) }, dataType: c.dataType)
                } catch {
                    return ([], "造 MLMultiArray 失败 dims=\(dims): \(error)")
                }
                switch arr.dataType {
                case .float32:
                    let p = arr.dataPointer.assumingMemoryBound(to: Float32.self)
                    for i in 0..<total { p[i] = Float32(rand01() * 2 - 1) }
                case .float16:
                    let p = arr.dataPointer.assumingMemoryBound(to: Float16.self)
                    for i in 0..<total { p[i] = Float16(rand01() * 2 - 1) }
                case .float64:
                    let p = arr.dataPointer.assumingMemoryBound(to: Double.self)
                    for i in 0..<total { p[i] = rand01() * 2 - 1 }
                default:
                    return ([], "多数组元素类型 \(arr.dataType.rawValue) 我还不会填")
                }
                do {
                    list.append(try MLDictionaryFeatureProvider(dictionary: [name: MLFeatureValue(multiArray: arr)]))
                } catch {
                    return ([], "造 multiArray feature provider 失败: \(error)")
                }
            }
            return (list, "输入 \(name) multiArray dims=\(dims) 类型 \(c.dataType.rawValue)")
        }
        if desc.type == .image, let ic = desc.imageConstraint {
            let w = ic.pixelsWide > 0 ? ic.pixelsWide : 112
            let h = ic.pixelsHigh > 0 ? ic.pixelsHigh : 112
            let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
            for _ in 0..<count {
                var pb: CVPixelBuffer?
                if CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                       attrs as CFDictionary, &pb) != noErr, pb == nil {
                    return ([], "造 pixel buffer 失败 \(w)x\(h)")
                }
                guard let buf = pb else { continue }
                CVPixelBufferLockBaseAddress(buf, [])
                if let base = CVPixelBufferGetBaseAddress(buf) {
                    let bytes = CVPixelBufferGetDataSize(buf)
                    let p = base.assumingMemoryBound(to: UInt8.self)
                    for i in 0..<bytes { p[i] = UInt8(rand01() * 255) }
                }
                CVPixelBufferUnlockBaseAddress(buf, [])
                do {
                    list.append(try MLDictionaryFeatureProvider(dictionary: [name: MLFeatureValue(pixelBuffer: buf)]))
                } catch {
                    return ([], "造 image feature provider 失败: \(error)")
                }
            }
            return (list, "输入 \(name) image \(w)x\(h)")
        }
        return ([], "输入 \(name) 类型 \(desc.type.rawValue) 我还不会喂")
    }

    static func predict(_ model: MLModel, inputs: [MLFeatureProvider], runs: Int) -> (ms: [Double], note: String) {
        var times: [Double] = []
        for i in 0..<runs {
            let f = inputs[i % inputs.count]
            let t0 = DispatchTime.now().uptimeNanoseconds
            do {
                _ = try model.prediction(from: f)
            } catch {
                return (times, "第 \(i) 次 predict 抛错: \(error)")
            }
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        }
        return (times, "-")
    }

    static func digest(_ model: MLModel, inputs: [MLFeatureProvider]) -> String {
        guard let md = model.modelDescription.outputDescriptionsByName.keys.first,
              let res = try? model.prediction(from: inputs[0]),
              let v = res.featureValue(for: md), let arr = v.multiArrayValue else {
            return "输出去哪看：\(model.modelDescription.outputDescriptionsByName.keys.joined(separator: ","))（取不到 multiArray）"
        }
        let n = arr.count
        let p = arr.dataPointer.assumingMemoryBound(to: Float32.self)
        var sum = 0.0
        for i in 0..<n { sum += Double(p[i]) * Double(p[i]) }
        let head = (0..<min(4, n)).map { String(format: "%.4f", p[$0]) }.joined(separator: ", ")
        return "输出 \(md) 维数 \(n) 模长 \(String(format: "%.2f", sum.squareRoot())) 前4维 [\(head)]"
    }

    static func probe(runs: Int) -> String {
        var out: [String] = ["身份尺自检（包里的 mbf，转换器的数值对齐在 CI 只有 43 dB）"]
        let found = locate()
        guard let modelURL = found.url else {
            out.append("  \(found.note)")
            return out.joined(separator: "\n")
        }
        out.append("  \(found.note)")
        for unit in [("cpuAndNeuralEngine", MLComputeUnits.cpuAndNeuralEngine),
                     ("cpuAndGPU", MLComputeUnits.cpuAndGPU),
                     ("all", MLComputeUnits.all),
                     ("cpuOnly", MLComputeUnits.cpuOnly)] {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = unit.1
            let t0 = DispatchTime.now().uptimeNanoseconds
            guard let model = try? MLModel(contentsOf: modelURL, configuration: cfg) else {
                out.append("  \(unit.0): 加载失败")
                continue
            }
            let loadMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            let made = makeInputs(model, count: 8)
            guard !made.list.isEmpty else {
                out.append("  \(unit.0): 加载成功 \(Runner.ms(loadMs))，但\(made.note)")
                continue
            }
            let warm = predict(model, inputs: made.list, runs: 5)
            let timed = predict(model, inputs: made.list, runs: runs)
            out.append("  \(unit.0): 加载 \(Runner.ms(loadMs))｜预热5次 \(Runner.stat(warm.ms))｜正式 \(runs) 次 \(Runner.stat(timed.ms))")
            if timed.note != "-" { out.append("      \(timed.note)") }
            if unit.0 == "cpuAndNeuralEngine" || unit.0 == "cpuOnly" {
                out.append("      \(made.note)")
                out.append("      \(digest(model, inputs: made.list))")
            }
        }
        out.append("  对照：本机 PC 钉 CPU 单线程 22.48 ms/帧；ANE 若真吃到应当远低于这个数")
        return out.joined(separator: "\n")
    }

}

