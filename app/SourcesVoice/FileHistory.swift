import Foundation

/// 这个 app 在沙盒里留下的东西：Documents 根目录的音频（源 / 中间 / 成品）+ 临时目录里选文件的原件。
///
/// 为什么要单独一页来删：`app/project-voice.yml` 里 `UIFileSharingEnabled` 是开着的，整个 Documents
/// 直接出现在系统「文件」app 里 ⇒ 录过的源、系统原声、转换成品全躺在上面，别人拿到这台手机也翻得到。
/// 界面上播完一次不等于手机上没了。
///
/// Documents 那一半只认自己写的那几种前缀，其余一概不列、也删不到：
/// `voice_models/` 删了要重新下 581 MB，`voice_log.txt` 是唯一的闪退证据，
/// `samples/` 是音色条件（那条清单自己已经有「删」按钮）。
enum FileHistory {
    enum Kind: String, CaseIterable, Identifiable {
        case source = "源音频"
        case raw = "中间音频（系统原声）"
        case output = "最终音频"
        case temp = "临时目录（选文件的原件）"

        var id: String { rawValue }

        /// 这一类认领哪些文件名前缀。`pick_` 是「选文件」当场拷进 Documents 的固化副本，`record_` 是麦克风录的。
        /// `.temp` 不按名字认，整个目录都是可丢的，所以前缀表是空的。
        var prefixes: [String] {
            switch self {
            case .source: return ["pick_", "record_"]
            case .raw: return ["tts_raw_"]
            case .output: return ["output_", "novel_"]
            case .temp: return []
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
        /// 界面上那一行显示什么。临时目录里的条目带相对路径，不然只显示 `Qq.wav` 看不出它躲在哪个子目录。
        let label: String
        var id: String { url.path }
    }

    /// Documents 根目录那一半。只扫一层（不递归），所以模型目录和样本目录天然进不来。
    /// 名字里带的是秒级 epoch，位数固定 ⇒ 按名字排就是按时间排，和样本清单一样新的在前面。
    static func scanDocuments() -> [Item] {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
              let names = try? fm.contentsOfDirectory(atPath: docs.path) else { return [] }
        var out: [Item] = []
        for n in names {
            guard let kind = Kind.kind(ofName: n) else { continue }
            let url = docs.appendingPathComponent(n)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            out.append(Item(url: url, kind: kind, bytes: sizeOf(url.path), label: n))
        }
        return out.sorted { $0.label > $1.label }
    }

    /// 临时目录那一半。iOS 只清**它自己管的**容器里的 tmp，LiveContainer 那层嵌套容器（`data/Application/<id>/tmp`）
    /// 它不管 ⇒ 「选文件」`asCopy:true` 留下的原件一直堆在那儿（他就是在这儿看见文件的）。
    /// 往下走两层、**不跳过隐藏项**：那份原件躲在 `com.apple.*` 子目录里，跳过隐藏项正好把他问的那批漏掉。
    static func scanTemp() -> [Item] {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
        var out: [Item] = []
        walk(root, depth: 1, limit: 2) { url in
            let rel = url.path.hasPrefix(root.path + "/")
                ? String(url.path.dropFirst(root.path.count + 1))
                : url.lastPathComponent
            out.append(Item(url: url, kind: .temp, bytes: sizeOf(url.path), label: rel))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    static func scan() -> [Item] { scanDocuments() + scanTemp() }

    private static func walk(_ dir: URL, depth: Int, limit: Int, onFile: (URL) -> Void) {
        guard depth <= limit else { return }
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsSubdirectoryDescendants]) else { return }
        for u in kids {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { walk(u, depth: depth + 1, limit: limit, onFile: onFile) }
            else { onFile(u) }
        }
    }

    private static func sizeOf(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
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
            VoiceJournal.line("历史文件已删（\(item.kind.rawValue)）\(item.label) \(human(item.bytes))")
            return true
        } catch {
            VoiceJournal.line("历史文件删除失败 \(item.label)：\(error.localizedDescription)")
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
