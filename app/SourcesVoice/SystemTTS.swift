import Foundation
import AVFoundation

/// iOS 自带 `AVSpeechSynthesizer` → 16 kHz 单声道 float。新增模型 0 MB。
///
/// A0 那一格（这个 API 在 LiveContainer 里到底吐不吐得出 PCM）就靠这一段判，
/// 所以每个读数都记下来：句子数、buffer 个数、原生采样率/声道/位深/交错、总时长、峰值、rms、墙钟。
/// **一个 buffer 都没来就直接报错，不回一段静音**——静音和失败在这把尺上必须是两件事。
///
/// `write(_:toBufferCallback:)` 的 iOS 门是 13.0（DocC symbol 页 introducedAt=13.0），
/// 回调形参写的是 `AVAudioBuffer` 而不是 `AVAudioPCMBuffer`，所以进去先 `as?` 一次。
/// 这条路不占播放会话，不动 AVAudioSession。
enum SystemTTS {

    /// 和整条链一个口径：16 kHz 单声道。
    static let sampleRate: Double = 16000

    /// 一次 `write` 最多念这么多字。超长句会把整段音频攒在内存里，中间也没法报进度。
    static let maxSentenceChars = 60
    /// 攒到这么长还碰不到标点才允许在 `，、：` 处断（硬切在字中间会听出来，但总比卡住好）。
    static let softBreakChars = 24

    struct Report {
        var sentences: Int = 0
        var buffers: Int = 0
        var skipped: Int = 0
        var nativeRate: Double = 0
        var nativeChannels: Int = 0
        var nativeCommon = "-"
        var nativeInterleaved = false
        var seconds: Double = 0
        var peak: Float = 0
        var rms: Float = 0
        var wall: Double = 0

        /// 发回电脑的那一行探针读数。
        var line: String {
            String(format: "TTS 探针 %d 句 / %d 个 buffer%@／原生 %.0f Hz %d 声道 %@ %@／合成音频 %.2f s 用时 %.1f s（%.1f× 实时）／峰值 %.3f rms %.3f",
                   sentences, buffers,
                   skipped > 0 ? "（另有 \(skipped) 个不是 PCM）" : "",
                   nativeRate, nativeChannels, nativeCommon,
                   nativeInterleaved ? "交错" : "非交错",
                   seconds, wall,
                   wall > 0.001 ? seconds / wall : 0,
                   peak, rms)
        }
    }

    /// 这台机装了哪些中文语音。空表本身是有用读数（语音包没装或被 LiveContainer 挡住）。
    static func chineseVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
    }

    /// 优先 zh-CN，其次任何 zh，都没有就 nil（交给系统默认语音）。
    static func pickVoice() -> AVSpeechSynthesisVoice? {
        let zh = chineseVoices()
        return zh.first { $0.language == "zh-CN" } ?? zh.first
    }

    /// 中文句读切句：`。！？；…` 和换行是硬边界；`，、：` 只在已攒够 24 字时才算边界；
    /// 满 60 字还没标点就硬切。
    static func sentences(from text: String) -> [String] {
        let hard: Set<Character> = ["。", "！", "？", "；", "…", "\n", "!", "?", ";"]
        let soft: Set<Character> = ["，", "、", "：", ","]
        var out: [String] = []
        var cur = ""
        for ch in text {
            if ch == "\r" { continue }
            if ch.isWhitespace && cur.isEmpty { continue }
            cur.append(ch)
            if hard.contains(ch) || (soft.contains(ch) && cur.count >= softBreakChars) || cur.count >= maxSentenceChars {
                emit(&out, cur)
                cur = ""
            }
        }
        emit(&out, cur)
        return out
    }

    private static func emit(_ out: inout [String], _ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { out.append(s) }
    }

    static func fail(_ text: String) -> NSError {
        VoiceJournal.line("SystemTTS: \(text)")
        return NSError(domain: "SystemTTS", code: -1,
                       userInfo: [NSLocalizedDescriptionKey: text])
    }
}

/// 一句一句念的泵：`speak(一句)` 返回这一句的 16 kHz 单声道 float。
///
/// 按句吐数是为了让「读小说」那条管路能在攒够一片之后就进链子，不必把整章音频先摊在内存里。
/// 计数器（`report`）跨句累加，最后那一行探针读数就取它。
final class TTSPump {
    private let synth = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var convInKey = ""
    private(set) var report = SystemTTS.Report()
    private var sumSq: Double = 0
    private var frames = 0

    init(voice: AVSpeechSynthesisVoice?) {
        self.voice = voice
        synth.voice = voice
    }

    /// 念一句。回调一次都没来就抛错（A0 的判据就是这一条）。
    func speak(_ sentence: String) throws -> [Float] {
        let t0 = Date()
        report.sentences += 1
        var got: [Float] = []
        let utt = AVSpeechUtterance(string: sentence)
        utt.voice = voice
        var err: String?
        synth.write(utt) { [weak self] buf in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let pcm = buf as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                self.report.skipped += 1
                return
            }
            let fmt = pcm.format
            if self.report.buffers == 0 {
                self.report.nativeRate = fmt.sampleRate
                self.report.nativeChannels = Int(fmt.channelCount)
                self.report.nativeCommon = String(describing: fmt.commonFormat)
                self.report.nativeInterleaved = fmt.interleaved
            }
            let key = String(format: "%.0f/%d/%@/%d", fmt.sampleRate, Int(fmt.channelCount),
                            String(describing: fmt.commonFormat), fmt.interleaved ? 1 : 0)
            if self.converter == nil || self.convInKey != key {
                self.converter = AVAudioConverter(from: fmt, to: Self.out16K)
                self.convInKey = key
            }
            guard let conv = self.converter else {
                self.report.skipped += 1
                VoiceJournal.line(String(format: "TTS buffer 转不成 16k：转换器建不出来（%.0f Hz %d 声道）",
                                         fmt.sampleRate, Int(fmt.channelCount)))
                return
            }
            do {
                got.append(contentsOf: try Self.floats(from: pcm, via: conv))
                self.report.buffers += 1
            } catch {
                self.report.skipped += 1
                err = error.localizedDescription
            }
        }
        // write 到底同步不同步 Apple 没写死：它若还挂着这条朗读就等它吐完（上限 30 s/句）。
        var waited = 0.0
        while synth.isSpeaking, waited < 30 {
            Thread.sleep(forTimeInterval: 0.02)
            waited += 0.02
        }
        if let err = err {
            VoiceJournal.line("TTS buffer 搬不进 16k：\(err)")
        }
        // 第一句一个 buffer 都没落进这一句 = 这条路根本没通（或者 write 是异步的、
        // buffer 落在我们返回之后的那个数组副本上）。两种都要当场炸出来，别往下攒静音。
        if got.isEmpty {
            finish()
            throw SystemTTS.fail("第 \(report.sentences) 句 write 之后拿到 0 个样本（累计 \(report.buffers) 个 buffer、\(report.skipped) 个不是 PCM）⇒ 要么这条路不通，要么回调是异步的")
        }
        for v in got {
            let a = abs(v)
            if a > report.peak { report.peak = a }
            sumSq += Double(v) * Double(v)
        }
        frames += got.count
        report.rms = Float(sqrt(sumSq / Double(max(frames, 1))))
        report.wall += Date().timeIntervalSince(t0)
        report.seconds += Double(got.count) / SystemTTS.sampleRate
        return got
    }

    /// 收摊：把可能还挂着的朗读停掉。
    func finish() {
        synth.stopSpeaking(at: .immediate)
    }

    private static let out16K = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: SystemTTS.sampleRate,
                                              channels: 1,
                                              interleaved: false)!

    /// 原生格式和 16k 完全一致就直接搬，否则过给定的 AVAudioConverter（和 AudioProcessor 那趟同一写法）。
    private static func floats(from b: AVAudioPCMBuffer, via conv: AVAudioConverter) throws -> [Float] {
        let fmt = b.format
        let n = Int(b.frameLength)
        if abs(fmt.sampleRate - SystemTTS.sampleRate) < 1, fmt.channelCount == 1,
           fmt.commonFormat == .pcmFormatFloat32, !fmt.interleaved,
           let p = b.floatChannelData {
            return Array(UnsafeBufferPointer(start: p[0], count: n))
        }
        let ratio = SystemTTS.sampleRate / max(fmt.sampleRate, 1)
        guard let dst = AVAudioPCMBuffer(pcmFormat: out16K,
                                         frameCapacity: AVAudioFrameCount(Double(n) * ratio) + 1024) else {
            throw SystemTTS.fail("输出 buffer 分配失败（\(n) 帧）")
        }
        var fed = false
        var error: NSError?
        let status = conv.convert(to: dst, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            fed = true
            return b
        }
        if let error = error { throw error }
        guard status != .error else { throw SystemTTS.fail("转换返回 .error（输入 \(n) 帧）") }
        guard let p = dst.floatChannelData?[0] else { throw SystemTTS.fail("转换结果拿不到 floatChannelData") }
        return Array(UnsafeBufferPointer(start: p, count: Int(dst.frameLength)))
    }
}
