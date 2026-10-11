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
        /// 第一句从 `write` 到首个 buffer 落地的延迟。-1 表示一次都没来（和「来了但很小」是两件事）。
        var firstBuffer: Double = -1

        /// 发回电脑的那一行探针读数。
        var line: String {
            String(format: "TTS 探针 %d 句 / %d 个 buffer%@／原生 %.0f Hz %d 声道 %@ %@／首包 %.2f s／合成音频 %.2f s 用时 %.1f s（%.1f× 实时）／峰值 %.3f rms %.3f",
                   sentences, buffers,
                   skipped > 0 ? "（另有 \(skipped) 个不是 PCM）" : "",
                   nativeRate, nativeChannels, nativeCommon,
                   nativeInterleaved ? "交错" : "非交错",
                   firstBuffer,
                   seconds, wall,
                   wall > 0.001 ? seconds / wall : 0,
                   peak, rms)
        }
    }

    /// 现场读数：当前音频会话。`write` 这条路若被会话状态挡住，这一行能看出来。
    static func sessionLine() -> String {
        let s = AVAudioSession.sharedInstance()
        return "\(s.category)/\(s.mode)/\(Int(s.sampleRate))Hz"
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
///
/// **0.1/19 那一版的等法是错的**：它按 `synth.isSpeaking` 排空，而 `isSpeaking` 对 `write` 这种
/// 不落扬声器的离线生成不成立，于是循环一次都没转就退出，紧接着 `stopSpeaking(.immediate)`
/// 把刚起步的生成掐死——手机报回来的「0 个 buffer」是这一手造成的假阴性，不能当 A0 的判据。
/// 这一版按「回调来一次 signal 一次」等：拿到过 buffer 且连续 `idleClose` 秒没有新的来才算吐完，
/// 一个都没来就等满 `hardCap`（按句长估）为止；等满了才抛错，抛之前再拿普通朗读对照一次。
final class TTSPump: NSObject, AVSpeechSynthesizerDelegate {

    /// 已经有过 buffer 之后，静默这么多秒就认为这一句吐完了（`BufferCallback` 没有结束标志位）。
    private static let idleClose = 0.6

    private let synth = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var convInKey = ""
    private(set) var report = SystemTTS.Report()
    private var sumSq: Double = 0
    private var frames = 0

    /// 回调线程 → 等待线程：来一个 buffer 就 +1 并 signal。
    private let arrived = DispatchSemaphore(value: 0)
    private var arrivals = 0
    private var lastArrival = Date.distantPast
    /// 只走普通 `speak()` 的对照探针用；代理回调来自另一条线程。
    private var spStart = 0
    private var spFinish = 0
    private var spCancel = 0
    /// 不是 PCM 的 buffer 只报第一个的类名，够定性了。
    private var skippedType = ""

    init(voice: AVSpeechSynthesisVoice?) {
        // 语音挂在 utterance 上就行：AVSpeechSynthesizer 自己没有 voice 这个属性（CI 编译器报的）。
        self.voice = voice
        super.init()
        synth.delegate = self
    }

    /// 念一句。等满还是没有 buffer 就抛错（A0 的判据就是这一条）。
    func speak(_ sentence: String) throws -> [Float] {
        let t0 = Date()
        report.sentences += 1
        var got: [Float] = []
        let utt = AVSpeechUtterance(string: sentence)
        utt.voice = voice
        var err: String?
        bump {
            self.arrivals = 0
            self.lastArrival = Date.distantPast
        }
        synth.write(utt) { [weak self] buf in
            guard let self = self else { return }
            self.lock.lock()
            self.arrivals += 1
            self.lastArrival = Date()
            self.lock.unlock()
            self.arrived.signal()
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let pcm = buf as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                self.report.skipped += 1
                if self.skippedType.isEmpty {
                    self.skippedType = String(describing: type(of: buf))
                    VoiceJournal.line("TTS 回调给的不是 PCM buffer：\(self.skippedType)")
                }
                return
            }
            let fmt = pcm.format
            if self.report.buffers == 0 {
                self.report.nativeRate = fmt.sampleRate
                self.report.nativeChannels = Int(fmt.channelCount)
                self.report.nativeCommon = String(describing: fmt.commonFormat)
                self.report.nativeInterleaved = fmt.isInterleaved
            }
            let key = String(format: "%.0f/%d/%@/%d", fmt.sampleRate, Int(fmt.channelCount),
                            String(describing: fmt.commonFormat), fmt.isInterleaved ? 1 : 0)
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
        // 结束的两种判据：吐过东西且静默够久；或等满硬上限。
        // `report`/`lastArrival` 是回调线程在锁里写的，这边读也必须走同一把锁。
        let est = max(1.0, Double(sentence.count) / 4.1)
        let hardCap = 20.0 + est * 4
        var waited = Date().timeIntervalSince(t0)
        while waited < hardCap {
            let r = arrived.wait(timeout: .now() + 0.2)
            let now = Date()
            waited = now.timeIntervalSince(t0)
            if r == .success {
                if report.firstBuffer < 0 {
                    report.firstBuffer = waited
                    VoiceJournal.line(String(format: "TTS 首包 %.2f s（句长 %d 字）", waited, sentence.count))
                }
            } else {
                let s = bumpRead { (self.report.buffers, self.lastArrival) }
                if s.0 > 0, now.timeIntervalSince(s.1) >= Self.idleClose { break }
            }
        }
        finish()
        if let err = err {
            VoiceJournal.line("TTS buffer 搬不进 16k：\(err)")
        }
        if got.isEmpty {
            let snap = bumpRead { (self.arrivals, self.report.buffers, self.report.skipped, self.skippedType) }
            let diag = probeSpeaking(sentence)
            throw SystemTTS.fail(String(format: "第 %d 句 write 等满 %.1f s：回调进来 %d 次／其中 PCM %d 个／被跳过 %d 个（%@）；对照普通朗读：%@",
                                         report.sentences, waited, snap.0, snap.1, snap.2,
                                         snap.3.isEmpty ? "-" : "首个非 PCM 是 \(snap.3)", diag))
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

    /// 对照探针：普通 `speak()`（走扬声器那条）起不起得来。
    ///
    /// 这一格是为了把两件事分开——「语音引擎在 LiveContainer 里根本起不来」和
    /// 「只有 `write` 这条离线生成路不通」。前者 speak 也没有回调，后者 speak 正常。
    /// 只报计数，不下结论：回调到了但他耳朵没听见是另一回事（会话/路由），那要他自己报。
    private func probeSpeaking(_ sentence: String) -> String {
        bump {
            self.spStart = 0
            self.spFinish = 0
            self.spCancel = 0
        }
        let utt = AVSpeechUtterance(string: sentence)
        utt.voice = voice
        synth.speak(utt)
        let est = max(1.0, Double(sentence.count) / 4.1)
        let t0 = Date()
        var sawSpeaking = false
        while Date().timeIntervalSince(t0) < est + 8 {
            if synth.isSpeaking { sawSpeaking = true }
            let done = bumpRead { self.spFinish + self.spCancel }
            if done > 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        finish()
        let r = bumpRead { (self.spStart, self.spFinish, self.spCancel) }
        return String(format: "isSpeaking %@／didStart %d／didFinish %d／didCancel %d／会话 %@，等了 %.1f s",
                      sawSpeaking ? "见到过" : "全程为否", r.0, r.1, r.2,
                      SystemTTS.sessionLine(), Date().timeIntervalSince(t0))
    }

    private func bump(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        body()
    }

    private func bumpRead<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// 收摊：把可能还挂着的朗读停掉。只在等完之后调用——早一步就会掐死正在进行的生成。
    func finish() {
        synth.stopSpeaking(at: .immediate)
    }

    // MARK: - AVSpeechSynthesizerDelegate（对照探针的计数）
    // 只声明 iOS 上确实有的那三个；willSpeak 是 macOS 的，写进来会当场编译失败。

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        bump { self.spStart += 1 }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        bump { self.spFinish += 1 }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        bump { self.spCancel += 1 }
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
           fmt.commonFormat == .pcmFormatFloat32, !fmt.isInterleaved,
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
