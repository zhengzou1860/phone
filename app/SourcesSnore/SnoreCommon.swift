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
    ///
    /// 地址在「设置 → 发到电脑」里可改。写死过一次就吃了亏：电脑的 .99 变成了残留的副地址
    /// （Windows 标了 SkipAsSource，出站不走它），真正在用的是 .100，于是整晚记录发不出来，
    /// 而为改一个 IP 重新出包、重装一轮实在太贵。
    static let defaultEndpoint = "http://192.168.31.100:8717/report"
    private static let endpointKey = "snore.pcEndpoint"

    /// 存下来的原文（可能是空串）。输入框绑这一份，清空了才不会被默认值立刻顶回去。
    static var savedEndpoint: String {
        UserDefaults.standard.string(forKey: endpointKey) ?? ""
    }

    static var endpoint: String {
        let saved = savedEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.isEmpty ? defaultEndpoint : saved
    }

    static func saveEndpoint(_ text: String) {
        UserDefaults.standard.set(text.trimmingCharacters(in: .whitespacesAndNewlines), forKey: endpointKey)
    }

    static func send(_ text: String) -> String {
        let target = endpoint
        guard let url = URL(string: target) else { return badAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = text.data(using: .utf8)
        let r = roundTrip(request, wait: 20)
        if r.timedOut { return unreachable(target, seconds: 20) }
        if r.code < 0 { return "发到电脑：失败 \(r.failure)" }
        return "发到电脑：HTTP \(r.code) 回执 \(r.reply)（送出 \(text.count) 字符）"
    }

    /// 先探通不通：GET /ping 只有几个字节，别拿 1 MB 的整晚记录去试一个可能错的地址。
    static func ping() -> String {
        let target = endpoint
        guard var parts = URLComponents(string: target) else { return badAddress }
        parts.path = "/ping"
        parts.query = nil
        guard let url = parts.url else { return badAddress }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let r = roundTrip(request, wait: 8)
        if r.timedOut { return unreachable(target, seconds: 8) }
        if r.code < 0 { return "探不通：\(r.failure)" }
        return "通了：HTTP \(r.code) 回执「\(r.reply)」← \(url.absoluteString)"
    }

    private static var badAddress: String {
        "发送失败：地址非法（设置里那一行要形如 \(defaultEndpoint)）"
    }

    private static func unreachable(_ target: String, seconds: Int) -> String {
        "超时 \(seconds) s 没回音（\(target) 不通？核对三件事：手机和电脑同一个 Wi-Fi；"
            + "电脑上 tools/report_server_snore.py 起着；设置里的地址跟电脑 ipconfig 的 IPv4 一致，末尾 /report 别丢）"
    }

    private static func roundTrip(_ request: URLRequest, wait: Double)
        -> (code: Int, reply: String, failure: String, timedOut: Bool) {
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
        let timedOut = done.wait(timeout: .now() + wait) == .timedOut
        return (code, reply, failure, timedOut)
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
