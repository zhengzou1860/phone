import Foundation
import AVFoundation

/// WAV ↔ 16 kHz 单声道 ↔ 两条 mel 前端的取数入口。频谱本体在 MelFrontEnd.swift。
///
/// 采样的事：录音按设备原生格式落盘（iPhone 上通常是 48 kHz Float32），
/// 模型这一侧全都钉在 16 kHz，所以读数时统一走 AVAudioConverter 降到 16k 单声道。
enum AudioProcessor {

    /// 全链路采样率。DiT / Vocos / 两个 mel 前端都是这个口径，改这里等于换模型。
    static let sampleRate: Double = 16000

    /// 读任意 WAV/CAF → 16 kHz 单声道 Float32，值域 [-1,1]
    static func loadWAV16K(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
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
                                          frameCapacity: AVAudioFrameCount(file.length)) else {
            throw fail("输入 buffer 分配失败（\(file.length) 帧）")
        }
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
    static func saveWAV(_ samples: [Float], to url: URL, sampleRate: Double = 16000) throws {
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
