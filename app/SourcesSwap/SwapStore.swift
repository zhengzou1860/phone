import Foundation
import CryptoKit

/// 模型仓库：两张网不再跟着 ipa 走，改成单独下到手机上一次。
///
/// 为什么：ipa 里带着几百 MB 权重，换程序就得把那几百 MB 重装一遍（这一条线每轮都在改程序）。
/// 模型单独放一份在 Documents/swap_models 里，程序随便改；模型版本没变就不重新下。
/// 版本号＝两张 onnx 的 sha256 再加转换配方那一句（CI 那头算），所以「换模型」和「改程序」这两件事在盘上是分开的：
/// 程序改完装上去，那一份模型原封不动；只有模型本身（或转换配方）换了，手机上那份才会被换掉。
///
/// 这一版 fsx 那条链路带的两样：fsx_arc.mlpackage／fsx_swap.mlpackage（hyperswap_1a_256）。
/// 换脸网收的就是归一化后的 512 维向量，不再需要 inswapper 那张 emap 矩阵。
///
/// 发布位：CI 把这些打成两个文件，挂在 channel-swap 这条 release 上：
///   models.json  清单：版本号＋整包 sha256＋每个文件的大小
///   models.bin   归档：文件头 "SWPM"＋uint32 头长（4 字节小端）＋JSON 头＋各文件字节依次排下去
///   （不用 zip：iOS 没有现成的解 zip，逐段 inflate 得自己写一套；存成不压缩的归档省掉那一整套，
///     少一个能出错的环节比省几十 MB 划算）
enum SwapStore {
    /// 模型从哪儿下：清单和归档分开排。
    ///
    /// 清单（1 KB）以 GitHub 上那条发布位为准，局域网那份只当兜底：版本号是「这两张网换没换」的凭据，
    /// 不能让电脑上一份旧的说了算。
    /// 归档（这一版：两张 fp32 网，不含 emap）反过来，先走局域网上那台电脑：
    /// 手机直连 GitHub 那条路被掐着走时能爬一两个小时（实测 30 KB/s，同一台电脑上却是 4.5 MB/s）；
    /// 走局域网两三分半钟就完。哪条下来的都过 sha256，对不上就换下一条。
    static let manifestBases = [
        "https://github.com/zhengzou1860/phone/releases/download/channel-swap",
        "http://192.168.31.99:8716",
        "http://192.168.31.100:8716",
    ]
    static let archiveBases = [
        "http://192.168.31.99:8716",
        "http://192.168.31.100:8716",
        "https://github.com/zhengzou1860/phone/releases/download/channel-swap",
    ]
    static let manifestName = "models.json"
    static let archiveName = "models.bin"
    static let dirName = "swap_models"

    /// 本版链路的口径标记：归档里带一份 chain.txt，内容对得上才算「这一版的模型」。
    /// 两张资源名没变（fsx_swap.mlpackage），旧版装过的那份同名包光看名字分不出来——
    /// 不带这一关，升级后第一次出片会在接口对账那一刻才炸（256 的入参在 128 的包里找不到）。
    static let chainTag = "hyperswap-1a-256"

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

    /// 两张网（顺序＝身份证／换脸）
    static var resources: [String] {
        [FsxNets.arcResource, FsxNets.swapResource]
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

    static func chainTagOK() -> Bool {
        guard let d = dir,
              let s = try? String(contentsOf: d.appendingPathComponent("chain.txt"), encoding: .utf8)
        else { return false }
        return s.trimmingCharacters(in: .whitespacesAndNewlines) == chainTag
    }

    /// 口径标记对得上、两张都在、Manifest.json 也都在，才算齐。
    /// 半个 mlpackage 进 compileModel 会炸，所以清单文件也得在。
    static func haveAll() -> Bool {
        guard chainTagOK() else { return false }
        for r in resources {
            guard let p = local(r) else { return false }
            guard FileManager.default.fileExists(atPath: p.appendingPathComponent("Manifest.json").path) else { return false }
        }
        return true
    }

    /// 把这一版用不上的旧模型先腾掉。
    /// 为什么要在下载之前就腾：归档落盘和解出来的两张网落盘在那一刻是同时存在的，
    /// 旧那四张（~345 MB）要还占着，手机就得一口气空出 1.7 GB 才够——空间不够最烦的不是失败，
    /// 是下到 90 % 写不进去、几条源全这么废一轮还看不出为什么。
    /// 认这一版要的就是 resources 那两张，别的 *.mlpackage 一律是上一版留下的，删了不影响 haveAll()。
    /// 返回删掉的名字（进流水，好核对到底腾出多少）。
    @discardableResult
    static func purgeStale(_ at: URL? = nil) -> [String] {
        let d = at ?? dir
        guard let d else { return [] }
        let fm = FileManager.default
        let keep = Set(resources.map { "\($0).mlpackage" })
        var gone: [String] = []
        guard let all = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey], options: []) else {
            return []
        }
        for u in all {
            let n = u.lastPathComponent
            let stale = (u.pathExtension == "mlpackage" && !keep.contains(n))
                || n == "archive.part" || n == "emap.bin"     // emap 是上一版 inswapper 的口径，本版没有这一步
            guard stale else { continue }
            let mb = Double((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / 1_048_576
            do {
                try fm.removeItem(at: u)
                gone.append("\(n)（\(String(format: "%.0f", mb)) MB）")
            } catch {
                gone.append("\(n) 删不掉：\(error.localizedDescription)")
            }
        }
        return gone
    }

    /// 装得下才开工：归档＋解出来的两张网同时存在，再留 300 MB 余量。
    /// 量不出来（拿不到文件系统属性）不拦，让真跑那一次去说话——这里只管「明摆着不够」那一种。
    static func fitsArchive(_ bytes: Int) -> Bool {
        guard let a = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let n = a[.systemFreeSize] as? NSNumber else { return true }
        return n.int64Value >= Int64(bytes) * 2 + 300_000_000
    }

    static func statusLine() -> String {
        if haveAll() { return "已下好 版本 \(localVersion())｜两张网齐（\(chainTag)）" }
        let v = localVersion()
        return v.isEmpty ? "没下（点「下模型」，或直接开始换脸会自动下）"
                         : "没下齐（盘上版本 \(v) 不全）"
    }

    // MARK: - 清单

    /// 清单就几 KB：版本对得上就不用再动那几百 MB。
    /// 挨个源试，第一个通的就算；note 里带上是哪一条源通的。
    static func fetchManifest(timeout: TimeInterval = 30) -> (m: Manifest?, note: String, base: String?) {
        var why: [String] = []
        for b in manifestBases {
            guard let url = URL(string: "\(b)/\(manifestName)") else { why.append("\(b) 地址非法"); continue }
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
            if sem.wait(timeout: .now() + timeout + 5) == .timedOut {
                why.append("\(b) 超时 \(Int(timeout)) s")
                continue
            }
            guard code == 200, let d = data else {
                why.append("\(b) HTTP \(code) \(err)")
                continue
            }
            do {
                let m = try JSONDecoder().decode(Manifest.self, from: d)
                return (m, "清单 \(d.count) 字节｜版本 \(m.version)｜源 \(b)", b)
            } catch {
                why.append("\(b) 清单解不开：\(error)")
            }
        }
        return (nil, "拿不到清单：" + why.joined(separator: "；"), nil)
    }

    // MARK: - 下载

    /// 下载任务 + 进度。didFinishDownloadingTo 给的那个临时文件在这个方法返回后就没了，
    /// 所以当场挪到自己的路径上（挪晚了文件已经不在）。
    final class Grabber: NSObject, URLSessionDownloadDelegate {
        var onProgress: ((Int64, Int64) -> Void)?
        var onStatus: ((String) -> Void)?
        private let sem = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var dst: URL?
        private var note = ""
        private var code = -1
        private var lastAt: UInt64 = DispatchTime.now().uptimeNanoseconds
        private var finished = false
        private var saidStatus = false

        /// 这么久没有新字节就当这条源卡住了。挂着的下载最烦：不动、也不报错，等它一小时。
        static let stallSec: Double = 45

        private func setNote(_ text: String) {
            lock.lock()
            if note.isEmpty { note = text }
            lock.unlock()
        }

        private func markFinished(_ text: String) {
            setNote(text)
            lock.lock()
            finished = true
            lock.unlock()
            sem.signal()
        }

        func grab(_ url: URL, to dst: URL, timeout: TimeInterval) -> (ok: Bool, note: String) {
            self.dst = dst
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 60
            cfg.timeoutIntervalForResource = timeout
            let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            task.resume()
            // 看门狗：卡住的源掐掉，让上面换下一条，别在一棵树上吊死
            DispatchQueue.global().async { [weak self] in
                while let s = self {
                    s.lock.lock()
                    let fin = s.finished
                    let idle = Double(DispatchTime.now().uptimeNanoseconds - s.lastAt) / 1e9
                    s.lock.unlock()
                    if fin { return }
                    if idle > Grabber.stallSec {
                        s.markFinished("这条源卡住了：\(Int(idle)) s 没有新字节")
                        task.cancel()
                        return
                    }
                    Thread.sleep(forTimeInterval: 2)
                }
            }
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
            lock.lock()
            lastAt = DispatchTime.now().uptimeNanoseconds
            let first = !saidStatus
            saidStatus = true
            let resp = downloadTask.response
            lock.unlock()
            if first, let r = resp as? HTTPURLResponse {
                onStatus?("模型 归档 HTTP \(r.statusCode)｜\(r.url?.absoluteString ?? urlText(resp))")
            }
            onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
        }

        private func urlText(_ resp: URLResponse?) -> String {
            guard let u = resp?.url else { return "?" }
            return u.absoluteString
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else { setNote("模型归档 HTTP \(code)（发布位上还没有这一份？）"); return }
            do {
                if let d = dst { try? FileManager.default.removeItem(at: d) }
                try FileManager.default.moveItem(at: location, to: dst ?? location)
            } catch {
                setNote("下下来的文件挪不走：\(error.localizedDescription)")
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { setNote("下载失败：\(error.localizedDescription)") }
            lock.lock()
            finished = true
            lock.unlock()
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
        purgeStale(dir)
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
        guard haveAll() else { return (false, "解完了但两张网／\(chainTag) 没齐（清单 \(man.files.count) 个文件）") }
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
        let (man, mnote, _) = fetchManifest()
        guard let m = man else { return (false, "模型 \(mnote)") }
        onLine("模型 清单到手：\(mnote)｜\(String(format: "%.0f", Double(m.bytes) / 1_048_576)) MB")
        if haveAll() && localVersion() == m.version {
            return (true, "模型 盘上那一份就是最新的（版本 \(m.version)），不用重下")
        }
        // 先腾地方再下载：旧版那几张对本版一点用都没有（haveAll() 认的是这两张），
        // 却要在下载这一刻和归档同时占着盘，挤不下就是半截失败。
        let cleared = purgeStale(dir)
        if !cleared.isEmpty { onLine("模型 先腾掉上一版留下的：\(cleared.joined(separator: "、"))") }
        guard fitsArchive(m.bytes) else {
            let need = String(format: "%.1f", Double(m.bytes) * 2 / 1_048_576_000 + 0.3)
            return (false, "模型 手机上的可用空间不够：这一份要能同时放下归档和解开的两张网，约 \(need) GB，"
                + "现在只剩 \(SwapFacts.diskFreeGB()) GB｜先清一清（旧视频、旧照片）再点「下模型」")
        }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            return (false, "模型 建不出目录：\(error.localizedDescription)")
        }
        let tmp = dir.appendingPathComponent("archive.part")
        var why: [String] = []
        for b in archiveBases {
            guard let url = URL(string: "\(b)/\(archiveName)") else { why.append("\(b) 地址非法"); continue }
            try? fm.removeItem(at: tmp)
            let grab = Grabber()
            var lastMB = -1
            grab.onStatus = { onLine($0) }
            grab.onProgress = { got, total in
                let mb = Int(got / 1_048_576)
                if mb - lastMB >= 16 || (total > 0 && got >= total) {
                    lastMB = mb
                    let tot = total > 0 ? String(format: "%.0f", Double(total) / 1_048_576) : "?"
                    onLine("模型 下到 \(mb)/\(tot) MB（\(b)）")
                }
            }
            let g = grab.grab(url, to: tmp, timeout: 1800)
            guard g.ok else {
                try? fm.removeItem(at: tmp)
                why.append("\(b) \(g.note)")
                onLine("模型 这条源不成：\(g.note)｜换下一条")
                continue
            }
            guard let sha = sha256(tmp) else {
                try? fm.removeItem(at: tmp)
                why.append("\(b) sha256 算不出来")
                continue
            }
            guard sha == m.sha256 else {
                try? fm.removeItem(at: tmp)
                why.append("\(b) 整包 sha256 对不上（要 \(m.sha256.prefix(12))… 拿到 \(sha.prefix(12))…）")
                onLine("模型 \(b) 那份对不上（多半是电脑上的缓存旧了）｜换下一条")
                continue
            }
            onLine("模型 整包 sha256 对上了（\(sha.prefix(12))…）｜开始解包")
            let ex = extract(tmp, manifest: m, to: dir)
            try? fm.removeItem(at: tmp)
            guard ex.ok else {
                why.append("\(b) \(ex.note)")
                continue
            }
            try? m.version.write(to: dir.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true          // 几百 MB 权重不进 iCloud 备份
            var modelDir = dir                       // setResourceValues 是 mutating 的，URL 得是可改的
            try? modelDir.setResourceValues(rv)
            onLine("模型 解好了：\(ex.note)｜版本 \(m.version)")
            return (true, "模型 下好了：版本 \(m.version)｜两张网齐（\(chainTag)）")
        }
        return (false, "模型 几条源都没成：" + why.joined(separator: "；"))
    }
}
