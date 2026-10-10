import Foundation
import Compression

/// 纯 Swift ZIP 读取器：中央目录解析 + 流式 inflate
/// 支持 method 0（store）与 method 8（deflate，raw 无 zlib 头）
enum ZipError: Error, LocalizedError {
    case eocdNotFound
    case badMagic(name: String)
    case unsupportedMethod(UInt16, String)
    case inflateFailed(String)
    case ioFailed(String)

    var errorDescription: String? {
        switch self {
        case .eocdNotFound: return "EOCD 未找到，可能不是 zip 或下载不完整"
        case .badMagic(let n): return "ZIP 头 magic 不对（\(n)）"
        case .unsupportedMethod(let m, let f): return "文件 \(f) 用了不支持的压缩 method=\(m)"
        case .inflateFailed(let r): return "inflate 失败: \(r)"
        case .ioFailed(let r): return "读写失败: \(r)"
        }
    }
}

struct ZipEntry {
    let filename: String
    let compressionMethod: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

enum ZipExtractor {

    /// 读取中央目录所有条目
    static func readEntries(zipURL: URL) throws -> [ZipEntry] {
        let fh = try FileHandle(forReadingFrom: zipURL)
        defer { try? fh.close() }
        let fileSize = try fh.seekToEnd()
        guard fileSize >= 22 else { throw ZipError.eocdNotFound }

        // 尾部窗口找 EOCD "PK\x05\x06"，ZIP comment 最多 65535 字节
        let window = min(UInt64(22 + 65535), fileSize)
        let startOffset = fileSize - window
        try fh.seek(toOffset: startOffset)
        let tail = try fh.read(upToCount: Int(window)) ?? Data()

        var eocdPos = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50 && tail[i+1] == 0x4b && tail[i+2] == 0x05 && tail[i+3] == 0x06 {
                eocdPos = i
                break
            }
            i -= 1
        }
        guard eocdPos >= 0 else { throw ZipError.eocdNotFound }

        let totalEntries = Int(readU16(tail, eocdPos + 10))
        let cdSize = Int(readU32(tail, eocdPos + 12))
        let cdOffset = Int(readU32(tail, eocdPos + 16))

        try fh.seek(toOffset: UInt64(cdOffset))
        let cd = try fh.read(upToCount: cdSize) ?? Data()
        guard cd.count == cdSize else { throw ZipError.ioFailed("中央目录读取不完整") }

        var entries: [ZipEntry] = []
        var p = 0
        for _ in 0..<totalEntries {
            guard p + 46 <= cd.count else { throw ZipError.badMagic(name: "中央目录越界") }
            guard cd[p] == 0x50 && cd[p+1] == 0x4b && cd[p+2] == 0x01 && cd[p+3] == 0x02
            else { throw ZipError.badMagic(name: "中央目录头") }
            let method = readU16(cd, p + 10)
            let csize = Int(readU32(cd, p + 20))
            let usize = Int(readU32(cd, p + 24))
            let fnlen = Int(readU16(cd, p + 28))
            let extralen = Int(readU16(cd, p + 30))
            let commentlen = Int(readU16(cd, p + 32))
            let lho = Int(readU32(cd, p + 42))
            guard p + 46 + fnlen <= cd.count else { throw ZipError.ioFailed("文件名字段越界") }
            let fnBytes = cd.subdata(in: (p+46)..<(p+46+fnlen))
            let filename = String(bytes: fnBytes, encoding: .utf8) ?? ""
            entries.append(ZipEntry(filename: filename,
                                    compressionMethod: method,
                                    compressedSize: csize,
                                    uncompressedSize: usize,
                                    localHeaderOffset: lho))
            p += 46 + fnlen + extralen + commentlen
        }
        return entries
    }

    /// 提取所有文件到目标目录
    static func extractAll(zipURL: URL, to dir: URL) throws {
        let entries = try readEntries(zipURL: zipURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fh = try FileHandle(forReadingFrom: zipURL)
        defer { try? fh.close() }
        for e in entries where !e.filename.hasSuffix("/") && !e.filename.isEmpty {
            let dest = dir.appendingPathComponent(e.filename)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try extractEntry(fh, e, to: dest)
            let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
            let got = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            if got != Int64(e.uncompressedSize) {
                throw ZipError.ioFailed("\(e.filename) 解压出来 \(got) 字节，中央目录声明 \(e.uncompressedSize)")
            }
        }
    }

    private static func extractEntry(_ fh: FileHandle,
                                     _ entry: ZipEntry,
                                     to dest: URL) throws {
        // 读本地头（因为 extra field 长度可能和中央目录不同）
        try fh.seek(toOffset: UInt64(entry.localHeaderOffset))
        let lfh = try fh.read(upToCount: 30) ?? Data()
        guard lfh.count >= 30,
              lfh[0] == 0x50, lfh[1] == 0x4b, lfh[2] == 0x03, lfh[3] == 0x04
        else { throw ZipError.badMagic(name: entry.filename) }
        let fnlen = Int(readU16(lfh, 26))
        let extralen = Int(readU16(lfh, 28))
        let dataStart = entry.localHeaderOffset + 30 + fnlen + extralen
        try fh.seek(toOffset: UInt64(dataStart))

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let outFH = try FileHandle(forWritingTo: dest)
        defer { try? outFH.close() }

        switch entry.compressionMethod {
        case 0:
            try copyRaw(fh: fh, outFH: outFH, totalBytes: entry.compressedSize)
        case 8:
            try inflate(fh: fh, outFH: outFH,
                        compressedSize: entry.compressedSize,
                        uncompressedSize: entry.uncompressedSize,
                        name: entry.filename)
        default:
            throw ZipError.unsupportedMethod(entry.compressionMethod, entry.filename)
        }
    }

    private static func copyRaw(fh: FileHandle, outFH: FileHandle, totalBytes: Int) throws {
        let chunk = 1 << 20   // 1 MB
        var remaining = totalBytes
        while remaining > 0 {
            let n = min(chunk, remaining)
            let data = try fh.read(upToCount: n) ?? Data()
            if data.isEmpty { throw ZipError.ioFailed("提前 EOF") }
            try outFH.write(contentsOf: data)
            remaining -= data.count
        }
    }

    private static func inflate(fh: FileHandle,
                                outFH: FileHandle,
                                compressedSize: Int,
                                uncompressedSize: Int,
                                name: String) throws {
        let inChunk = 1 << 20       // 1 MB 输入
        let outChunk = 4 << 20      // 4 MB 输出
        var srcArr = [UInt8](repeating: 0, count: inChunk)
        var dstArr = [UInt8](repeating: 0, count: outChunk)

        var stream = compression_stream()
        guard compression_stream_init(&stream, COMPRESSION_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else {
            throw ZipError.inflateFailed("stream_init 失败 (\(name))")
        }
        defer { compression_stream_destroy(&stream) }

        var remainingIn = compressedSize
        var done = false
        while !done {
            let toRead = min(inChunk, remainingIn)
            var filled = 0
            if toRead > 0 {
                let data = try fh.read(upToCount: toRead) ?? Data()
                if data.isEmpty {
                    throw ZipError.ioFailed("inflate 提前 EOF (\(name))")
                }
                data.withUnsafeBytes { raw in
                    memcpy(&srcArr, raw.baseAddress, data.count)
                }
                filled = data.count
                remainingIn -= data.count
            }
            let flags: compression_stream_flag = (remainingIn <= 0) ? COMPRESSION_STREAM_FINALIZE : 0

            var statusOut: compression_status = COMPRESSION_STATUS_OK
            var producedData: Data = Data()
            srcArr.withUnsafeMutableBufferPointer { srcPtr in
                dstArr.withUnsafeMutableBufferPointer { dstPtr in
                    stream.src_ptr = srcPtr.baseAddress!
                    stream.src_size = filled
                    stream.dst_ptr = dstPtr.baseAddress!
                    stream.dst_size = outChunk
                    statusOut = compression_decode_stream(&stream, flags)
                    let produced = outChunk - stream.dst_size
                    if produced > 0 {
                        producedData = Data(bytes: dstPtr.baseAddress!, count: produced)
                    }
                }
            }
            if !producedData.isEmpty {
                try outFH.write(contentsOf: producedData)
            }
            switch statusOut {
            case COMPRESSION_STATUS_END:
                done = true
            case COMPRESSION_STATUS_ERROR:
                throw ZipError.inflateFailed("decode 报错 (\(name))")
            default:
                if remainingIn <= 0 && producedData.isEmpty && filled == 0 {
                    done = true
                }
            }
        }
    }

    // MARK: - little-endian readers

    private static func readU16(_ d: Data, _ off: Int) -> UInt16 {
        let b0 = UInt16(d[d.startIndex + off])
        let b1 = UInt16(d[d.startIndex + off + 1])
        return b0 | (b1 << 8)
    }

    private static func readU32(_ d: Data, _ off: Int) -> UInt32 {
        let b0 = UInt32(d[d.startIndex + off])
        let b1 = UInt32(d[d.startIndex + off + 1])
        let b2 = UInt32(d[d.startIndex + off + 2])
        let b3 = UInt32(d[d.startIndex + off + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
