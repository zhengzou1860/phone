//
//  AppLog.swift
//  手机自己的运行日志：环形缓冲 + 落盘滚动 + 闪退标记，界面那颗「发日志」按钮
//  把它压成几段 GET 发到 PC 的 /app_log?…。
//
//  为什么用 GET 的查询串而不是新接口：PC 那边这一版没有任何日志接收口，但它的
//  Flask 启动日志会把每条请求行（含查询串）都记下来。手机把日志切段塞进 URL，
//  404 也无所谓——数据已经落在电脑的日志里，PC 侧一行代码都不用改，重启也不丢。
//
//  这里只用 Foundation/Darwin：CI 在 mac 上要把这个文件和别的文件一起 swiftc 跑，
//  UIKit 的东西一律不碰。
//

import Compression
import Darwin
import Foundation

/// 信号处理器要用的文件描述符。放全局是因为 C 函数指针不能捕获上下文。
private var appLogCrashFd: Int32 = -1

/// 信号处理器里不能构造 Swift 字符串（会分配内存），所以每种信号备一条静态字符串。
private func appLogSignalNote(_ sig: Int32) -> StaticString {
    switch sig {
    case SIGABRT: return "\n[crash] SIGABRT\n"
    case SIGSEGV: return "\n[crash] SIGSEGV\n"
    case SIGBUS: return "\n[crash] SIGBUS\n"
    case SIGILL: return "\n[crash] SIGILL\n"
    case SIGFPE: return "\n[crash] SIGFPE\n"
    default: return "\n[crash] signal\n"
    }
}

private func appLogSignalHandler(_ sig: Int32) {
    let note = appLogSignalNote(sig)
    _ = write(appLogCrashFd, note.utf8Start, note.utf8CodeUnitCount)
    signal(sig, SIG_DFL)
    raise(sig)
}

private func appLogExceptionHandler(_ exc: NSException) {
    let line = "\n[crash] NSException \(exc.name.rawValue): \(exc.reason ?? "")\n"
    line.withCString { _ = write(appLogCrashFd, $0, strlen($0)) }
}

final class AppLog {
    static let shared = AppLog()

    /// 环形缓冲留多少行、盘上文件滚到多大。发日志默认只发最近这一截，
    /// 足够覆盖一次「越用越卡、最后一次特征改不了」的现场。
    static let ringLimit = 2000
    static let fileLimit = 512 * 1024
    static let chunkChars = 4000
    static let maxPayloadLines = 1600

    private let lock = NSLock()
    private var ring: [String] = []
    private var fileURL: URL?
    private var fd: Int32 = -1
    private var fileBytes = 0
    private var formatter: DateFormatter
    private var booted = false
    private var crashedLastRun = false
    private var uncleanLastRun = false

    private(set) var version = ""
    private(set) var build = ""
    private let bootWall = Date()

    var uptimeSeconds: Int { Int(Date().timeIntervalSince(bootWall)) }

    private init() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        formatter = f
    }

    // MARK: - 开机

    /// App 启动第一件事：接上上一轮的文件、认出上次是不是闪退、装好崩溃处理器。
    /// 重复调用无副作用。
    func boot(version: String, build: String) {
        lock.lock()
        guard !booted else { lock.unlock(); return }
        booted = true
        self.version = version
        self.build = build

        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LiveLogs", isDirectory: true)
        if let dir = dir {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = dir?.appendingPathComponent("live.log")
        fileURL = url

        var oldSize = 0
        if let url = url,
           let attrs = try? fm.attributesOfItem(atPath: url.path),
           let n = attrs[.size] as? NSNumber {
            oldSize = n.intValue
        }
        if oldSize > Self.fileLimit, let url = url {
            // 只留上一轮：崩溃要看的是最近这一段，不是上周的。
            let old = url.deletingLastPathComponent().appendingPathComponent("live.old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
            oldSize = 0
        }
        if oldSize > 0, let url = url {
            // 上一轮的最后几行进环形缓冲：闪退后重启，用户点「发日志」时
            // 崩溃前那段也在里面，不必要求他在崩溃前先点一次。
            let tail = Self.readTail(url, maxBytes: 24 * 1024)
            let lines = tail.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            ring.append(contentsOf: lines.suffix(Self.ringLimit))
            crashedLastRun = tail.contains("[crash]")
            uncleanLastRun = !tail.contains("[exit] clean")
            fileBytes = oldSize
        }
        if let url = url {
            fm.createFile(atPath: url.path, contents: nil)
            fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            appLogCrashFd = dup(fd)
        }

        appendLocked("[boot] LiveSwap \(version)(\(build))｜\(Self.deviceLine())｜\(Self.memoryLine())")
        if crashedLastRun {
            appendLocked("[boot] 上一轮是崩溃退出的：下面这条线前面就是崩溃前最后的记录")
        } else if uncleanLastRun {
            appendLocked("[boot] 上一轮没走正常收尾（闪退，或者被系统/用户杀掉）")
        }
        lock.unlock()

        NSSetUncaughtExceptionHandler(appLogExceptionHandler)
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig, appLogSignalHandler)
        }
    }

    /// 上一次退出得干不干净。启动后自动发一次日志，省得用户先发现闪退再补发。
    var needsAutoUpload: Bool {
        lock.lock()
        defer { lock.unlock() }
        return crashedLastRun || uncleanLastRun
    }

    func clearCrashFlag() {
        lock.lock()
        crashedLastRun = false
        uncleanLastRun = false
        lock.unlock()
    }

    /// 正常退出（iOS 只在这条路真退出时调）。没走到这里不等于闪退：
    /// 用户上滑关掉、系统回收也会留下「没正常收尾」的标记。
    func markCleanExit() {
        log("exit", "clean")
    }

    // MARK: - 写日志

    func log(_ tag: String, _ message: String) {
        var s = message
        if s.count > 1600 { s = String(s.prefix(1600)) + "…" }
        // 一条日志一行：PC 那边是按行看的，换行会把一段拆成好几行。
        s = s.replacingOccurrences(of: "\r", with: " ")
             .replacingOccurrences(of: "\n", with: " ⏎ ")
        lock.lock()
        appendLocked("[\(tag)] \(s)")
        lock.unlock()
    }

    private func appendLocked(_ body: String) {
        let line = "[\(formatter.string(from: Date()))] \(body)"
        ring.append(line)
        if ring.count > Self.ringLimit {
            ring.removeFirst(ring.count - Self.ringLimit)
        }
        writeLineLocked(line + "\n")
    }

    private func writeLineLocked(_ line: String) {
        guard fd >= 0 else { return }
        let data = Data(line.utf8)
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var off = 0
            while off < buf.count {
                let n = write(fd, base.advanced(by: off), buf.count - off)
                if n <= 0 { break }
                off += n
            }
        }
        fileBytes += data.count
        if fileBytes > Self.fileLimit { rotateLocked() }
    }

    private func rotateLocked() {
        guard let url = fileURL else { return }
        if fd >= 0 { close(fd); fd = -1 }
        let old = url.deletingLastPathComponent().appendingPathComponent("live.old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        if appLogCrashFd >= 0 { close(appLogCrashFd) }
        appLogCrashFd = dup(fd)
        fileBytes = 0
        ring.append("[\(formatter.string(from: Date()))] [log] 日志滚到 live.old.log")
        if ring.count > Self.ringLimit { ring.removeFirst(ring.count - Self.ringLimit) }
    }

    // MARK: - 发日志

    /// 一次发送的标题行 + 最近这一截。标题里带版本、系统、内存、PC 地址：
    /// 这些不用用户另外说，收到日志就能对上现场。
    func snapshot() -> String {
        lock.lock()
        let lines = Array(ring.suffix(Self.maxPayloadLines))
        let head = "==== LiveSwap \(version)(\(build))｜\(Self.deviceLine())｜"
            + "\(Self.memoryLine())｜开机 \(uptimeSeconds)s｜"
            + "PC \(UserDefaults.standard.string(forKey: "pcBase") ?? "-")｜"
            + "\(formatter.string(from: Date())) ===="
        lock.unlock()
        return ([head] + lines).joined(separator: "\n")
    }

    static func sessionID() -> String {
        let secs = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
        let salt = UInt16.random(in: 0...UInt16.max)
        return String(format: "%08x%04x", secs, salt)
    }

    /// 手机屏幕上回显的编号：用户只要说「发过了」，PC 日志里按这个编号拼段。
    struct UploadReport {
        let ok: Bool
        let chunks: Int
        let message: String
    }

    /// 把整段日志压成几段 GET。PC 上没有 /app_log 这个路由（回 404 或跳登录页都行），
    /// 它的启动日志照样会把带查询串的请求行记下来——这就是传输本身。
    static func upload(payload: String, to base: URL, session: String, version: String,
                       completion: @escaping (UploadReport) -> Void) {
        let raw = Data(payload.utf8)
        let packed = compress(raw)
        let body = packed ?? raw
        let zflag = packed == nil ? "0" : "1"
        let encoded = base64URL(body)
        let pieces = chunks(encoded)
        guard !pieces.isEmpty else {
            completion(UploadReport(ok: false, chunks: 0, message: "没有日志可发"))
            return
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = false
        let ses = URLSession(configuration: cfg)
        let total = pieces.count

        func finish(_ report: UploadReport) {
            ses.finishTasksAndInvalidate()
            completion(report)
        }

        func send(_ index: Int) {
            if index >= total {
                finish(UploadReport(ok: true, chunks: total, message: "已发 \(total) 段"))
                return
            }
            let endpoint = base.appendingPathComponent("app_log")
            guard var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
                finish(UploadReport(ok: false, chunks: index, message: "拼不出日志地址"))
                return
            }
            comps.queryItems = [
                URLQueryItem(name: "s", value: session),
                URLQueryItem(name: "i", value: String(index + 1)),
                URLQueryItem(name: "n", value: String(total)),
                URLQueryItem(name: "z", value: zflag),
                URLQueryItem(name: "v", value: version),
                URLQueryItem(name: "d", value: pieces[index]),
            ]
            guard let u = comps.url else {
                finish(UploadReport(ok: false, chunks: index, message: "这一段的 URL 不合法"))
                return
            }
            var req = URLRequest(url: u)
            req.timeoutInterval = 8
            ses.dataTask(with: req) { _, _, err in
                if let err = err {
                    finish(UploadReport(ok: false, chunks: index,
                                        message: "第 \(index + 1)/\(total) 段没送到："
                                            + err.localizedDescription))
                    return
                }
                send(index + 1)
            }.resume()
        }
        send(0)
    }

    // MARK: - 纯函数（CI 自测直接判这几条）

    /// 压缩成 zlib/deflate 流。压不动（返回 0）就落回明文，不因为这步失败发不出去。
    static func compress(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let cap = input.count + 64
        var out = Data(count: cap)
        let produced = out.withUnsafeMutableBytes { dst -> Int in
            guard let d = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { src -> Int in
                guard let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, cap, s, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard produced > 0, produced <= cap else { return nil }
        out.removeSubrange(produced..<out.count)
        return out
    }

    /// 查询串里只能出现不需要百分号转义的字符：base64url 正好只含 A-Za-z0-9-_。
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 4000 字符一段：整条请求行远低于 HTTP 服务器的行上限，单段丢了也只缺一小截。
    static func chunks(_ s: String, size: Int = AppLog.chunkChars) -> [String] {
        guard size > 0, !s.isEmpty else { return [] }
        var out: [String] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: size, limitedBy: s.endIndex) ?? s.endIndex
            out.append(String(s[i..<j]))
            i = j
        }
        return out
    }

    // MARK: - 环境

    static func deviceLine() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var uts = utsname()
        uname(&uts)
        let machine = withUnsafeBytes(of: &uts.machine) { buf -> String in
            guard let p = buf.bindMemory(to: CChar.self).baseAddress else { return "?" }
            return String(cString: p)
        }
        return "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) \(machine)"
    }

    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    static func memoryLine() -> String {
        var freeMB = 0
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let n = attrs[.systemFreeSize] as? NSNumber {
            freeMB = n.intValue / (1024 * 1024)
        }
        return "内存 \(footprintMB())MB｜剩余磁盘 \(freeMB)MB"
    }

    private static func readTail(_ url: URL, maxBytes: Int) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
