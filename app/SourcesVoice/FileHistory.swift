import Foundation

/// Documents 根目录里这个 app 自己留下的音频（源 / 中间 / 成品）。
///
/// 为什么要单独一页来删：`app/project-voice.yml` 里 `UIFileSharingEnabled` 是开着的，整个 Documents
/// 直接出现在系统「文件」app 里 ⇒ 录过的源、系统原声、转换成品全躺在上面，别人拿到这台手机也翻得到。
/// 界面上播完一次不等于手机上没了。
///
/// 只认自己写的那几种前缀，其余一概不列、也删不到：
/// `voice_models/` 删了要重新下 581 MB，`voice_log.txt` 是唯一的闪退证据，
/// `samples/` 是音色条件（那条清单自己已经有「删」按钮）。
enum FileHistory {
    enum Kind: String, CaseIterable, Identifiable {
        case source = "源音频"
        case raw = "中间音频（系统原声）"
        case output = "最终音频"

        var id: String { rawValue }

        /// 这一类认领哪些文件名前缀。`pick_` 是「选文件」当场拷进来的固化副本，`record_` 是麦克风录的。
        var prefixes: [String] {
            switch self {
            case .source: return ["pick_", "record_"]
            case .raw: return ["tts_raw_"]
            case .output: return ["output_", "novel_"]
            }
        }

        static func kind(ofName name: String) -> Kind? {
            for k in allCases where k.prefixes.contains(where: { name.hasPrefix($0) }) { return k }
            return nil
        }
    }

    struct Item: Identifiable {
        let url: URL
        let kind: Kind
        let bytes: Int64
        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    /// 只扫根目录这一层（不递归），所以模型目录和样本目录天然进不来。
    /// 名字里带的是秒级 epoch，位数固定 ⇒ 按名字排就是按时间排，和样本清单一样新的在前面。
    static func scan() -> [Item] {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
              let names = try? fm.contentsOfDirectory(atPath: docs.path) else { return [] }
        var out: [Item] = []
        for n in names {
            guard let kind = Kind.kind(ofName: n) else { continue }
            let url = docs.appendingPathComponent(n)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let sz = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            out.append(Item(url: url, kind: kind, bytes: sz))
        }
        return out.sorted { $0.name > $1.name }
    }

    static func total(_ items: [Item]) -> Int64 {
        items.reduce(Int64(0)) { $0 + $1.bytes }
    }

    static func human(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    /// 删一个。成不成都落日志——这类动作不留痕就没法回答「我到底删了没」。
    @discardableResult
    static func delete(_ item: Item) -> Bool {
        do {
            try FileManager.default.removeItem(at: item.url)
            VoiceJournal.line("历史文件已删（\(item.kind.rawValue)）\(item.name) \(human(item.bytes))")
            return true
        } catch {
            VoiceJournal.line("历史文件删除失败 \(item.name)：\(error.localizedDescription)")
            return false
        }
    }

    /// 删一批：几个删掉了 / 拿回多少字节 / 几个没删掉。
    static func deleteAll(_ items: [Item]) -> (deleted: Int, freed: Int64, failed: Int) {
        var n = 0
        var freed: Int64 = 0
        var bad = 0
        for it in items {
            if delete(it) {
                n += 1
                freed += it.bytes
            } else {
                bad += 1
            }
        }
        return (n, freed, bad)
    }
}
