import Foundation
import UIKit
import CoreML

// MARK: - 现场读数

enum SwapFacts {
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
            "endpoint   \(SwapUploader.endpoint)",
            "CoreML     \(NSClassFromString("MLModel") != nil ? "可用" : "缺失")",
            "Vision     \(NSClassFromString("VNDetectFaceLandmarksRequest") != nil ? "可用" : "缺失")",
            "换脸网     \(modelNote())"
        ]
    }

    /// 只认包里有哪个文件。绝不在主线程调 compileModel——那可能现场编几分钟。
    /// CI 是把 mlpackage 当普通目录拷进 .app 的，所以除了 Bundle.url 还要直接按路径摸。
    static func modelNote() -> String {
        let fm = FileManager.default
        func has(_ ext: String) -> Bool {
            if Bundle.main.url(forResource: SwapBench.resource, withExtension: ext) != nil { return true }
            for base in [Bundle.main.bundleURL, Bundle.main.resourceURL].compactMap({ $0 }) {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: base.appendingPathComponent("\(SwapBench.resource).\(ext)").path,
                                isDirectory: &isDir), isDir.boolValue { return true }
            }
            return false
        }
        if has("mlmodelc") { return "\(SwapBench.resource).mlmodelc 在包里" }
        if has("mlpackage") { return "\(SwapBench.resource).mlpackage 在包里（点自检才现场编译）" }
        return "包里没有换脸网：CI 那轮没把 mlpackage 拷进包"
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

/// 每一步往 Documents/swap_log.txt 追加一行（带水位）。闪退不清盘，重开就能看到死在第几步。
enum SwapJournal {
    static var url: URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("swap_log.txt")
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
        let entry = "\(f.string(from: Date())) 足迹\(SwapFacts.footprintMB())/驻留\(SwapFacts.residentMB())MB \(oneLine)"
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

enum SwapUploader {
    /// 8712 剪辑 / 8714 VR3D / 8715 Voice，这个 app 走 8716 和自己的接收文件。
    static let endpoint = "http://192.168.31.99:8716/report"

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
            return "发到电脑：超时 20 s 无回音（手机到 192.168.31.99:8716 不通？电脑上的 8716 接收端没开？）"
        }
        if code < 0 { return "发到电脑：失败 \(failure)" }
        return "发到电脑：HTTP \(code) 回执 \(reply)（送出 \(text.count) 字符）"
    }
}

// MARK: - 小工具

enum SwapUtil {
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
}
