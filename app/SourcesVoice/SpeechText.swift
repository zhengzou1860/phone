import Foundation
import Speech
import AVFoundation

/// 「提取视频中人物的话」：用系统自带的**本机听写**把音轨变成可编辑的文字。
///
/// 为什么是这一条路而不是下一个 ASR 模型：这个 app 的硬门是包体 —— 效果能看的中文识别模型
/// 几十 MB 起、好的上 GB，直接否。听写包在系统里，一个字节都不进 IPA。
/// 精度也不是这条要的：他要的是"把台词拿出来改成想说的"，改的过程本身就在人眼底下过一遍。
///
/// 两头真机上还没验过的，代码里都留了读数，不靠猜：
/// 1. **权限归谁**：装机只进 LiveContainer，`requestAuthorization` 那句弹窗归宿主 plist 管。
///    所以状态枚举原样落日志，被拒时界面上直接写去哪儿开（设置 → 隐私与安全性 → 语音识别）。
/// 2. **喂快了掉字**：听写是流式 API（一边喂一边认），把 5 分钟音频一秒钟全灌进去它会丢。
///    这里按 `feedPace` 倍实时喂，并且把「认出的字数／素材秒数／每窗状态」落日志 ——
///    掉没掉字看那几行就知道，不用回头猜是哪一段。
enum SpeechText {

    /// 一次识别请求最多吃这么多秒。听写请求跑久了准确率会往下掉，也有内部时限，
    /// 所以按窗分段；每窗自己的字数单独记一行。
    static let windowSecs = 50.0

    /// 相对实时的喂数倍率。1.0 最稳但太慢（5 分钟素材要等 5 分钟），
    /// 往上一档掉字的风险就归到上面那条读数里。
    static let feedPace = 1.5

    /// 每次喂进请求的那一块有多长（100 ms，和 `AVAudioEngine` 的输入块同一量级）。
    static let bufferSecs = 0.1

    /// 说完 `endAudio()` 之后最多再等这么久收尾；等不到就用最后那一版部分结果。
    /// 12 s 是照着"正常收尾 1~3 s"放宽的：这一条是**每窗**都要等的，画长了整趟就跟着长
    /// （15 分钟素材 = 18 窗，每窗多等 10 s 就是多 3 分钟）。
    static let graceSecs = 12.0

    /// 认出来的一段：在源时间轴上的起点 + 文本。
    struct Segment {
        var startSecs: Double
        var text: String
    }

    struct Result {
        var segments: [Segment]
        var sourceSecs: Double
        var chars: Int
        var wallSeconds: Double
        var localeID: String
        /// 这一趟真走的本机识别（`supportsOnDeviceRecognition` 那条）。false = 落到了需要网络的那头，
        /// 装机时这一行就是证据：手机在飞行模式下能不能提台词，全看这个数。
        var onDevice: Bool
        /// 每窗：窗长 / 认出的字数 / 那一窗的判决（超时、被拒、没认出来都写在这儿）
        var windows: [(secs: Double, chars: Int, note: String)]

        /// 拼成能编辑的一份稿子：一窗一行（≈50 s 说的话），行间不插空行。
        var text: String {
            segments.map { $0.text }.joined(separator: "\n")
        }

        var line: String {
            let perWin = windows.map { w -> String in
                String(format: "%.0fs:%d字%@", w.secs, w.chars, w.note.isEmpty ? "" : "（\(w.note)）")
            }.joined(separator: " ")
            // 那一串每窗的话里可能有 `%`（系统的报错原文什么都可能写），所以它**不能**进 format 的
            // 格式串 ⇒ 用 + 拼。混进 `String(format:)` 的裸 `%` 是当场崩，不是显示乱码。
            let head = String(format: "提台词：源 %.1f s ⇒ %d 窗／%d 字／墙钟 %.0f s（%@，%@）｜",
                              sourceSecs, windows.count, chars, wallSeconds, localeID,
                              onDevice ? "本机" : "需网络")
            return head + perWin
        }
    }

    /// 能试的语言顺序：普通话优先，其次系统当前语言。
    static let localeCandidates = ["zh-CN", "zh_CN", "zh-Hans-CN"]

    /// 主入口。`samples` 是 16 kHz 单声道 [-1,1]（`VideoClip.extractAudio` 那个口径，一个字都不用换）。
    ///
    /// 不在主线程上跑：调用方在 `Task` 里 await 它，里面每块 100 ms 用 `Task.sleep` 卡节奏，
    /// 既不占线程也不卡界面。
    static func transcribe(samples: [Float],
                           onStage: (String) -> Void = { _ in }) async throws -> Result {
        let sr = AudioProcessor.sampleRate
        let total = Double(samples.count) / sr
        guard samples.count > 0 else { throw ChainError.input("这条素材解出来是空的（0 秒），没什么可提") }
        let t0 = Date()

        // 1) 权限。已经授过就不重复弹（`authorizationStatus` 是同步的那一份）。
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { st in c.resume(returning: st) }
            }
        }
        VoiceJournal.line("语音识别授权状态 = \(authText(status))")
        switch status {
        case .denied, .restricted:
            throw ChainError.input("系统不给语音识别权限（\(authText(status))）⇒ 去 设置 → 隐私与安全性 → 语音识别 里打开；"
                                   + "装机在 LiveContainer 里时，这一条归宿主那份权限管")
        case .notDetermined:
            throw ChainError.input("语音识别权限没答上来（弹窗没出现／没点）⇒ 再点一次「提取台词」")
        default:
            break
        }

        // 2) 挑一把可用的尺。`isAvailable` 假多半是本机听写包没装／正在下载。
        var rec: SFSpeechRecognizer?
        var used = ""
        for id in localeCandidates {
            let r = SFSpeechRecognizer(locale: Locale(identifier: id))
            if let r = r, r.isAvailable { rec = r; used = id; break }
        }
        if rec == nil, let r = SFSpeechRecognizer(), r.isAvailable {
            rec = r
            used = r.locale.identifier
        }
        guard let recognizer = rec else {
            let tried = localeCandidates.joined(separator: "、")
            let sup = SFSpeechRecognizer.supportedLocales().prefix(12)
                .map { $0.identifier }.joined(separator: "、")
            throw ChainError.input("这台机的听写现在不可用（试过 \(tried)）。本机支持的口音：\(sup)｜"
                                   + "中文听写包没装／还在下载也长这样：设置 → 通用 → 键盘 → 听写 里打开")
        }
        let onDevice = recognizer.supportsOnDeviceRecognition
        VoiceJournal.line(String(format: "提台词开跑：源 %.1f s／语言 %@／本机识别 %@／喂数 %.2f× 实时",
                                 total, recognizer.locale.identifier,
                                 onDevice ? "支持" : "不支持（要联网）", feedPace))

        let win = Int((windowSecs * sr).rounded())
        let nWin = (samples.count + win - 1) / max(win, 1)
        var segs: [Segment] = []
        var rows: [(secs: Double, chars: Int, note: String)] = []
        var chars = 0

        for w in 0..<nWin {
            let from = w * win
            let to = min(samples.count, from + win)
            let secs = Double(to - from) / sr
            onStage(String(format: "提取台词：第 %d/%d 段（%.0f~%.0f s，按 %.1f× 实时喂，要等一会儿）",
                           w + 1, nWin, Double(from) / sr, Double(to) / sr, feedPace))
            let one = try await oneWindow(recognizer: recognizer, samples: samples, from: from, to: to,
                                          onDevice: onDevice)
            segs.append(contentsOf: one.segments)
            chars += one.chars
            rows.append((secs, one.chars, one.note))
            VoiceJournal.line(String(format: "提台词第 %d/%d 窗（%.0f s）：认出 %d 字｜%@",
                                     w + 1, nWin, secs, one.chars, one.note))
        }
        let bad = rows.filter { !$0.note.isEmpty }.count
        let note = bad == 0 ? "" : "｜有 \(bad) 窗留了话（超时／没认出来），那几段的字可能缺"
        VoiceJournal.line(Result(segments: segs, sourceSecs: total, chars: chars,
                                 wallSeconds: Date().timeIntervalSince(t0),
                                 localeID: used, onDevice: onDevice, windows: rows).line + note)
        return Result(segments: segs, sourceSecs: total, chars: chars,
                      wallSeconds: Date().timeIntervalSince(t0), localeID: used,
                      onDevice: onDevice, windows: rows)
    }

    // MARK: - 一窗

    /// 一窗：建请求 → 按节奏喂 → `endAudio()` → 等收尾。返回这一窗认出来的行（带源时间轴的起点）。
    private static func oneWindow(recognizer: SFSpeechRecognizer, samples: [Float],
                                  from: Int, to: Int, onDevice: Bool) async throws
        -> (segments: [Segment], chars: Int, note: String) {
        let sr = AudioProcessor.sampleRate
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true       // 收尾等不到 final 时，部分结果就是那一窗的全部内容
        req.requiresOnDeviceRecognition = onDevice  // 不支持本机时这条根本不会被置上
        req.taskHint = .dictation

        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                      channels: 1, interleaved: false) else {
            throw ChainError.input("16k 单声道 float32 的格式建不出来（听写要的口径就是这个）")
        }

        // 回调在系统的队列上，和这儿的 await 两头同时读写 ⇒ 收数的那一份自带一把锁（`WindowBox`）。
        let box = WindowBox()
        let task = recognizer.recognitionTask(with: req) { res, err in
            if let res = res {
                let text = res.bestTranscription.formattedString
                let pieces = res.bestTranscription.segments.map {
                    Segment(startSecs: Double($0.timestamp), text: $0.substring)
                }
                box.put(text: text, pieces: pieces, isFinal: res.isFinal)
            } else if let err = err {
                box.fail(err.localizedDescription)
            }
        }

        let per = max(1, Int((bufferSecs * sr).rounded()))
        var off = from
        let fedT0 = Date()
        while off < to {
            let n = min(per, to - off)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else {
                task.cancel()
                throw ChainError.input("听写的音频块建不出来（\(n) 帧）")
            }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                if let dst = buf.floatChannelData {
                    memcpy(dst[0], src.baseAddress! + off, n * MemoryLayout<Float>.size)
                }
            }
            req.append(buf)
            off += n
            // 卡节奏：喂得比实时快太多，听写会把中间那些字丢掉。睡掉「这块该占的时间」减去已花掉的。
            let due = fedT0.addingTimeInterval(Double(off - from) / sr / feedPace)
            let left = due.timeIntervalSinceNow
            if left > 0 {
                try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000))
            }
        }
        req.endAudio()

        // 等到 final 为止；等不到就先 `finish()`（"音频喂完了，把最后这版结掉"）再给 3 秒 ——
        // `finish()` 之后系统通常还会回一次 final，那一版比部分结果完整。两头都没来才 cancel。
        var got = await box.wait(finalSecs: graceSecs)
        if !got {
            task.finish()
            got = await box.wait(finalSecs: 3.0)
        }
        task.cancel()

        let text = box.bestText
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var note = ""
        if trimmed.isEmpty {
            note = box.err.isEmpty ? "这一窗没认出一个字" : "报错：\(box.err)"
        } else if !box.err.isEmpty {
            note = "收尾报错：\(box.err)"
        } else if !box.sawFinal {
            note = "等 final 等了 \(Int(graceSecs)) s 没来，用了最后一版部分结果"
        }
        // pieces 里每个词的起点是「这一窗自己」的时间轴 ⇒ 抬到源时间轴上
        let base = Double(from) / sr
        var segs: [Segment] = []
        if !box.pieces.isEmpty {
            for p in box.pieces {
                segs.append(Segment(startSecs: base + p.startSecs, text: p.text))
            }
        } else if !trimmed.isEmpty {
            segs.append(Segment(startSecs: base, text: trimmed))
        }
        return (segs, trimmed.count, note)
    }

    private static func authText(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "没问过"
        case .denied: return "被拒"
        case .restricted: return "受限（家长控制／描述文件）"
        case .authorized: return "已授权"
        @unknown default: return "未知(\(s.rawValue))"
        }
    }
}

/// 一窗的收数处。系统回调的队列和 `await` 这头同时在读写，所以每样都过一把锁。
/// `@unchecked Sendable`：锁里已经是全量互斥，而且这一份只在一窗内活着、不跨窗复用。
private final class WindowBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _text = ""
    private var _pieces: [SpeechText.Segment] = []
    private var _err = ""
    private var _final = false

    private func snap() -> (text: String, pieces: [SpeechText.Segment], err: String, final: Bool) {
        lock.lock()
        let r = (_text, _pieces, _err, _final)
        lock.unlock()
        return r
    }

    var bestText: String { snap().text }
    var pieces: [SpeechText.Segment] { snap().pieces }
    var err: String { snap().err }
    var sawFinal: Bool { snap().final }

    func put(text: String, pieces: [SpeechText.Segment], isFinal: Bool) {
        lock.lock()
        // 只在文本变长时收：听写会把同一句改好几遍（补标点、改别字），留最长那一版。
        if text.count >= _text.count {
            _text = text
            _pieces = pieces
        }
        if isFinal { _final = true }
        lock.unlock()
    }

    func fail(_ msg: String) {
        lock.lock()
        if _err.isEmpty { _err = msg }
        lock.unlock()
    }

    /// 等到 final 或报错，最多 `finalSecs`；等不到就用手上最后一版部分结果。
    ///
    /// 为什么是轮询而不是续体：这头必须**保证**在 `finalSecs` 之内醒。挂续体等回调，碰上
    /// 系统既不回 final 也不报错那一格（听写任务被别的 app 抢走时真会这样）就永远醒不来，
    /// 「提取台词」那颗按钮从此转圈。200 ms 一次、最多几十个来回，代价看不见。
    func wait(finalSecs: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(finalSecs)
        while true {
            let s = snap()
            if s.final || !s.err.isEmpty { return s.final }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
