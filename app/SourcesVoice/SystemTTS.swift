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
        /// `frameLength == 0` 的 buffer：不是错误，是这一句吐完的收尾信号。
        var markers: Int = 0
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
            String(format: "TTS 探针 %d 句 / %d 个 buffer（收尾 marker %d 个%@）／原生 %.0f Hz %d 声道 %@ %@／首包 %.2f s／合成音频 %.2f s 用时 %.1f s（%.1f× 实时）／峰值 %.3f rms %.3f",
                   sentences, buffers, markers,
                   skipped > 0 ? "、另有 \(skipped) 个不是 PCM" : "",
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
        func bare(_ v: String) -> String { v.replacingOccurrences(of: "AVAudioSession", with: "") }
        return "\(bare(s.category.rawValue))/\(bare(s.mode.rawValue))/\(Int(s.sampleRate))Hz"
    }

    /// 这台机装了哪些中文语音。空表本身是有用读数（语音包没装或被 LiveContainer 挡住）。
    static func chineseVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
    }

    /// 界面上的一行嗓音。`gender` 是 iOS 13 就有的真 API（`.unspecified/.male/.female`），
    /// 拿来把男声排前面——「音高太低太尖」这件事最终是他耳朵定的，这里只负责把候选摊开。
    struct VoiceRow: Identifiable {
        let identifier: String
        let name: String
        let language: String
        let gender: String
        let quality: String
        var id: String { identifier }

        /// 尾段：`com.apple.voice.compact.zh-CN.Tingting` → `zh-CN.Tingting`。
        var tail: String {
            let p = identifier.split(separator: ".", omittingEmptySubsequences: true)
            return p.count >= 2 ? "\(p[p.count - 2]).\(p[p.count - 1])" : identifier
        }

        var label: String { "\(name)｜\(gender)｜\(quality)｜\(tail)" }
    }

    /// 这台机装了哪些中文语音，排好序给界面：zh-CN 在前，然后男声在前（要找「低一点」的先看这批）。
    static func voiceRows() -> [VoiceRow] {
        chineseVoices().map { v in
            let g: String
            switch v.gender {
            case .male: g = "男"
            case .female: g = "女"
            @unknown default: g = "未标"
            }
            return VoiceRow(identifier: v.identifier, name: v.name, language: v.language,
                            gender: g, quality: String(describing: v.quality))
        }
        .sorted { a, b in
            let aCN = a.language.hasPrefix("zh-CN"), bCN = b.language.hasPrefix("zh-CN")
            if aCN != bCN { return aCN }
            let aM = a.gender == "男", bM = b.gender == "男"
            if aM != bM { return aM }
            if a.name != b.name { return a.name < b.name }
            return a.identifier < b.identifier
        }
    }

    /// 优先用户选中的 identifier，其次 zh-CN，再次任何 zh，都没有就 nil（交给系统默认语音）。
    static func pickVoice(identifier: String? = nil) -> AVSpeechSynthesisVoice? {
        if let id = identifier, !id.isEmpty {
            // 这个 init 在有/无 Optional 两种 SDK 声明里都能编：接成可选就两头都不赌。
            let chosen: AVSpeechSynthesisVoice? = AVSpeechSynthesisVoice(identifier: id)
            if let chosen { return chosen }
            VoiceJournal.line("存的语音 \(id) 在这台机上取不回来（可能被系统换掉了）⇒ 退回默认选法")
        }
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
/// **0.1/20 手机上量到的**：`write` 的回调**确实异步吐 PCM**（首包 0.34–0.78 s，925 个有效 buffer），
/// 普通朗读也正常（`didStart 1／didFinish 1`）⇒ A0 这一格是通的。那一版死在两处自己的判据上：
/// - 静默收摊读的是**跨句累计**的 `report.buffers`：第二句一开局它就是真的，而 `lastArrival` 被我
///   重置成 `distantPast`，于是第一次 0.2 s 超时当场满足「静默 0.6 s」，0.7 s 就退出，第二句一个样本都没等；
/// - `stopSpeaking(.immediate)` **掐不掉已经在吐的离线生成**：第一句的尾巴还在往共享计数器里灌
///   （那 296 次「回调进来」就是这么来的），反过来也说明第一句在静默窗那里被截了尾。
/// 这一版：每句一个独立的 `Call`（身份比对，上一句迟到的尾巴直接丢弃、不污染新句）；收摊只看本句；
/// `frameLength == 0` 的 buffer 当「这一句吐完了」的强信号（0.1/20 的日志里它就成对出现在句尾），
/// 收到它之后再静默 `afterMarker` 秒就收；`idleClose` 只当兜底；成功路径上不再提前 stop。
final class TTSPump: NSObject, AVSpeechSynthesizerDelegate {

    /// 本句已有数据、且一直没等到收尾 marker 时，静默这么多秒才算吐完（兜底）。
    private static let idleClose = 0.9
    /// 收到 `frameLength == 0` 的 marker 之后，再静默这么多秒就收摊。
    /// 不敢取太小：万一它只是中途的一次冲刷，提前收摊会把这句的后半截全判成"迟到"丢掉。
    private static let afterMarker = 0.5

    /// 一句的私有状态。回调线程只认「我还是当前那句」才往里写。
    private final class Call {
        var got: [Float] = []
        var arrivals = 0
        var buffers = 0
        var empties = 0
        /// 见过 marker 且之前已有数据 ⇒ 这一句吐完了。
        var ended = false
        var lastArrival = Date.distantPast
        var firstAt = -1.0
        var nativeLine = ""
        var err: String?
    }

    private let synth = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var convInKey = ""
    private(set) var report = SystemTTS.Report()
    private var sumSq: Double = 0
    private var frames = 0

    /// 回调线程 → 等待线程：来一个 buffer 就 signal 一次。
    private let arrived = DispatchSemaphore(value: 0)
    /// 当前正在收的那一句；换句就整个换掉，旧句迟到的 buffer 因此在身份比对上落空。
    private var current: Call?
    /// 被丢弃的迟到 buffer 计数，只为报一次现象。
    private var lateDropped = 0
    /// 只走普通 `speak()` 的对照探针用；代理回调来自另一条线程。
    private var spStart = 0
    private var spFinish = 0
    private var spCancel = 0

    init(voice: AVSpeechSynthesisVoice?) {
        // 语音挂在 utterance 上就行：AVSpeechSynthesizer 自己没有 voice 这个属性（CI 编译器报的）。
        self.voice = voice
        super.init()
        synth.delegate = self
    }

    /// 念一句。等满硬上限仍一个样本都没有才抛错（A0 的判据；0.1/20 已经把它答成「通」了）。
    func speak(_ sentence: String) throws -> [Float] {
        let t0 = Date()
        report.sentences += 1
        let c = Call()
        bump { self.current = c }
        let utt = AVSpeechUtterance(string: sentence)
        utt.voice = voice
        synth.write(utt) { [weak self] buf in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            // 上一句的尾巴迟到：丢掉。让它写进新句的计数会把「这一句到底吐完没有」彻底读乱。
            guard self.current === c else {
                self.lateDropped += 1
                if self.lateDropped == 1 {
                    VoiceJournal.line("TTS 有 buffer 迟到（上一句的尾巴，`stopSpeaking` 掐不掉离线生成）⇒ 已丢弃")
                }
                return
            }
            c.arrivals += 1
            c.lastArrival = Date()
            self.arrived.signal()
            guard let pcm = buf as? AVAudioPCMBuffer else {
                c.err = "回调给的不是 AVAudioPCMBuffer 而是 \(String(describing: type(of: buf)))"
                self.report.skipped += 1
                return
            }
            if pcm.frameLength == 0 {
                // 不是错误：这是这一句吐完的信号（0.1/20 的日志里它出现在句尾）。
                c.empties += 1
                if c.buffers > 0 { c.ended = true }
                self.report.markers += 1
                return
            }
            let fmt = pcm.format
            if c.buffers == 0 {
                c.firstAt = Date().timeIntervalSince(t0)
                c.nativeLine = String(format: "%.0f Hz %d 声道 %@ %@", fmt.sampleRate, Int(fmt.channelCount),
                                     String(describing: fmt.commonFormat), fmt.isInterleaved ? "交错" : "非交错")
                VoiceJournal.line(String(format: "TTS 首包 %.2f s／原生 %@（句长 %d 字）",
                                         c.firstAt, c.nativeLine, sentence.count))
                if self.report.firstBuffer < 0 { self.report.firstBuffer = c.firstAt }
                if self.report.buffers == 0 {
                    self.report.nativeRate = fmt.sampleRate
                    self.report.nativeChannels = Int(fmt.channelCount)
                    self.report.nativeCommon = String(describing: fmt.commonFormat)
                    self.report.nativeInterleaved = fmt.isInterleaved
                }
            }
            let key = String(format: "%.0f/%d/%@/%d", fmt.sampleRate, Int(fmt.channelCount),
                            String(describing: fmt.commonFormat), fmt.isInterleaved ? 1 : 0)
            if self.converter == nil || self.convInKey != key {
                self.converter = AVAudioConverter(from: fmt, to: Self.out16K)
                self.convInKey = key
            }
            guard let conv = self.converter else {
                c.err = String(format: "转换器建不出来（%.0f Hz %d 声道）", fmt.sampleRate, Int(fmt.channelCount))
                self.report.skipped += 1
                return
            }
            do {
                c.got.append(contentsOf: try Self.floats(from: pcm, via: conv))
                c.buffers += 1
                self.report.buffers += 1
            } catch {
                c.err = error.localizedDescription
                self.report.skipped += 1
            }
        }
        // 收摊：只看本句。有数据 +（见过 marker 就再静默 afterMarker，否则静默 idleClose）。
        let est = max(1.0, Double(sentence.count) / 4.1)
        let hardCap = 20.0 + est * 6
        var waited = 0.0
        var closedClean = false
        while true {
            _ = arrived.wait(timeout: .now() + 0.2)
            let now = Date()
            waited = now.timeIntervalSince(t0)
            let s = bumpRead { (c.buffers, c.ended, c.lastArrival) }
            if s.0 > 0, now.timeIntervalSince(s.2) >= (s.1 ? Self.afterMarker : Self.idleClose) {
                closedClean = true
                break
            }
            if waited >= hardCap { break }
        }
        let snap = bumpRead { (c.arrivals, c.buffers, c.empties, c.got.count, c.err) }
        bump { self.current = nil }
        finish()
        if let err = snap.4 {
            VoiceJournal.line("TTS buffer 搬不进 16k：\(err)")
        }
        if snap.3 == 0 {
            let diag = probeSpeaking(sentence)
            throw SystemTTS.fail(String(format: "第 %d 句（%d 字）等满 %.1f s 仍 0 样本：回调进来 %d 次／有效 PCM %d 个／空 marker %d 个／干净收摊=%@；对照普通朗读：%@",
                                         report.sentences, sentence.count, waited, snap.0, snap.1, snap.2,
                                         closedClean ? "是" : "否", diag))
        }
        if !closedClean {
            VoiceJournal.line(String(format: "第 %d 句没等到收尾 marker，按静默窗收摊（%.1f s／%d 个 buffer／%d 样本）",
                                     report.sentences, waited, snap.1, snap.3))
        }
        // 统计和取值都在锁里做一次：`c.got` 是回调线程在锁里往上长的，锁外读它（含 return 那份拷贝）
        // 会和刚好已进身份比对、还持着锁的在途回调撞上。
        var samples: [Float] = []
        bump {
            samples = c.got
            for v in samples {
                let a = abs(v)
                if a > report.peak { report.peak = a }
                sumSq += Double(v) * Double(v)
            }
            frames += samples.count
            report.rms = Float(sqrt(sumSq / Double(max(frames, 1))))
            report.wall += Date().timeIntervalSince(t0)
            report.seconds += Double(samples.count) / SystemTTS.sampleRate
        }
        return samples
    }

    /// 对照探针：普通 `speak()`（走扬声器那条）起不起得来。
    ///
    /// 这一格是为了把两件事分开——「语音引擎在 LiveContainer 里根本起不来」和
    /// 「只有 `write` 这条离线生成路不通」。前者 speak 也没有回调，后者 speak 正常。
    /// 固定 `volume = 0` 静音跑，只回答引擎活不活；外放与否不归它管，别把诊断做成噪音。
    private func probeSpeaking(_ sentence: String) -> String {
        bump {
            self.spStart = 0
            self.spFinish = 0
            self.spCancel = 0
        }
        let utt = AVSpeechUtterance(string: sentence)
        utt.voice = voice
        // 必须静音：这条探针 0.1/20 是全音量跑的，他在手机上听到的
        // 「只播了最后一句、还是系统原音」就是它，而不是任何转换结果。
        utt.volume = 0
        VoiceJournal.line("诊断：静音朗读一次（不外放），看引擎起不起得来")
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
                // 不是 endOfStream：`write` 的回调是一串小块，每块都宣告流结束就等于
                // 每个边界把重采样器的历史冲一次、周期性啃掉尾巴。宣告"暂时没料"，
                // 让它把现在能产的产出来、状态留给下一个 buffer（同一个 converter 实例跨 buffer 复用）。
                outStatus.pointee = .noDataNow
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

/// 「试听」：把选中的嗓音外放念一句，不跑链、不落盘。
///
/// 存在的理由：音高高低、温柔不温柔是他耳朵定的，而一整章要跑几十分钟 ⇒
/// 挑嗓音必须能在几十秒内反复比，不能每换一个都点一次「读给我听」。
/// `speak()` 那条外放路真机确认过（didStart 1／didFinish 1），所以这里不需要兜底。
///
/// 自带一个 `AVSpeechSynthesizer`，和 TTSPump 那个隔开：试听不许污染正式朗读的计数。
final class Audition {
    static let shared = Audition()
    static let sampleLine = "他慢慢转过身去，窗外那条巷子还亮着最后一点灯。"

    private let synth = AVSpeechSynthesizer()

    func play(identifier: String?) {
        let voice = SystemTTS.pickVoice(identifier: identifier)
        synth.stopSpeaking(at: .immediate)
        let utt = AVSpeechUtterance(string: Self.sampleLine)
        utt.voice = voice
        VoiceJournal.line("试听：\(voice?.identifier ?? "系统默认语音")")
        synth.speak(utt)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }
}

