import Foundation

// MARK: - 一晚一坨，落在沙盒的 Documents/nights 里
//
// 目录名就是开场时刻（20261104-231205），列表按它排序，删旧晚直接把整目录 rm 掉，不留散文件。
//   meta.json     起止／配置／设备／是否正常收尾／引擎重连了几次
//   curve.csv     逐秒曲线（Excel 直接能开，也是导出给医生的那份数）
//   events.jsonl  一行一个事件（发作／疑似中断／其他发声）
//   snippets/     s_<事件号>.wav，16 k 单声道
//   report.txt    收尾时生成的报告；历史列表直接读它，不用每晚重算

struct SnoreNightMeta: Codable {
    var id: String
    var startMs: Double
    var endMs: Double
    var ended: Bool
    var sampleRate: Double
    var restarts: Int
    var blocks: Int
    var seconds: Int
    var config: SnoreConfig
    var device: String
    var note: String

    var startDate: Date { Date(timeIntervalSince1970: startMs / 1000.0) }
    var endDate: Date { Date(timeIntervalSince1970: endMs / 1000.0) }
}

final class SnoreNightStore {
    let dir: URL
    var meta: SnoreNightMeta
    private(set) var buckets: [SnoreSecond] = []
    private(set) var events: [SnoreEvent] = []

    private let fm = FileManager.default

    init(dir: URL, meta: SnoreNightMeta) {
        self.dir = dir
        self.meta = meta
        try? fm.createDirectory(at: snippetsDir, withIntermediateDirectories: true)
    }

    var snippetsDir: URL { dir.appendingPathComponent("snippets") }
    private var curveURL: URL { dir.appendingPathComponent("curve.csv") }
    private var eventsURL: URL { dir.appendingPathComponent("events.jsonl") }
    private var metaURL: URL { dir.appendingPathComponent("meta.json") }
    var reportURL: URL { dir.appendingPathComponent("report.txt") }

    func snippetURL(_ id: Int) -> URL { snippetsDir.appendingPathComponent("s_\(id).wav") }

    // MARK: 追加

    func add(_ b: SnoreSecond) { buckets.append(b) }
    func add(_ e: SnoreEvent) { events.append(e) }

    /// 一声收口后回填的那一格（判定要等响完，格子先发）。整晚的格子按整秒密排——缺的秒也会补
    /// 一格 stale，所以 t0 就是下标；对不上就倒着找一次，再找不到就放弃（那格少涂一点鼾色，
    /// 事件表里的数不受影响）。
    func amend(_ b: SnoreSecond) {
        if b.t0 >= 0, b.t0 < buckets.count, buckets[b.t0].t0 == b.t0 {
            buckets[b.t0] = b
            return
        }
        if let i = buckets.lastIndex(where: { $0.t0 == b.t0 }) { buckets[i] = b }
    }

    /// 每 30 s 落一次盘：整份重写。字符串就 1 MB 量级，比重开 FileHandle _seek 一趟少一处能错的地方，
    /// 而且被系统杀掉时盘上最多丢 30 s——重启后 recover 那条会把起点标出来。
    func flush() {
        writeCurve()
        writeEvents()
        writeMeta()
    }

    func writeCurve() {
        var s = "t0,maxDb,meanDb,snoreSec,vocalSec,maxScore,floorDb,stale\n"
        for b in buckets {
            s += "\(b.t0),\(f2(b.maxDb)),\(f2(b.meanDb)),\(f3(b.snoreSec)),\(f3(b.vocalSec)),\(f3(b.maxScore)),\(f2(b.floorDb)),\(b.stale ? 1 : 0)\n"
        }
        if let d = s.data(using: .utf8) { try? d.write(to: curveURL, options: .atomic) }
    }

    func writeEvents() {
        let enc = JSONEncoder()
        var lines = [String]()
        for e in events {
            if let d = try? enc.encode(e), let s = String(data: d, encoding: .utf8) {
                lines.append(s)
            }
        }
        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        if let d = text.data(using: .utf8) { try? d.write(to: eventsURL, options: .atomic) }
    }

    func writeMeta() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(meta) { try? d.write(to: metaURL, options: .atomic) }
    }

    func writeReport(_ text: String) {
        if let d = text.data(using: .utf8) { try? d.write(to: reportURL, options: .atomic) }
    }

    private func f2(_ v: Double) -> String { String(format: "%.2f", v) }
    private func f3(_ v: Double) -> String { String(format: "%.3f", v) }

    // MARK: 读回来（历史页用）

    static func load(dir: URL) -> SnoreNightStore? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let meta = try? JSONDecoder().decode(SnoreNightMeta.self, from: data) else {
            return nil
        }
        let store = SnoreNightStore(dir: dir, meta: meta)
        store.reloadCurve()
        store.reloadEvents()
        return store
    }

    func reloadCurve() {
        buckets.removeAll()
        guard let text = try? String(contentsOf: curveURL, encoding: .utf8) else { return }
        var first = true
        for raw in text.split(separator: "\n") {
            if first { first = false; continue }        // 表头
            let c = raw.split(separator: ",").map(String.init)
            guard c.count >= 8, let t0 = Int(c[0]) else { continue }
            buckets.append(SnoreSecond(t0: t0,
                                       maxDb: Double(c[1]) ?? -120,
                                       meanDb: Double(c[2]) ?? -120,
                                       snoreSec: Double(c[3]) ?? 0,
                                       vocalSec: Double(c[4]) ?? 0,
                                       maxScore: Double(c[5]) ?? 0,
                                       floorDb: Double(c[6]) ?? -75,
                                       stale: c[7] == "1"))
        }
    }

    func reloadEvents() {
        events.removeAll()
        guard let text = try? String(contentsOf: eventsURL, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        for raw in text.split(separator: "\n") {
            if let d = String(raw).data(using: .utf8), let e = try? dec.decode(SnoreEvent.self, from: d) {
                events.append(e)
            }
        }
    }

    // MARK: 片段

    /// 环形缓冲里截 [from-1.5, to+1.5]，降到 16 k 写 wav。拿不到就返回 nil（界面上那条会显示「片段没留成」）。
    func writeSnippet(id: Int, from: Double, to: Double, ring: SnoreSnippetRing, config: SnoreConfig) -> String? {
        guard config.keepSnippets else { return nil }
        guard let got = ring.capture(from: from - 1.5, to: to + 1.5) else { return nil }
        let resampled = SnoreWav.resample(got.samples, from: got.rate, to: 16000)
        let url = snippetURL(id)
        return SnoreWav.write(resampled, sampleRate: 16000, to: url) ? url.lastPathComponent : nil
    }

    func hasSnippet(_ id: Int) -> Bool {
        return fm.fileExists(atPath: snippetURL(id).path)
    }
}

// MARK: - 跨晚的管理：列目录、开新晚、清旧、回收没收尾的那晚

enum SnoreArchive {
    static let fm = FileManager.default

    static var root: URL? {
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return docs.appendingPathComponent("nights")
    }

    static func ensureRoot() -> URL? {
        guard let root = root else { return nil }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 目录名按本地时间的开场时刻，翻历史的时候一眼认得出是哪一晚。
    static func makeId(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    static func openNight(start: Date, config: SnoreConfig, sampleRate: Double, device: String) -> SnoreNightStore? {
        guard let root = ensureRoot() else { return nil }
        let id = makeId(start)
        let dir = root.appendingPathComponent(id)
        try? fm.createDirectory(at: dir.appendingPathComponent("snippets"), withIntermediateDirectories: true)
        let meta = SnoreNightMeta(id: id, startMs: start.timeIntervalSince1970 * 1000.0,
                                  endMs: start.timeIntervalSince1970 * 1000.0, ended: false,
                                  sampleRate: sampleRate, restarts: 0, blocks: 0, seconds: 0,
                                  config: config, device: device, note: "")
        let store = SnoreNightStore(dir: dir, meta: meta)
        store.writeMeta()
        return store
    }

    /// 从新到旧。坏目录（meta.json 读不出来）直接跳过，不让一晚的数据把整页拖没。
    static func list() -> [SnoreNightStore] {
        guard let root = root,
              let names = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        let sorted = names.sorted { $0.lastPathComponent > $1.lastPathComponent }
        var out: [SnoreNightStore] = []
        for url in sorted {
            if let n = SnoreNightStore.load(dir: url) { out.append(n) }
        }
        return out
    }

    /// 最新一晚的目录名，只翻目录不读 curve.csv。
    /// 「开一晚想知道自己落在哪个目录」这种事别拿 list()：那是把每一晚的逐秒表全解析一遍。
    static func latestId() -> String? {
        guard let root = root,
              let names = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        return names.map { $0.lastPathComponent }.sorted(by: >).first
    }

    static func delete(_ night: SnoreNightStore) {
        try? fm.removeItem(at: night.dir)
    }

    static func deleteAll() {
        guard let root = root else { return }
        try? fm.removeItem(at: root)
        _ = ensureRoot()
    }

    /// 按保留夜数清理；返回删了哪几晚的目录名。
    static func prune(keepNights: Int) -> [String] {
        let all = list()
        guard all.count > keepNights else { return [] }
        var removed: [String] = []
        for n in all.suffix(from: max(0, keepNights)) {
            let id = n.meta.id
            try? fm.removeItem(at: n.dir)
            removed.append(id)
        }
        return removed
    }

    /// 上次没正常收尾（闪退、被杀、没电）：把 ended 补上、写明到几点断的，数据留在历史里。
    static func recoverOpenNights() -> [SnoreNightStore] {
        var fixed: [SnoreNightStore] = []
        for n in list() where !n.meta.ended {
            let lastT = Double(n.buckets.last?.t0 ?? 0)
            let endAt = n.meta.startDate.addingTimeInterval(lastT + 1.0)
            n.meta.endMs = endAt.timeIntervalSince1970 * 1000.0
            n.meta.seconds = n.buckets.count
            n.meta.ended = true
            n.meta.note = "没收到收尾（App 被杀／没电／手动划掉）：数据只到 \(snoreDateText(endAt))"
            n.writeMeta()
            fixed.append(n)
        }
        return fixed
    }

    static func diskFreeMB() -> Double {
        guard let a = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let n = a[.systemFreeSize] as? NSNumber else { return -1 }
        return n.doubleValue / 1_048_576.0
    }
}
