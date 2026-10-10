import Foundation
import UIKit
import AVFoundation
import CoreMedia
import CoreVideo
import CoreML
import Metal
import Photos
import PhotosUI
import QuartzCore

// MARK: - 现场读数

enum VRFacts {
    static func lines() -> [String] {
        let info = Bundle.main.infoDictionary ?? [:]
        let pi = ProcessInfo.processInfo
        return [
            "bundleId   \(Bundle.main.bundleIdentifier ?? "-")",
            "version    \(info["CFBundleShortVersionString"] ?? "-") (\(info["CFBundleVersion"] ?? "-"))",
            "iOS        \(pi.operatingSystemVersionString)",
            "machine    \(machineName())  cores=\(pi.processorCount)",
            "memory     足迹 \(footprintMB()) / 驻留 \(residentMB()) MB / 物理 \(pi.physicalMemory / 1048576) MB",
            "disk       可用 \(diskFreeGB()) GB",
            "endpoint   \(VRUploader.endpoint)",
            "Metal      \(VRTech.device == nil ? "起不来" : "可用 " + (VRTech.device?.name ?? "-"))",
            "深度模型   \(modelNote())",
            "AVFoundation \(NSClassFromString("AVAssetReader") != nil ? "可用" : "缺失")",
            "Vision     \(NSClassFromString("VNDetectFaceRectanglesRequest") != nil ? "可用" : "缺失")",
            "PhotosUI   \(NSClassFromString("PHPickerViewController") != nil ? "可用" : "缺失")"
        ]
    }

    /// 只认包里有哪个文件。绝不在主线程调 compileModel——那可能现场编几分钟。
    /// CI 是把 mlpackage 当普通目录拷进 .app 的，所以除了 Bundle.url 还要直接按路径摸。
    static func modelNote() -> String {
        let fm = FileManager.default
        func has(_ ext: String) -> Bool {
            if Bundle.main.url(forResource: VRDepth.resource, withExtension: ext) != nil { return true }
            for base in [Bundle.main.bundleURL, Bundle.main.resourceURL].compactMap({ $0 }) {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: base.appendingPathComponent("\(VRDepth.resource).\(ext)").path,
                                isDirectory: &isDir), isDir.boolValue { return true }
            }
            return false
        }
        if has("mlmodelc") { return "\(VRDepth.resource).mlmodelc 在包里" }
        if has("mlpackage") { return "\(VRDepth.resource).mlpackage 在包里（点自检才现场编译）" }
        return "包里没有深度模型：CI 那轮没把 mlpackage 拷进包"
    }

    static func diskFreeGB() -> String {
        guard let a = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let n = a[.systemFreeSize] as? NSNumber else { return "-" }
        return String(format: "%.1f", n.doubleValue / 1_073_741_824)
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

    /// jetsam 判杀看 phys_footprint，驻留在这台容器里小一个数量级，别拿它当水位。
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

/// 每一步往 Documents/vr_log.txt 追加一行（带水位）。闪退不清盘，重开就能看到死在第几步。
enum VRJournal {
    static var url: URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("vr_log.txt")
    }

    static func load() -> String {
        guard let url = url else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func line(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        // 一条一行：日志按行发给电脑，条目里夹换行会把后半句丢在传输外
        let oneLine = text.replacingOccurrences(of: "\n", with: " ／ ")
        let entry = "\(f.string(from: Date())) 足迹\(VRFacts.footprintMB())/驻留\(VRFacts.residentMB())MB \(oneLine)"
        guard let url = url else { return }
        var lines = load().split(separator: "\n").map(String.init)
        lines.append(entry)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        guard let data = lines.joined(separator: "\n").appending("\n").data(using: .utf8) else { return }
        try? data.write(to: url)
    }

    static func tail(_ n: Int) -> String {
        let lines = load().split(separator: "\n").map(String.init)
        if lines.isEmpty { return "磁盘日志是空的（\(url?.path ?? "拿不到 documents 目录")）" }
        return lines.suffix(n).joined(separator: "\n")
    }
}

enum VRPressure {
    static var sources: [DispatchSourceMemoryPressure] = []
    static var sawPressure = false

    static func reset() { sawPressure = false }

    static func start() {
        guard sources.isEmpty else { return }
        for (level, label) in [(DispatchSource.MemoryPressureEvent.warning, "警告"),
                               (DispatchSource.MemoryPressureEvent.critical, "严重")] {
            let src = DispatchSource.makeMemoryPressureSource(eventMask: level, queue: .main)
            src.setEventHandler {
                if level.contains(.critical) { sawPressure = true }
                VRJournal.line("内存压力\(label) 足迹\(VRFacts.footprintMB())MB")
            }
            src.resume()
            sources.append(src)
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            sawPressure = true
            VRJournal.line("didReceiveMemoryWarning 足迹\(VRFacts.footprintMB())MB")
        }
    }
}

enum VRUploader {
    /// 8712 归剪辑项目，这个 app 走自己的端口和自己的接收文件，两边别互相覆盖。
    static let endpoint = "http://192.168.31.99:8714/report"

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
            return "发到电脑：超时 20 s 无回音（手机到 192.168.31.99:8714 不通？电脑上的 8714 接收端没开？）"
        }
        if code < 0 { return "发到电脑：失败 \(failure)" }
        return "发到电脑：HTTP \(code) 回执 \(reply)（送出 \(text.count) 字符）"
    }
}

// MARK: - 小工具

enum VRUtil {
    static func ms(_ value: Double) -> String {
        return String(format: "%.2f ms", value)
    }

    static func stat(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "无数据" }
        let sorted = values.sorted()
        let avg = values.reduce(0, +) / Double(values.count)
        return String(format: "avg %.2f / 中位 %.2f / max %.2f", avg, sorted[sorted.count / 2],
                      sorted.last ?? 0) + " ms（n=\(values.count)）"
    }

    static func deg(_ tf: CGAffineTransform) -> Int {
        var d = Int((atan2(tf.b, tf.a) * 180 / .pi).rounded())
        if d < 0 { d += 360 }
        return d
    }

    /// 长边收进 longEdge，两边凑偶数（编码器要偶数尺寸）
    static func fitEven(_ w: Int, _ h: Int, longEdge: Int) -> (w: Int, h: Int) {
        let s = Double(longEdge) / Double(max(w, h))
        var nw = Int((Double(w) * s).rounded())
        var nh = Int((Double(h) * s).rounded())
        if nw % 2 != 0 { nw -= 1 }
        if nh % 2 != 0 { nh -= 1 }
        return (max(2, nw), max(2, nh))
    }

    static func fourcc(_ f: OSType) -> String {
        let b = [UInt8((f >> 24) & 0xFF), UInt8((f >> 16) & 0xFF), UInt8((f >> 8) & 0xFF), UInt8(f & 0xFF)]
        let s = String(bytes: b, encoding: .ascii) ?? "????"
        return s.map { $0.isLetter || $0.isNumber ? $0 : "?" }.joined()
    }

    /// 送检尺寸：短边贴 short，长边凑 14 的倍数（ViT 的 patch 网格要求），再夹进模型允许的区间
    static func modelSize(eyeW: Int, eyeH: Int, short: Int,
                          minW: Int, minH: Int, maxW: Int, maxH: Int) -> (w: Int, h: Int) {
        var w: Double
        var h: Double
        if eyeW <= eyeH {
            w = Double(short)
            h = (Double(short) * Double(eyeH) / Double(max(1, eyeW)) / 14.0).rounded() * 14.0
        } else {
            h = Double(short)
            w = (Double(short) * Double(eyeW) / Double(max(1, eyeH)) / 14.0).rounded() * 14.0
        }
        if maxW > 0 { w = min(w, Double(maxW)) }
        if maxH > 0 { h = min(h, Double(maxH)) }
        if minW > 0 { w = max(w, Double(minW)) }
        if minH > 0 { h = max(h, Double(minH)) }
        return (Int(w.rounded()), Int(h.rounded()))
    }
}

// MARK: - Metal 地基

enum VRTech {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static var queue: MTLCommandQueue? = device?.makeCommandQueue()
    static var cache: CVMetalTextureCache?
    static var libs: [String: MTLComputePipelineState] = [:]
    static var initNote = ""
    /// 从上次 commitWait 到现在造出的所有 CVMetalTexture，托住它们底下的 MTLTexture 别中途作废。
    static var keep: [CVMetalTexture] = []

    /// 一次性把 shader 编好。失败就把原因留在 initNote 里，界面直接显示——
    /// default.metallib 没进包这件事必须看得见，不能变成"按钮按了没反应"。
    static func boot() -> Bool {
        guard device == nil || libs.isEmpty else { return !libs.isEmpty }
        guard let dev = device, let q = queue else {
            initNote = "MTLCreateSystemDefaultDevice 或 makeCommandQueue 返回空"
            return false
        }
        queue = q
        var texCache: CVMetalTextureCache?
        let cvk = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &texCache)
        guard cvk == noErr, let tc = texCache else {
            initNote = "CVMetalTextureCacheCreate 失败 \(Int(cvk))"
            return false
        }
        cache = tc
        guard let library = dev.makeDefaultLibrary() else {
            initNote = "makeDefaultLibrary() 返回空：包里没有 default.metallib（CI 那轮 Shaders.metal 没被编进包）"
            return false
        }
        var bad: [String] = []
        for name in ["kScale", "kBack", "kSplatDepth", "kSplatColor", "kCombine", "kCopy"] {
            guard let fn = library.makeFunction(name: name) else {
                bad.append(name + "(没这个函数)")
                continue
            }
            do {
                libs[name] = try dev.makeComputePipelineState(function: fn)
            } catch {
                bad.append(name + "(编不出来)")
                VRJournal.line("kernel \(name) 建管线失败 \(error)")
            }
        }
        if !bad.isEmpty {
            initNote = "这几个 kernel 没编出来: \(bad.joined(separator: ",")}"
            return false
        }
        initNote = "Metal \(dev.name) 就绪，6 个 kernel 全在（纹理走 bgra8Unorm / rgba8Unorm）"
        VRJournal.line("Metal " + initNote)
        return true
    }

    static func texture(from pb: CVPixelBuffer, width: Int, height: Int)
        -> (tex: MTLTexture?, cv: CVMetalTexture?, note: String) {
        guard let tc = cache else { return (nil, nil, "Metal 没起来") }
        // 默认建出来的纹理只让读和采样，成片那块要往里写 ⇒ usage 里显式把 shaderWrite 也要上。
        // 键是 kCVMetalTextureUsage，值是一个数（option set 的位），不是数组。
        let usage = MTLTextureUsage([.shaderRead, .shaderSample, .shaderWrite])
        let attrs = [kCVMetalTextureUsage: NSNumber(value: usage.rawValue)] as CFDictionary
        var cvTex: CVMetalTexture?
        var r = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, tc, pb, attrs,
                                                          .bgra8Unorm, width, height, 0, &cvTex)
        var fellBack = ""
        if r != noErr || cvTex == nil {
            cvTex = nil
            let r2 = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, tc, pb, nil,
                                                               .bgra8Unorm, width, height, 0, &cvTex)
            if r2 == noErr, cvTex != nil {
                fellBack = "（带 write 的 usage 被拒，退回默认属性建的）"
                r = r2
            }
        }
        guard r == noErr, let ct = cvTex, let tex = CVMetalTextureGetTexture(ct) else {
            let f = CVPixelBufferGetPixelFormatType(pb)
            return (nil, nil, "像素缓冲转纹理失败 \(VRUtil.fourcc(f)) \(width)x\(height) 返回码 \(Int(r))")
        }
        // CVMetalTexture 一脱手，它底下的 MTLTexture 就作废 ⇒ 活着的这段路必须由 keep 托住，
        // commitWait 之后才放开；要跨帧用的（送检框）另外自己存一份引用。
        keep.append(ct)
        return (tex, ct, fellBack.isEmpty ? "-" : fellBack)
    }

    static func pixelBuffer(width: Int, height: Int,
                            format: OSType = kCVPixelFormatType_32BGRA) -> (pb: CVPixelBuffer?, note: String) {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        let r = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &pb)
        guard r == noErr, let out = pb else {
            return (nil, "CVPixelBufferCreate \(VRUtil.fourcc(format)) \(width)x\(height) 失败 \(Int(r))")
        }
        return (out, "-")
    }
}
