import AVFoundation
import Foundation
import UIKit
import Darwin

// MARK: - 现场读数
//
// 每个 app 都带这一份：手机上判「为什么没录到」的时候，这几行比什么都能说明问题
// （权限、音量是不是全零、还剩多少盘、足迹多大、走的哪个端口）。

enum SnoreFacts {
    static func lines() -> [String] {
        let info = Bundle.main.infoDictionary ?? [:]
        let pi = ProcessInfo.processInfo
        var l = [
            "bundleId   \(Bundle.main.bundleIdentifier ?? "-")",
            "version    \(info["CFBundleShortVersionString"] ?? "-") (\(info["CFBundleVersion"] ?? "-"))",
            "iOS        \(pi.operatingSystemVersionString)",
            "machine    \(machine())  cores=\(pi.processorCount)",
            "memory     足迹 \(footprintMB()) / 驻留 \(residentMB()) MB / 物理 \(pi.physicalMemory / 1048576) MB",
            "disk       可用 \(String(format: "%.1f", SnoreArchive.diskFreeMB() / 1024.0)) GB",
            "endpoint   \(SnoreUploader.endpoint)",
            "麦克风     \(perm())",
            "音频会话   \(sessionText())",
            "电量       \(SnoreEnv.cachedBattery)｜低电量模式 "
                + "\(ProcessInfo.processInfo.isLowPowerModeEnabled ? "开（后台录音会被掐，充电时建议关掉）" : "关")",
            "屏幕       \(SnoreEnv.cachedIdleTimer ? "防休眠开着（更耗电，但屏一直亮）" : "系统默认（熄屏不影响录音）")"
        ]
        l.append("后台模式   \(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") != nil ? "Info 里写了" : "Info 里没写：熄屏就停")")
        return l
    }

    static func machine() -> String {
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

    static func perm() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "已允许"
        case .denied: return "已拒绝（设置里放开才能录）"
        case .restricted: return "受限（家长控制一类）"
        default: return "未决（第一次点开始会弹窗）"
        }
    }

    /// AVAudioSession 不是 UI API，后台线程读它没问题（报告就是在 core 队列上拼的）。
    private static func sessionText() -> String {
        let s = AVAudioSession.sharedInstance()
        return "类别 \(s.category.rawValue)／模式 \(s.mode.rawValue)／\(Int(s.sampleRate)) Hz"
            + "／进 \(Int(s.inputNumberOfChannels)) 出 \(Int(s.outputNumberOfChannels))"
    }
}

// MARK: - UI API 的读数先缓存再给人读
//
// UIDevice 的电量、UIApplication.isIdleTimerDisabled 都是主线程的东西，而报告是在 core 队列上拼的。
// 所以由主线程那边隔一会儿喂一次缓存，拼报告的人只读缓存——不跨线程碰 UI API，也不为此加锁加出死锁。
enum SnoreEnv {
    private static let lock = NSLock()
    private static var battery = "没读到"
    private static var idle = false

    static func update(batteryText: String, idleTimerDisabled: Bool) {
        lock.lock()
        battery = batteryText
        idle = idleTimerDisabled
        lock.unlock()
    }

    static var cachedBattery: String {
        lock.lock()
        defer { lock.unlock() }
        return battery
    }

    static var cachedIdleTimer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return idle
    }
}

// MARK: - 磁盘流水
//
// 整晚挂着，崩一次就没了。所以每一步都往 Documents/snore_log.txt 追加一行（带水位），
// 「发到电脑」连它一起发；心跳那行每 60 s 一次，能看出是几点几分断的气。

enum SnoreJournal {
    static var url: URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("snore_log.txt")
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
        let entry = "\(f.string(from: Date())) 足迹\(SnoreFacts.footprintMB())/驻留\(SnoreFacts.residentMB())MB \(oneLine)"
        guard let url = url else { return }
        var lines = load().split(separator: "\n").map(String.init)
        lines.append(entry)
        if lines.count > 900 { lines.removeFirst(lines.count - 900) }
        guard let data = lines.joined(separator: "\n").appending("\n").data(using: .utf8) else { return }
        try? data.write(to: url)
    }

    static func tail(_ n: Int) -> String {
        let lines = load().split(separator: "\n").map(String.init)
        if lines.isEmpty { return "磁盘日志是空的（\(url?.path ?? "拿不到 documents 目录")）" }
        return lines.suffix(n).joined(separator: "\n")
    }
}

// MARK: - 发到电脑

enum SnoreUploader {
    /// 8712 剪辑 / 8714 VR3D / 8715 Voice / 8716 换脸，这条线走 8717 和自己的接收文件。
    static let endpoint = "http://192.168.31.99:8717/report"

    static func send(_ text: String) -> String {
        guard let url = URL(string: endpoint) else { return "发送失败：地址非法" }
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
            return "发到电脑：超时 20 s 没回音（手机到 192.168.31.99:8717 不通？电脑上的 8717 接收端没开？）"
        }
        if code < 0 { return "发到电脑：失败 \(failure)" }
        return "发到电脑：HTTP \(code) 回执 \(reply)（送出 \(text.count) 字符）"
    }
}

// MARK: - 内存压力哨兵
//
// 整晚驻着，系统真要杀会先喊内存压力。喊过 → 是内存的事；一声没喊就死 → 得换方向查。
enum SnorePressureWatch {
    private static var sources: [DispatchSourceMemoryPressure] = []
    static var sawPressure = false

    static func start() {
        guard sources.isEmpty else { return }
        let q = DispatchQueue(label: "com.qoder.snorebench.pressure")
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: q)
        s.setEventHandler {
            sawPressure = true
            let level = s.data
            SnoreJournal.line("内存压力喊了一声 eventMask=\(level.rawValue)｜足迹 \(SnoreFacts.footprintMB()) MB")
        }
        s.resume()
        sources.append(s)
    }

    static func reset() { sawPressure = false }
}
