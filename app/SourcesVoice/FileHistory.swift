import Foundation

/// Documents 根目录里这个 app 自己留下的音频和视频（源 / 中间 / 成品）。
///
/// 为什么要单独一页来删：`app/project-voice.yml` 里 `UIFileSharingEnabled` 是开着的，整个 Documents
/// 直接出现在系统「文件」app 里 ⇒ 录过的源、系统原声、转换成品、换了声的视频全躺在上面，
/// 别人拿到这台手机也翻得到。界面上播完一次不等于手机上没了。
///
/// 只认自己写的那几种前缀，其余一概不列、也删不到：
/// `voice_models/` 删了要重新下 581 MB，`voice_log.txt` 是唯一的闪退证据，
/// `samples/` 是音色条件（那条清单自己已经有「删」按钮）。
enum FileHistory {
    enum Kind: String, CaseIterable, Identifiable {
        /// `pick_` 既可能是音频也可能是视频（音频走「选文件」、视频走相册，两个入口同一个前缀、同一个落点），
        /// 所以这一格的名字必须两种都能对上，不然他在清理页看到一个 mp4 躺在「源音频」下会以为显示错了。
        case source = "源（音频/视频）"
        case raw = "中间音频（系统原声）"
        case output = "最终音频"
        /// 视频换声这一条的三件：成品 mp4 + 转换后 wav + 对齐后 wav，全用 `video_` 前缀。
        /// 中间那两份跑成了会自己删；崩在半路留下的归这一格收。
        case video = "视频（成品与中间）"

        var id: String { rawValue }

        /// 这一类认领哪些文件名前缀。`pick_` 是「选文件」当场拷进来的固化副本，`record_` 是麦克风录的。
        var prefixes: [String] {
            switch self {
            case .source: return ["pick_", "record_"]
            case .raw: return ["tts_raw_"]
            case .output: return ["output_", "novel_"]
            case .video: return ["video_"]
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
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            VoiceJournal.line("历史文件：拿不到 Documents 路径")
            return []
        }
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: docs.path)
        } catch {
            let ne = error as NSError
            VoiceJournal.line("历史文件列目录失败：\(ne.domain)#\(ne.code)｜\(ne.localizedDescription)"
                              + "｜目录 \(docs.path)")
            return []
        }
        var out: [Item] = []
        for n in names {
            guard let kind = Kind.kind(ofName: n) else { continue }
            let url = docs.appendingPathComponent(n)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let sz = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            out.append(Item(url: url, kind: kind, bytes: sz))
        }
        // 「目录里一共几项」和「本 app 认领几项」必须分开报：上一版只报认领数，
        // 于是「列目录列不到」和「文件名字对不上前缀」在这行日志里长得一模一样。
        VoiceJournal.line("历史文件扫目录：\(names.count) 项／认领 \(out.count) 个")
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
            let ne = error as NSError
            VoiceJournal.line("历史文件删除失败 \(item.name)：\(ne.domain)#\(ne.code)｜\(ne.localizedDescription)")
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
