import Foundation

/// 一次转换的调度：读数 → ChainDriver → 后处理 → 落盘。算法本体全在 ChainDriver.swift。
///
/// 整件事是纯 CPU 的（几秒到几分钟），所以真正干活的部分放在 userInitiated 的
/// 分离任务上，别占着调用方的线程；onStage 也在那条线程上被调，实现方自己决定
/// 要不要跳回主线程。
///
/// 目标音色有两条来源，和官方那两个脚本一一对应：
/// - 样本（`scripts/infer.sh` 的 `--spk-emb-path` + `--prompt-path`）：① 早先算过一次存盘，
///   这次跳过，省下 4.1 s 和那次 386 MB 的 sv 图载入（真机 09:11:40 实测）。
/// - 现场参考音频（`scripts/infer_ref.sh` 的 `--reference-path`）：每次都要重跑 ①。
final class VoiceEngine {
    let modelDir: URL

    init(modelDir: URL) {
        self.modelDir = modelDir
    }

    /// 把一段音频炼成样本存进清单。① 那一次载入是真成本（实测 4.1 s / 峰值足迹 726 MB），
    /// 所以每条参考只做一次，之后反复用。
    ///
    /// 只解前 `ChainDriver.svMaxSecs` 秒：① 的内存随参考长度平方涨，而音色尺 6~11 s 就平了。
    func makeSample(fromWav url: URL, name: String) async throws -> SampleStore.Sample {
        let dir = modelDir
        return try await Task.detached(priority: .userInitiated) {
            VoiceJournal.line("生成样本「\(name)」← \(url.lastPathComponent)")
            let wav = try AudioProcessor.loadWAV16K(url, maxSeconds: ChainDriver.svMaxSecs)
            let driver = try ChainDriver(modelDir: dir)
            let parts = try driver.makeSample(reference: wav)
            return try SampleStore.save(name: name, parts: parts, wav16k: wav)
        }.value
    }

    /// inputWav: 用户要转换的那段
    /// sample / refWav: 目标音色，二选一（sample 优先）
    /// outputWav: 落盘路径
    /// pitchCents: 链外移调（±1200 音分），加在 ④ 声码之后的波形上；语速不做，播放器都有
    func convert(inputWav: URL, sample: SampleStore.Sample?, refWav: URL?,
                 outputWav: URL, pitchCents: Double = 0.0,
                 onStage: @escaping (String) -> Void = { VoiceJournal.line($0) }) async throws {
        let dir = modelDir
        try await Task.detached(priority: .userInitiated) {
            let srcName = inputWav.lastPathComponent
            let how: String
            if let s = sample {
                how = "样本「\(s.info.name)」"
            } else if let r = refWav {
                how = "现场参考 \(r.lastPathComponent)"
            } else {
                throw ChainError.input("既没在清单里选样本，也没有参考音频")
            }
            VoiceJournal.line("VoiceEngine 开始 \(srcName) / \(how)")
            let source = try AudioProcessor.loadWAV16K(inputWav)
            onStage("读数完成：源 \(source.count) 样本")
            let driver = try ChainDriver(modelDir: dir)
            driver.onStage = { text in
                VoiceJournal.line(text)
                onStage(text)
            }
            let wav: [Float]
            if let s = sample {
                let parts = try SampleStore.load(s)
                onStage("用样本：跳过 ①，不载 sv 图")
                wav = try driver.convert(source: source, sample: parts)
            } else if let r = refWav {
                let reference = try AudioProcessor.loadWAV16K(r, maxSeconds: ChainDriver.svMaxSecs)
                onStage("读数完成：参考 \(reference.count) 样本")
                wav = try driver.convert(source: source, reference: reference)
            } else {
                throw ChainError.input("参考没准备起来")
            }
            let shaped = PostProcessor.pitchShift(wav, cents: pitchCents)
            if abs(pitchCents) > 1e-6 {
                VoiceJournal.line(String(format: "后处理 音高 %+.0f 音分：%.2f s → %.2f s",
                                         pitchCents,
                                         Double(wav.count) / AudioProcessor.sampleRate,
                                         Double(shaped.count) / AudioProcessor.sampleRate))
                onStage(String(format: "音高已移 %+.0f 音分", pitchCents))
            }
            try AudioProcessor.saveWAV(shaped, to: outputWav)
            VoiceJournal.line("已写出 \(shaped.count) 样本 → \(outputWav.lastPathComponent)")
        }.value
    }

    // MARK: - 读小说（文本 → 系统 TTS → 现有样本链）

    /// 一次朗读的读数。`tts.line` 就是 A0 那一格的证据。
    struct NovelResult {
        var tts: SystemTTS.Report
        var passes: Int
        var convertedSeconds: Double
        var rawURL: URL
    }

    /// 一片进链的时长。按片而不是按句的理由写在下面那条注释里。
    static let novelPassSeconds: Double = 120

    /// 原声和转换后两条 16 kHz float 数组要一起揣在兜里的上限：1800 s 音频 = 2×115 MB。
    /// 超线在开跑之前就拒（拿实测的 4.1 字/秒估），别等顶到前台水位线被系统杀掉。
    static let maxNovelSeconds: Double = 1800

    /// 文本 → 分句系统朗读 → 按片过 ②③④ → 拼成一个 wav（播放器只吃一个文件）。
    ///
    /// 为什么按片：ChainDriver 每段跑完就把图关掉（编码器三张 + DiT 七张 + vocos 一张
    /// ≈343 MB 的载入）。按句转换 = 每句重开一遍图，300 句就是 300 次。按片切只落在句读上
    /// ⇒ 编码器缓存清零正好赶上停顿，听不见接缝；图和样本条件整趟只载一次。
    ///
    /// 音色来源和 `convert` 一样：样本优先，没样本就用现场参考；两者都空直接报错
    /// （文本没有"自转换"这一说——源是合成声，转给自己听没意义）。
    /// rawTTSWav: 系统原声也存一份，好和转换后的对着听。
    func readNovel(text: String, sample: SampleStore.Sample?, refWav: URL?,
                   outputWav: URL, rawTTSWav: URL, pitchCents: Double = 0.0,
                   onStage: @escaping (String) -> Void = { VoiceJournal.line($0) }) async throws -> NovelResult {
        let dir = modelDir
        return try await Task.detached(priority: .userInitiated) {
            let sents = SystemTTS.sentences(from: text)
            guard !sents.isEmpty else { throw ChainError.input("文本切完是空的（全是空白？）") }
            let est = Double(text.count) / 4.1          // PC 实测：系统 TTS 念中文 ≈4.1 字/秒
            guard est <= VoiceEngine.maxNovelSeconds else {
                throw ChainError.input(String(format: "%d 字 ≈ %.0f 分钟音频，超 %.0f 分钟的上限"
                                                + "（原声＋转换后两条波形都要同时在内存里）⇒ 请分章",
                                              text.count, est / 60, VoiceEngine.maxNovelSeconds / 60))
            }
            let voice = SystemTTS.pickVoice()
            let how = voice.map { "语音 \($0.identifier)（\($0.language)）" } ?? "系统默认语音"
            VoiceJournal.line("读小说开跑：\(text.count) 字 → \(sents.count) 句／\(how)／装了的中文 voice \(SystemTTS.chineseVoices().count) 个")
            onStage("TTS 探针：\(how)")

            let driver = try ChainDriver(modelDir: dir)
            driver.onStage = { text in
                VoiceJournal.line(text)
                onStage(text)
            }
            let parts: ChainDriver.SampleParts
            if let s = sample {
                parts = try SampleStore.load(s)
                onStage("音色用样本「\(s.info.name)」：跳过 ①，不载 sv 图")
            } else if let r = refWav {
                let reference = try AudioProcessor.loadWAV16K(r, maxSeconds: ChainDriver.svMaxSecs)
                onStage("音色用现场参考 \(r.lastPathComponent)：读数 \(reference.count) 样本")
                parts = try driver.makeSample(reference: reference)
            } else {
                throw ChainError.input("既没在清单里选样本，也没有参考音频")
            }

            let pump = TTSPump(voice: voice)
            var rawAll: [Float] = []
            var convAll: [Float] = []
            var pending: [Float] = []
            var passes = 0
            let t0 = Date()
            for (i, s) in sents.enumerated() {
                pending.append(contentsOf: try pump.speak(s))
                let last = (i == sents.count - 1)
                if Double(pending.count) / SystemTTS.sampleRate >= VoiceEngine.novelPassSeconds || last {
                    passes += 1
                    let inSec = Double(pending.count) / SystemTTS.sampleRate
                    VoiceJournal.line(String(format: "第 %d 片：%d/%d 句，进链 %.1f s（累计音频 %.1f s）",
                                             passes, i + 1, sents.count, inSec, pump.report.seconds))
                    onStage(String(format: "第 %d 片进链（%.0f s 音频，累计 %d/%d 句）",
                                   passes, inSec, i + 1, sents.count))
                    convAll.append(contentsOf: try driver.convert(source: pending, sample: parts))
                    rawAll.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                } else if i % 10 == 9 {
                    onStage(String(format: "念到第 %d/%d 句，累计 %.0f s 音频", i + 1, sents.count, pump.report.seconds))
                }
            }
            pump.finish()

            let shaped = PostProcessor.pitchShift(convAll, cents: pitchCents)
            try AudioProcessor.saveWAV(rawAll, to: rawTTSWav)
            try AudioProcessor.saveWAV(shaped, to: outputWav)
            VoiceJournal.line(pump.report.line)
            VoiceJournal.line(String(format: "读小说完成：%d 片，转换后 %.2f s，整趟墙钟 %.1f s → %@",
                                     passes, Double(shaped.count) / SystemTTS.sampleRate,
                                     Date().timeIntervalSince(t0), outputWav.lastPathComponent))
            return NovelResult(tts: pump.report, passes: passes,
                               convertedSeconds: Double(shaped.count) / SystemTTS.sampleRate,
                               rawURL: rawTTSWav)
        }.value
    }
}
