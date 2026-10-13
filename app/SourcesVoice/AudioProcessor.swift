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
    /// 48 kHz 立体声每秒 0.384 MB ⇒ 1 分钟 23 MB、30 分钟 691 MB、1 小时 1.38 GB。
    /// iPhone 11 前台水位线约 2040 MB（真机实测 ① 在 40.6 s 参考上顶到 1749 MB），
    /// 到那一格不是报错而是被系统杀掉，连日志都带不走 ⇒ 开读之前先按文件头算账，超线就拒。
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

    /// 流式写 16 kHz 单声道 **int16** WAV：一片进来落一片，整章不在内存里攒。
    ///
    /// 替掉 `saveWAV` 那条路的理由有两条，都是读小说逼出来的：
    /// ① 原来原声＋转换后两条 float 数组要揣到读完（30 分钟 = 2×115 MB），所以开跑前
    ///    有一道 30 分钟的内存闸门；流式之后常驻只有当前一片（≤120 s ≈ 7.7 MB）。
    /// ② 守卫原来在整章末尾按**全章**长峰乘一个线性增益 ⇒ 某一片过冲会把整章一起压小。
    ///    这里改成每片自己算峰值、自己压回，片与片之间互不牵连。
    /// int16 顺带把磁盘也省一半（32 KB/秒，30 分钟 58 MB）。
    static let writerRate: Double = 16000

    final class WAVWriter {
        private let url: URL
        private var handle: FileHandle?
        private(set) var frames = 0
        /// 各片里最大的那个原始峰值，只进日志，不参与增益计算。
        private(set) var maxPeak: Float = 0

        init(url: URL) throws {
            self.url = url
            FileManager.default.createFile(atPath: url.path, contents: Self.header(dataBytes: 0))
            guard let handle = FileHandle(forWritingAtPath: url.path) else {
                throw AudioProcessor.fail("打不开写盘句柄（\(url.lastPathComponent)）")
            }
            handle.seekToEndOfFile()
            self.handle = handle
        }

        /// 小端 4 字节／2 字节。WAV 头的两个长度字段和整份采样数据都走这两个口。
        private static func u32(_ v: UInt32) -> Data {
            var out = Data()
            withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
            return out
        }
        private static func u16(_ v: UInt16) -> Data {
            var out = Data()
            withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
            return out
        }

        /// 标准 44 字节 PCM 头。两个长度字段先填 0，`finish()` 回填——所以 finish 必须调到，
        /// 没回填的文件播放器读出来是 0 秒。
        private static func header(dataBytes: UInt32) -> Data {
            var d = Data(capacity: 44)
            func put(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
            func u32(_ v: UInt32) { d.append(contentsOf: Self.u32(v)) }
            func u16(_ v: UInt16) { d.append(contentsOf: Self.u16(v)) }
            put("RIFF"); u32(36 + dataBytes); put("WAVE")
            put("fmt "); u32(16)
            u16(1)                                  // 1 = 未压缩 PCM
            u16(1)                                  // 单声道
            u32(UInt32(AudioProcessor.writerRate))
            u32(UInt32(AudioProcessor.writerRate) * 2)   // 字节率 = 采样率 × 2 字节
            u16(2)                                  // 块对齐
            u16(16)                                 // 位深
            put("data"); u32(dataBytes)
            return d
        }

        /// 落一片。峰值过满刻度就按**这片自己**的长峰压回，不动别的片。
        func append(_ samples: [Float]) throws {
            guard let handle = handle else { throw AudioProcessor.fail("WAVWriter 已经收尾了，不能再写") }
            guard !samples.isEmpty else { return }
            var peak: Float = 0
            for v in samples {
                let a = abs(v)
                if a > peak { peak = a }
            }
            if peak > maxPeak { maxPeak = peak }
            let gain: Float = peak > 1.0 ? 0.999 / peak : 1.0
            if gain < 1.0 {
                VoiceJournal.line(String(format: "%@：本片峰值 %.4f 越过满刻度 ⇒ 乘 %.4f 压回",
                                         url.lastPathComponent, peak, gain))
            }
            VoiceJournal.line(String(format: "准备落盘 %@：本片 %d 帧", url.lastPathComponent, samples.count))
            var ints = [Int16](repeating: 0, count: samples.count)
            for i in 0..<samples.count {
                var v = samples[i] * gain
                if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
                ints[i] = Int16(v * 32767.0)
            }
            ints.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                handle.write(Data(bytes: base, count: raw.count))
            }
            frames += samples.count
        }

        /// `seek(toOffset:)` 在 iOS 13.4 之后的 SDK 上是 throws 的（CI 就是这么炸的）。
        /// 回填失败 ⇒ 头里两个长度字段还是 0 ⇒ 播放器读出来 0 秒，所以这个错要传出去，不能吞。
        func finish() throws {
            guard let handle = handle else { return }
            self.handle = nil
            let bytes = UInt32(frames * 2)
            try handle.seek(toOffset: 4)
            handle.write(Self.u32(36 + bytes))
            try handle.seek(toOffset: 40)
            handle.write(Self.u32(bytes))
            handle.closeFile()
            VoiceJournal.line(String(format: "%@ 收尾：%.1f s 音频／%d 字节",
                                     url.lastPathComponent, Double(frames) / AudioProcessor.writerRate,
                                     frames * 2 + 44))
        }
    }

    /// 一阶差分的能量占比 `sqrt(Σ(x[n]−x[n−1])² / Σx[n]²)`。按 Parseval 它就是
    /// `sqrt(mean(4·sin²(πf/2SR)))` —— 一个不用 FFT 的频谱重心代理，齿音和塞擦全算在这一格。
    /// 「吐字不清」在这把尺上就是数字往下走。每 `windowSecs` 一格，逐格报出来才能看是不是**越往后越低**。
    static func claritySeries(_ x: [Float], windowSecs: Double = 30.0) -> [String] {
        let L = Int(windowSecs * sampleRate)
        guard L > 64, x.count >= L else { return [] }
        var out: [String] = []
        var i = 0
        while i + L <= x.count {
            var se = 0.0, sd = 0.0
            var prev = Double(x[i])
            var k = i
            while k < i + L {
                let v = Double(x[k])
                se += v * v
                let d = v - prev
                sd += d * d
                prev = v
                k += 1
            }
            out.append(se > 0 ? String(format: "%.3f", (sd / se).squareRoot()) : "—")
            i += L
        }
        return out
    }

    /// 逐格数字拼成一格话，末尾补上「一共几格／不足一格的尾巴不算」，免得他把 4 格当成 4 片。
    static func clarityText(_ x: [Float], windowSecs: Double = 30.0) -> String {
        let s = claritySeries(x, windowSecs: windowSecs)
        guard !s.isEmpty else { return "不足 \(Int(windowSecs)) s，没格" }
        return s.joined(separator: " ") + "（每 \(Int(windowSecs)) s 一格，共 \(s.count) 格）"
    }

    /// kaldi 那一侧的定标：训练时 fbank 吃的是乘过 1<<15 的整数域样本
    static func scaled(_ norm: [Float]) -> [Float] {
        norm.map { $0 * 32768.0 }
    }

    /// librosa 的 mel 基（80×513 行主序）。训练侧前端的常量，随包发数据、不在 Swift 里重抄公式。
    static func melBasis() -> [Float]? { MelFrontEnd.loadFloats("librosa_mel_basis") }

    /// 给 `WAVWriter` 也用，所以不写 private（嵌套类型拿外层 private 是编译一轮才见分晓的那种坑）。
    static func fail(_ text: String) -> NSError {
        VoiceJournal.line("AudioProcessor: \(text)")
        return NSError(domain: "AudioProcessor", code: -1,
                       userInfo: [NSLocalizedDescriptionKey: text])
    }
}
