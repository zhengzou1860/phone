import Foundation
import AVFoundation

/// WAV ↔ 16 kHz 单声道 ↔ 两条 mel 前端的取数入口。频谱本体在 MelFrontEnd.swift。
///
/// 采样的事：录音按设备原生格式落盘（iPhone 上通常是 48 kHz Float32），
/// 模型这一侧全都钉在 16 kHz，所以读数时统一走 AVAudioConverter 降到 16k 单声道。
enum AudioProcessor {

    /// 全链路采样率。DiT / Vocos / 两个 mel 前端都是这个口径，改这里等于换模型。
    static let sampleRate: Double = 16000

    /// 一次性把整个文件按**原生**格式读进内存，代价 = 帧数 × 声道 × 4 字节：
    /// 48 kHz 立体声 1 分钟 23 MB、30 分钟 1.15 GB。iPhone 11 前台水位线约 2040 MB
    /// （真机实测 ① 在 40.6 s 参考上顶到 1749 MB），到那一格不是报错而是被系统杀掉，
    /// 连日志都带不走 ⇒ 开读之前先按文件头算账，超线就拒。
    static let maxDecodeMB: Double = 512

    /// 读任意 WAV/CAF → 16 kHz 单声道 Float32，值域 [-1,1]
    ///
    /// `maxSeconds` 只读文件头这么多秒（参考音频用得上：音色只看前几秒，
    /// 而整读一小时素材要先在内存里摊出 1.4 GB）。nil = 整读。
    static func loadWAV16K(_ url: URL, maxSeconds: Double? = nil) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        let wantFrames = maxSeconds.map { min(Double(file.length), $0 * inFmt.sampleRate) } ?? Double(file.length)
        let needMB = wantFrames * Double(inFmt.channelCount) * 4.0 / 1e6
        guard needMB <= maxDecodeMB else {
            let roomSecs = maxDecodeMB * 1e6 / (Double(inFmt.channelCount) * 4.0 * inFmt.sampleRate)
            throw fail(String(format: "%@ 解开来要 %.0f MB（%d 帧 / %d Hz / %d 声道 ≈ %.0f s），"
                                + "超过 %.0f MB 的水位保护 ⇒ 先剪到 %.0f 分钟以内",
                               url.lastPathComponent, needMB, Int(file.length),
                               Int(inFmt.sampleRate), Int(inFmt.channelCount),
                               Double(file.length) / inFmt.sampleRate, maxDecodeMB, roomSecs / 60))
        }
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false) else {
            throw fail("拿不到 16k 单声道格式")
        }
        guard let converter = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw fail("AVAudioConverter 建不出来：\(inFmt.sampleRate)Hz/\(Int(inFmt.channelCount))ch → 16000Hz/1ch")
        }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt,
                                          frameCapacity: AVAudioFrameCount(wantFrames)) else {
            throw fail("输入 buffer 分配失败（\(Int(wantFrames)) 帧）")
        }
        // frameCapacity 就是 wantFrames ⇒ 这一次 read 最多吃这么多帧，不必再给 frameCount
        try file.read(into: inBuf)

        let ratio = sampleRate / inFmt.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: capacity) else {
            throw fail("输出 buffer 分配失败（\(capacity) 帧）")
        }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            fed = true
            return inBuf
        }
        if let error = error { throw error }
        guard status != .error else { throw fail("转换返回 .error（输入 \(inBuf.frameLength) 帧）") }

        guard let chan = outBuf.floatChannelData?[0] else {
            throw fail("转换结果拿不到 floatChannelData")
        }
        return Array(UnsafeBufferPointer(start: chan, count: Int(outBuf.frameLength)))
    }

    /// 写 16 kHz 单声道 PCM（Vocos 出来的就是这个口径）
    ///
    /// 峰值过满刻度要压回来：fp16 整链在真素材上实测输出峰值 **1.084**（标准 euler 那版），
    /// float WAV 存得下，但手机上放出来那一下是硬削顶。压的是整体线性增益，
    /// 不改 mel、不改内容/音色那两把尺的读数。
    static func saveWAV(_ samples: [Float], to url: URL, sampleRate: Double = 16000) throws {
        var samples = samples
        var peak: Float = 0
        for v in samples {
            let a = abs(v)
            if a > peak { peak = a }
        }
        if peak > 1.0 {
            let gain: Float = 0.999 / peak
            VoiceJournal.line(String(format: "输出峰值 %.4f 越过满刻度 ⇒ 整体乘 %.4f 压回", peak, gain))
            for i in 0..<samples.count { samples[i] *= gain }
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false) else {
            throw fail("写盘格式建不出来")
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw fail("写盘 buffer 分配失败（\(samples.count) 帧）")
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buf)
    }

    /// kaldi 那一侧的定标：训练时 fbank 吃的是乘过 1<<15 的整数域样本
    static func scaled(_ norm: [Float]) -> [Float] {
        norm.map { $0 * 32768.0 }
    }

    /// librosa 的 mel 基（80×513 行主序）。训练侧前端的常量，随包发数据、不在 Swift 里重抄公式。
    static func melBasis() -> [Float]? { MelFrontEnd.loadFloats("librosa_mel_basis") }

    private static func fail(_ text: String) -> NSError {
        VoiceJournal.line("AudioProcessor: \(text)")
        return NSError(domain: "AudioProcessor", code: -1,
                       userInfo: [NSLocalizedDescriptionKey: text])
    }
}
