import Foundation

enum RestoreJournal {
    private static let lock = NSLock()
    private static let maximumLines = 1000
    private static let maximumBytes = 512 * 1024

    static var url: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return documents.appendingPathComponent("HiRestore", isDirectory: true)
            .appendingPathComponent("runtime.log")
    }

    static func line(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let oneLine = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ／ ")
            .prefix(2000)
        let entry = "\(formatter.string(from: Date())) \(oneLine)"
        var lines = readLinesLocked()
        lines.append(String(entry))
        lines = compact(lines)
        guard let data = lines.joined(separator: "\n").appending("\n").data(using: .utf8) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func exportSnapshot(details: String) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYearMonthDay, .withDashSeparator, .withColonSeparator, .withTime]
        let name = "HiRestore-runtime-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")).log"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try snapshot(details: details).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func snapshot(details: String) -> String {
        lock.lock()
        let lines = readLinesLocked()
        lock.unlock()
        let formatter = ISO8601DateFormatter()
        return """
        ====== HiRestore 运行日志 ======
        导出时间：\(formatter.string(from: Date()))
        日志仅包含 App、设备和操作信息，不包含照片或视频内容。

        ------ App 与设备 ------
        \(details)

        ------ 运行流水（最多 \(maximumLines) 行 / \(maximumBytes / 1024) KB）------
        \(lines.isEmpty ? "暂无运行记录" : lines.joined(separator: "\n"))
        """
    }

    static func compact(_ lines: [String]) -> [String] {
        var result = Array(lines.suffix(maximumLines))
        while result.joined(separator: "\n").utf8.count > maximumBytes, result.count > 1 {
            result.removeFirst()
        }
        if let first = result.first, first.utf8.count > maximumBytes {
            result[0] = String(first.prefix(maximumBytes))
        }
        return result
    }

    private static func readLinesLocked() -> [String] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}
