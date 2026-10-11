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
    func makeSample(fromWav url: URL, name: String) async throws -> SampleStore.Sample {
        let dir = modelDir
        return try await Task.detached(priority: .userInitiated) {
            VoiceJournal.line("生成样本「\(name)」← \(url.lastPathComponent)")
            let wav = try AudioProcessor.loadWAV16K(url)
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
                let reference = try AudioProcessor.loadWAV16K(r)
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
}
