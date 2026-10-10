import Foundation
import UIKit

/// 每一步往 Documents/voice_log.txt 追加一行（带水位）。闪退/失败不清盘，"发到电脑"能一次带走。
enum VoiceJournal {
    static var url: URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("voice_log.txt")
    }

    static func load() -> String {
        guard let url = url else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func line(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        let oneLine = text.replacingOccurrences(of: "\n", with: " ／ ")
        let entry = "\(f.string(from: Date())) 足迹\(VoiceFacts.footprintMB())/驻留\(VoiceFacts.residentMB())MB \(oneLine)"
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

enum VoiceFacts {
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
            "endpoint   \(VoiceUploader.endpoint)",
            "模型目录   \(modelsDirNote())"
        ]
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

    static func modelsDirNote() -> String {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return "拿不到 Documents"
        }
        let dir = docs.appendingPathComponent("voice_models")
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return "voice_models/ 不存在"
        }
        var total: Int64 = 0
        for f in files {
            let p = dir.appendingPathComponent(f).path
            if let sz = (try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber {
                total += sz.int64Value
            }
        }
        return "voice_models/ 有 \(files.count) 项 合计 \(total / 1_048_576) MB  [\(files.sorted().prefix(20).joined(separator: ", "))]"
    }
}

enum VoiceUploader {
    /// 8712 归剪辑项目 / 8714 归 VR3D，这个 app 走自己的端口和接收文件，两边不覆盖。
    static let endpoint = "http://192.168.31.99:8715/report"

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
            return "发到电脑：超时 20 s 无回音（手机到 192.168.31.99:8715 不通？电脑上的 8715 接收端没开？）"
        }
        if code < 0 { return "发到电脑：失败 \(failure)" }
        return "发到电脑：HTTP \(code) 回执 \(reply)（送出 \(text.count) 字符）"
    }
}
