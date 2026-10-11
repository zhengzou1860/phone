import Foundation

/// 样本清单的磁盘那一侧。
///
/// 一条样本 = `Documents/samples/<编号>/` 一个文件夹：
///   meta.json    名字、生成时间、spk 的形状、录音时长
///   spk.f32      音色向量（本机字节序的 Float32 数组，和 Fixtures/*.f32 同一个口径）
///   prompts.f32  150×80 的 prompt mel
///   ref.wav      生成它用的那段 16 kHz 录音（留着才能重算／以后换 prompt；30 s ≈ 1.9 MB）
///
/// 文件夹名用时间戳不用名字：改名只动 meta.json，界面上的选中状态（按文件夹认）不会跟着漂。
enum SampleStore {
    struct Info: Codable {
        var name: String
        var created: String
        var spkDims: [Int]
        var seconds: Double
    }

    struct Sample: Identifiable, Equatable {
        var dir: URL
        var info: Info
        var id: String { dir.lastPathComponent }
    }

    struct Stale: Error { var text: String }

    static let embCount = 256
    static let promptCount = ChainDriver.promptFrames * MelFrontEnd.nMels

    static func root() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("samples")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 按生成时间倒序（新的排前面）。坏条目（meta.json 读不出、f32 长度不对）直接跳过，
    /// 不让一条脏数据把整个清单变成空。
    static func list() -> [Sample] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root(),
                                                     includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [Sample] = []
        for d in dirs {
            guard let info = readMeta(d), complete(d, info: info) else { continue }
            out.append(Sample(dir: d, info: info))
        }
        return out.sorted { $0.info.created > $1.info.created }
    }

    static func save(name: String, parts: ChainDriver.SampleParts, wav16k: [Float]) throws -> Sample {
        let ts = Int(Date().timeIntervalSince1970)
        let dir = root().appendingPathComponent("spk_\(ts)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let info = Info(name: name,
                        created: stamp(),
                        spkDims: parts.spkDims,
                        seconds: Double(wav16k.count) / AudioProcessor.sampleRate)
        do {
            try writeFloats(parts.spk, to: dir.appendingPathComponent("spk.f32"))
            try writeFloats(parts.prompts, to: dir.appendingPathComponent("prompts.f32"))
            try AudioProcessor.saveWAV(wav16k, to: dir.appendingPathComponent("ref.wav"))
            try writeMeta(info, to: dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            VoiceJournal.line("样本落盘失败，已回收 \(dir.lastPathComponent)：\(error.localizedDescription)")
            throw error
        }
        VoiceJournal.line(String(format: "生成样本「%@」spk %d 个 / prompt %d 个 / 录音 %.2f s → %@",
                                 name, parts.spk.count, parts.prompts.count, info.seconds,
                                 dir.lastPathComponent))
        return Sample(dir: dir, info: info)
    }

    static func load(_ s: Sample) throws -> ChainDriver.SampleParts {
        let spk = try readFloats(s.dir.appendingPathComponent("spk.f32"))
        let prompts = try readFloats(s.dir.appendingPathComponent("prompts.f32"))
        guard spk.count == embCount else {
            throw Stale(text: "样本「\(s.info.name)」的音色向量是 \(spk.count) 个，要 \(embCount) 个")
        }
        guard prompts.count == promptCount else {
            throw Stale(text: "样本「\(s.info.name)」的 prompt 是 \(prompts.count) 个数，要 \(promptCount) 个")
        }
        return ChainDriver.SampleParts(spkDims: s.info.spkDims.isEmpty ? [1, embCount] : s.info.spkDims,
                                       spk: spk, prompts: prompts)
    }

    static func rename(_ s: Sample, to name: String) throws -> Sample {
        var info = s.info
        info.name = name
        try writeMeta(info, to: s.dir)
        VoiceJournal.line("样本改名 \(s.info.name) → \(name)（\(s.dir.lastPathComponent)）")
        return Sample(dir: s.dir, info: info)
    }

    static func delete(_ s: Sample) {
        do {
            try FileManager.default.removeItem(at: s.dir)
            VoiceJournal.line("样本已删 \(s.info.name)（\(s.dir.lastPathComponent)）")
        } catch {
            VoiceJournal.line("样本删除失败 \(s.info.name)：\(error.localizedDescription)")
        }
    }

    /// 这条样本还能不能用（转换前拦一下，别跑到 ③ 才炸）
    static func refWav(_ s: Sample) -> URL { s.dir.appendingPathComponent("ref.wav") }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    private static func complete(_ dir: URL, info: Info) -> Bool {
        let fm = FileManager.default
        for n in ["spk.f32", "prompts.f32"] {
            let p = dir.appendingPathComponent(n).path
            guard let sz = (try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber,
                  sz.intValue == (n == "spk.f32" ? embCount : promptCount) * MemoryLayout<Float>.size
            else { return false }
        }
        return fm.fileExists(atPath: dir.appendingPathComponent("ref.wav").path)
    }

    private static func readMeta(_ dir: URL) -> Info? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: d)
    }

    private static func writeMeta(_ info: Info, to dir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try enc.encode(info).write(to: dir.appendingPathComponent("meta.json"))
    }

    private static func writeFloats(_ a: [Float], to url: URL) throws {
        let data = a.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url)
    }

    private static func readFloats(_ url: URL) throws -> [Float] {
        let d = try Data(contentsOf: url)
        let n = d.count / MemoryLayout<Float>.size
        guard n > 0 else { throw Stale(text: "\(url.lastPathComponent) 是空的") }
        var a = [Float](repeating: 0, count: n)
        d.copyBytes(to: &a, count: n)
        return a
    }
}
