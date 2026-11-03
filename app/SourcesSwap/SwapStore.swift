import Foundation
import CryptoKit

/// 模型仓库：四张网不再跟着 ipa 走，改成单独下到手机上一次。
///
/// 为什么：ipa 里带 345 MB 权重，换程序就得把那 345 MB 重装一遍（这一条线每轮都在改程序）。
/// 模型单独放一份在 Documents/swap_models 里，程序随便改；模型版本没变就不重新下。
/// 版本号＝四张 onnx 的 sha256（CI 那头算），所以「换模型」和「改程序」这两件事在盘上是分开的：
/// 程序改完装上去，那一份模型原封不动；只有模型本身换了，手机上那份才会被换掉。
///
/// 发布位：CI 把四张 mlpackage 打成两个文件，挂在 channel-swap 这条 release 上：
///   models.json  清单：版本号＋整包 sha256＋每个文件的大小
///   models.bin   归档：文件头 "SWPM"＋uint32 头长（4 字节小端）＋JSON 头＋各文件字节依次排下去
///   （不用 zip：iOS 没有现成的解 zip，逐段 inflate 得自己写一套；存成不压缩的归档省掉那一整套，
///     少一个能出错的环节比省几十 MB 划算）
enum SwapStore {
    static let base = "https://github.com/zhengzou1860/phone/releases/download/channel-swap"
    static let manifestName = "models.json"
    static let archiveName = "models.bin"
    static let dirName = "swap_models"

    struct Manifest: Decodable {
        struct File: Decodable { let path: String; let size: Int }
        let version: String
        let sha256: String
        let bytes: Int
        let files: [File]
    }

    // MARK: - 盘上那一份

    static var dir: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(dirName, isDirectory: true)
    }

    /// 四张网（顺序＝身份证／权重生成／逐帧／人脸分割）
    static var resources: [String] {
        [SwapNets.arcResource, SwapNets.buildResource, SwapNets.unetResource, SwapNets.parseResource]
    }

    static func localVersion() -> String {
        guard let d = dir,
              let v = try? String(contentsOf: d.appendingPathComponent("version.txt"), encoding: .utf8)
        else { return "" }
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 盘上那一份里某个资源的 mlpackage 目录（没有就 nil）
    static func local(_ resource: String) -> URL? {
        guard let d = dir else { return nil }
        let p = d.appendingPathComponent("\(resource).mlpackage", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return p
    }

    /// 四张都在、Manifest.json 也都在，才算齐（半个 mlpackage 进 compileModel 会炸）
    static func haveAll() -> Bool {
        for r in resources {
            guard let p = local(r) else { return false }
            guard FileManager.default.fileExists(atPath: p.appendingPathComponent("Manifest.json").path) else { return false }
        }
        return true
    }

    static func statusLine() -> String {
        if haveAll() { return "已下好 版本 \(localVersion())｜四张齐" }
        let v = localVersion()
        return v.isEmpty ? "没下（点「下模型」，或直接开始换脸会自动下）"
                         : "没下齐（盘上版本 \(v) 不全）"
    }

    // MARK: - 清单

    /// 清单就几 KB：版本对得上就不用再动那 345 MB
    static func fetchManifest(timeout: TimeInterval = 30) -> (m: Manifest?, note: String) {
        guard let url = URL(string: "\(base)/\(manifestName)") else { return (nil, "地址非法") }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let sem = DispatchSemaphore(value: 0)
        var data: Data?, code = -1, err = ""
        URLSession.shared.dataTask(with: req) { d, r, e in
            if let e { err = e.localizedDescription }
            if let r = r as? HTTPURLResponse { code = r.statusCode }
            data = d
            sem.signal()
        }.resume()
        if sem.wait(timeout: .now() + timeout + 5) == .timedOut { return (nil, "清单超时 \(Int(timeout)) s") }
        guard code == 200, let d = data else { return (nil, "清单 HTTP \(code) \(err)") }
        do {
            let m = try JSONDecoder().decode(Manifest.self, from: d)
            return (m, "清单 \(d.count) 字节｜版本 \(m.version)")
        } catch {
            return (nil, "清单解不开：\(error)")
        }
    }

    // MARK: - 下载

    /// 下载任务 + 进度。didFinishDownloadingTo 给的那个临时文件在这个方法返回后就没了，
    /// 所以当场挪到自己的路径上（挪晚了文件已经不在）。
    final class Grabber: NSObject, URLSessionDownloadDelegate {
        var onProgress: ((Int64, Int64) -> Void)?
        private let sem = DispatchSemaphore(value: 0)
        private var dst: URL?
        private var note = ""
        private var code = -1

        func grab(_ url: URL, to dst: URL, timeout: TimeInterval) -> (ok: Bool, note: String) {
            self.dst = dst
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 60
            cfg.timeoutIntervalForResource = timeout
            let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            task.resume()
            if sem.wait(timeout: .now() + timeout + 15) == .timedOut {
                task.cancel()
                session.invalidateAndCancel()
                return (false, "下模型超时 \(Int(timeout)) s")
            }
            session.finishTasksAndInvalidate()
            if !note.isEmpty { return (false, note) }
            guard code == 200 else { return (false, "模型归档 HTTP \(code)") }
            return (true, "")
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else { note = "模型归档 HTTP \(code)（发布位上还没有这一份？）"; return }
            do {
                if let d = dst { try? FileManager.default.removeItem(at: d) }
                try FileManager.default.moveItem(at: location, to: dst ?? location)
            } catch {
                note = "下下来的文件挪不走：\(error.localizedDescription)"
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { note = "下载失败：\(error.localizedDescription)" }
            sem.signal()
        }
    }

    static func sha256(_ url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var h = SHA256()
        while true {
            guard let chunk = try? fh.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            h.update(data: chunk)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 归档 → 盘上。头是 "SWPM"＋4 字节头长＋JSON 头，之后各文件字节按清单顺序排下去。
    static func extract(_ archive: URL, manifest m: Manifest, to dir: URL) -> (ok: Bool, note: String) {
        let fm = FileManager.default
        guard let fh = try? FileHandle(forReadingFrom: archive) else { return (false, "归档打不开") }
        defer { try? fh.close() }
        guard let magic = try? fh.read(upToCount: 4) else { return (false, "归档头不是 SWPM") }
        let mb = [UInt8](magic)
        guard mb.count == 4, mb[0] == 0x53, mb[1] == 0x57, mb[2] == 0x50, mb[3] == 0x4D
        else { return (false, "归档头不是 SWPM") }
        guard let lenData = try? fh.read(upToCount: 4) else {
            return (false, "归档头长度读不出来")
        }
        let lb = [UInt8](lenData)
        guard lb.count == 4 else { return (false, "归档头长度读不出来") }
        let hlen = Int(lb[0]) | (Int(lb[1]) << 8) | (Int(lb[2]) << 16) | (Int(lb[3]) << 24)
        guard hlen > 0, hlen < 4_000_000, let head = try? fh.read(upToCount: hlen) else {
            return (false, "归档头读不出来")
        }
        guard let man = try? JSONDecoder().decode(Manifest.self, from: head) else {
            return (false, "归档里的清单解不开")
        }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            return (false, "建不出模型目录：\(error.localizedDescription)")
        }
        for r in resources {
            let p = dir.appendingPathComponent("\(r).mlpackage", isDirectory: true)
            try? fm.removeItem(at: p)
        }
        for f in man.files {
            let p = dir.appendingPathComponent(f.path)
            do {
                try fm.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: p.path) { try fm.removeItem(at: p) }
                _ = fm.createFile(atPath: p.path, contents: nil)
                let out = try FileHandle(forWritingTo: p)
                var left = f.size
                while left > 0 {
                    let want = min(left, 1 << 20)
                    guard let chunk = try fh.read(upToCount: want), !chunk.isEmpty else {
                        try? out.close()
                        return (false, "归档提前完了：\(f.path)")
                    }
                    try out.write(contentsOf: chunk)
                    left -= chunk.count
                }
                try out.close()
            } catch {
                return (false, "写 \(f.path) 失败：\(error.localizedDescription)")
            }
        }
        guard haveAll() else { return (false, "解完了但四张没齐（清单 \(man.files.count) 个文件）") }
        return (true, "解出 \(man.files.count) 个文件")
    }

    /// 盘上没有就下。force＝true 时先问一次版本：版本对得上也不重下。
    /// 返回的第一句是给人看的（进流水、也顶到界面上），第二句是给日志的细节。
    static func ensure(force: Bool = false, onLine: @escaping (String) -> Void) -> (ok: Bool, note: String) {
        let fm = FileManager.default
        if haveAll() && !force {
            return (true, "模型 盘上那一份就是齐的（版本 \(localVersion())），不联网、不重下")
        }
        guard let dir = dir else { return (false, "模型 拿不到 Documents 目录") }
        let (man, mnote) = fetchManifest()
        guard let m = man else { return (false, "模型 拿不到清单：\(mnote)") }
        onLine("模型 清单到手：\(mnote)｜\(String(format: "%.0f", Double(m.bytes) / 1_048_576)) MB")
        if haveAll() && localVersion() == m.version {
            return (true, "模型 盘上那一份就是最新的（版本 \(m.version)），不用重下")
        }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            return (false, "模型 建不出目录：\(error.localizedDescription)")
        }
        guard let url = URL(string: "\(base)/\(archiveName)") else { return (false, "模型 归档地址非法") }
        let tmp = dir.appendingPathComponent("archive.part")
        try? fm.removeItem(at: tmp)
        let grab = Grabber()
        var lastMB = -1
        grab.onProgress = { got, total in
            let mb = Int(got / 1_048_576)
            if mb - lastMB >= 32 || (total > 0 && got >= total) {
                lastMB = mb
                let tot = total > 0 ? String(format: "%.0f", Double(total) / 1_048_576) : "?"
                onLine("模型 下到 \(mb)/\(tot) MB")
            }
        }
        let g = grab.grab(url, to: tmp, timeout: 3600)
        guard g.ok else { try? fm.removeItem(at: tmp); return (false, "模型 \(g.note)") }
        guard let sha = sha256(tmp) else {
            try? fm.removeItem(at: tmp)
            return (false, "模型 sha256 算不出来")
        }
        guard sha == m.sha256 else {
            try? fm.removeItem(at: tmp)
            return (false, "模型 整包 sha256 对不上（要 \(m.sha256.prefix(12))… 拿到 \(sha.prefix(12))…）")
        }
        onLine("模型 整包 sha256 对上了（\(sha.prefix(12))…）｜开始解包")
        let ex = extract(tmp, manifest: m, to: dir)
        try? fm.removeItem(at: tmp)
        guard ex.ok else { return (false, "模型 \(ex.note)") }
        try? m.version.write(to: dir.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true          // 几百 MB 权重不进 iCloud 备份
        var modelDir = dir                       // setResourceValues 是 mutating 的，URL 得是可改的
        try? modelDir.setResourceValues(rv)
        onLine("模型 解好了：\(ex.note)｜版本 \(m.version)")
        return (true, "模型 下好了：版本 \(m.version)｜四张齐")
    }
}
