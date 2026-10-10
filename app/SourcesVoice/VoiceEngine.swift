import Foundation

/// 一次转换的调度：读数 → ChainDriver → 落盘。算法本体全在 ChainDriver.swift。
///
/// 整件事是纯 CPU 的（几十秒到几分钟），所以真正干活的部分放在 userInitiated 的
/// 分离任务上，别占着调用方的线程；onStage 也在那条线程上被调，实现方自己决定
/// 要不要跳回主线程。
final class VoiceEngine {
    let modelDir: URL

    init(modelDir: URL) {
        self.modelDir = modelDir
    }

    /// inputWav: 用户录的源语音
    /// refWav: 目标音色的参考语音（当前版本先用同一段，后续加参考选择）
    /// outputWav: 转换后的输出路径
    func convert(inputWav: URL, refWav: URL, outputWav: URL,
                 onStage: @escaping (String) -> Void = { VoiceJournal.line($0) }) async throws {
        let dir = modelDir
        try await Task.detached(priority: .userInitiated) {
            VoiceJournal.line("VoiceEngine 开始 \(inputWav.lastPathComponent) / \(refWav.lastPathComponent)")
            let source = try AudioProcessor.loadWAV16K(inputWav)
            let reference = try AudioProcessor.loadWAV16K(refWav)
            onStage("读数完成：源 \(source.count) 样本、参考 \(reference.count) 样本")
            let driver = try ChainDriver(modelDir: dir)
            driver.onStage = { text in
                VoiceJournal.line(text)
                onStage(text)
            }
            let wav = try driver.convert(source: source, reference: reference)
            try AudioProcessor.saveWAV(wav, to: outputWav)
            VoiceJournal.line("已写出 \(wav.count) 样本 → \(outputWav.lastPathComponent)")
        }.value
    }
}
