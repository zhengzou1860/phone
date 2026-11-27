import Foundation

enum RestoreModelArchive {
    static func extractStoredZip(at archive: URL, to destination: URL) throws {
        let reader = try FileHandle(forReadingFrom: archive)
        defer { try? reader.close() }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var names = Set<String>()
        var fileCount = 0
        var totalBytes: Int64 = 0

        for _ in 0..<10_000 {
            try Task.checkCancellation()
            let signature = try read(reader, count: 4)
            if signature == Data([0x50, 0x4b, 0x01, 0x02]) {
                guard fileCount > 0 else { throw invalidArchive("没有模型文件") }
                return
            }
            guard signature == Data([0x50, 0x4b, 0x03, 0x04]) else {
                throw invalidArchive("文件头无效")
            }
            let header = try read(reader, count: 26)
            let flags = integer(header, offset: 6, width: 2)
            let method = integer(header, offset: 8, width: 2)
            let compressedSize = integer(header, offset: 18, width: 4)
            let size = integer(header, offset: 22, width: 4)
            let nameLength = integer(header, offset: 26, width: 2)
            let extraLength = integer(header, offset: 28, width: 2)
            guard flags & 0x0009 == 0, method == 0, compressedSize == size,
                  nameLength > 0, nameLength <= 4096, extraLength <= 65_535,
                  size <= 2 * 1024 * 1024 * 1024 else {
                throw invalidArchive("仅支持未加密的存储格式")
            }
            let nameData = try read(reader, count: nameLength)
            guard let name = String(data: nameData, encoding: .utf8), !name.contains("\0"), !name.contains("\\") else {
                throw invalidArchive("文件名无效")
            }
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            let directory = name.hasSuffix("/")
            let pathComponents = directory ? components.dropLast() : Array(components)
            guard !pathComponents.isEmpty,
                  pathComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }),
                  names.insert(pathComponents.joined(separator: "/")).inserted else {
                throw invalidArchive("路径不安全或重复")
            }
            if extraLength > 0 {
                try reader.seekToCurrentOffset(relativeOffset: UInt64(extraLength))
            }
            let output = destination.appendingPathComponent(name)
            if directory {
                guard size == 0 else { throw invalidArchive("目录大小无效") }
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                continue
            }
            totalBytes += Int64(size)
            guard totalBytes <= 2 * 1024 * 1024 * 1024 else { throw invalidArchive("解包大小超限") }
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
                throw invalidArchive("无法创建模型文件")
            }
            let writer = try FileHandle(forWritingTo: output)
            do {
                try copy(reader, count: size, to: writer)
            } catch {
                try? writer.close()
                throw error
            }
            try writer.close()
            fileCount += 1
        }
        throw invalidArchive("文件数量超限")
    }

    private static func copy(_ reader: FileHandle, count: Int, to writer: FileHandle) throws {
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try read(reader, count: min(1024 * 1024, remaining))
            try writer.write(contentsOf: chunk)
            remaining -= chunk.count
        }
    }

    private static func read(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw invalidArchive("文件被截断")
            }
            data.append(chunk)
        }
        return data
    }

    private static func integer(_ data: Data, offset: Int, width: Int) -> Int {
        var value = 0
        for index in 0..<width {
            value |= Int(data[data.startIndex + offset + index]) << (index * 8)
        }
        return value
    }

    private static func invalidArchive(_ message: String) -> RestoreError {
        .fileOperation("模型压缩包无效：\(message)")
    }
}
