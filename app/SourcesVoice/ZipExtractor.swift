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
        let inChunk  = 1 << 20      // 1 MB 输入缓冲
        let outChunk = 4 << 20      // 4 MB 输出缓冲
        let srcBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: inChunk)
        let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: outChunk)
        defer { srcBuf.deallocate(); dstBuf.deallocate() }

        // Swift 不给导入的 C struct 生成无参 init，五个字段必须逐个给
        var stream = compression_stream(dst_ptr: dstBuf, dst_size: 0,
                                        src_ptr: UnsafePointer(srcBuf), src_size: 0,
                                        state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else {
            throw ZipError.inflateFailed("stream_init 失败 (\(name))")
        }
        defer { compression_stream_destroy(&stream) }

        var remainingIn = compressedSize   // zip 里还没读出来的压缩字节
        var buffered = 0                   // srcBuf 头部待处理的字节
        var producedTotal = 0
        var iterations = 0

        while true {
            iterations += 1
            if iterations > 4096 {
                throw ZipError.inflateFailed("\(name) 迭代超上限 produced=\(producedTotal)")
            }

            if remainingIn > 0 && buffered < inChunk {
                let want = min(remainingIn, inChunk - buffered)
                let data = try fh.read(upToCount: want) ?? Data()
                if data.isEmpty { throw ZipError.ioFailed("inflate 提前 EOF (\(name))") }
                _ = data.withUnsafeBytes { raw in
                    memcpy(srcBuf + buffered, raw.baseAddress!, data.count)
                }
                buffered += data.count
                remainingIn -= data.count
            }

            // 输入喂完 = 这一条 deflate 流的最后一块，必须带 FINALIZE，否则解不结束
            let isLastInput = (remainingIn <= 0)
            stream.src_ptr = UnsafePointer(srcBuf)
            stream.src_size = buffered
            stream.dst_ptr = dstBuf
            stream.dst_size = outChunk

            // CI 探测实证（iPhoneOS26.5.sdk）：process 的 flags 形参是 Int32，
            // 而 COMPRESSION_STREAM_FINALIZE 被导入成 __C.compression_stream_flags(rawValue: 1)。
            // truncatingIfNeeded 不依赖 rawValue 是 Int32 还是 UInt32。
            let finalize = Int32(truncatingIfNeeded: COMPRESSION_STREAM_FINALIZE.rawValue)
            let status = compression_stream_process(&stream, isLastInput ? finalize : 0)

            // process 会把 src_ptr 往前推、src_size 留成"还没吃掉的"，挪回头部再喂下一批
            let unconsumed = stream.src_size
            if unconsumed > 0 {
                memmove(srcBuf, srcBuf + (buffered - unconsumed), unconsumed)
            }
            buffered = unconsumed

            let produced = outChunk - stream.dst_size
            if produced > 0 {
                try outFH.write(contentsOf: UnsafeRawBufferPointer(start: dstBuf, count: produced))
                producedTotal += produced
            }

            switch status {
            case COMPRESSION_STATUS_END:
                if producedTotal != uncompressedSize {
                    throw ZipError.inflateFailed("\(name) 解出 \(producedTotal)，中央目录声明 \(uncompressedSize)")
                }
                return
            case COMPRESSION_STATUS_ERROR:
                throw ZipError.inflateFailed("decode 报错 (\(name)) produced=\(producedTotal)")
            default:
                // 没有 END 也没有 ERROR，但三方都没动 → 再转下去也不会变，判死
                if produced == 0 && buffered == 0 && remainingIn <= 0 {
                    throw ZipError.inflateFailed("流提前断 (\(name)) produced=\(producedTotal)/\(uncompressedSize)")
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
