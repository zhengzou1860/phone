import Foundation
import AVFoundation
import Combine

@MainActor
final class AudioEngine: ObservableObject {
    @Published var isRecording = false
    /// 暂停中（还在录这一条，只是暂时不往文件里写）。`isRecording` 仍为真 ⇒ 互斥位照样拦着别的动作。
    @Published var isPaused = false
    @Published var recordedURL: URL?

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    /// 续录要按同一个格式重挂 tap，所以起录时把它留着。
    private var tapFormat: AVAudioFormat?

    func startRecording() {
        guard !isRecording else { return }

        // 会话必须自己定：整个 app 原来一次都没碰过 AVAudioSession，实际用的是宿主
        // （LiveContainer）留下来的那一套 ⇒ 录出来是不是静音、走不走麦克风全看运气。
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            VoiceJournal.line("录音会话 playAndRecord/defaultToSpeaker；" +
                              "session \(Int(session.sampleRate)) Hz / \(Int(session.inputNumberOfChannels)) 声道")
        } catch {
            VoiceJournal.line("设录音会话失败（继续试）：\(error.localizedDescription)")
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("record_\(Int(Date().timeIntervalSince1970)).wav")
        recordedURL = url

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        VoiceJournal.line(String(format: "设备输入格式 %d Hz / %d 声道（落盘就按这个口径，读数时再降 16k）",
                                 Int(format.sampleRate), Int(format.channelCount)))

        do {
            audioFile = try AVAudioFile(forWriting: url,
                                        settings: format.settings,
                                        commonFormat: .pcmFormatFloat32,
                                        interleaved: false)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self = self, let file = self.audioFile else { return }
                try? file.write(from: buffer)
            }
            tapFormat = format

            try engine.start()
            isRecording = true
        } catch {
            VoiceJournal.line("录音启动失败：\(error.localizedDescription)")
            isRecording = false
        }
    }

    /// 暂停：**摘掉 tap**，文件不关。
    ///
    /// 不在 tap 里读一个「暂停位」——那是音频渲染线程，主线程写它读，天然是一场数据竞争。
    /// 没有 tap 就没人往文件里写，续录时按原格式重挂一个，接着往同一条后面写。
    /// 画面那一头同时暂停 ⇒ 暂停多久都不影响录音和画面的对位（两边一起冻住）。
    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.pause()
        isPaused = true
        VoiceJournal.line("录音暂停：tap 已摘、文件不关，续录接着写同一条")
    }

    /// 续录。调用方必须**先让画面真在走了**再调这一条：反过来（录音先续）每暂停一次
    /// 就把声音整体往后推一点（画面起播那几十毫秒里录进去的是空白）。
    func resumeRecording() {
        guard isRecording, isPaused else { return }
        guard let format = tapFormat, audioFile != nil else {
            VoiceJournal.line("续录失败：格式或文件已经不在了（这一条只能停止）")
            return
        }
        do {
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self = self, let file = self.audioFile else { return }
                try? file.write(from: buffer)
            }
            try engine.start()
            isPaused = false
            VoiceJournal.line("录音已续：接着往同一条后面写")
        } catch {
            VoiceJournal.line("续录失败：\(error.localizedDescription)（这一条可以「停止」，已录下的还在）")
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        tapFormat = nil
        isRecording = false
        isPaused = false
        if let url = recordedURL { measure(url) }
    }

    /// 「录到的是不是静音」必须在录完这一刻量出来。
    ///
    /// 宿主是 LiveContainer，麦克风权限不在我们手里：拿不到时它不报错，只是安静地给你
    /// 一条全零 wav。下游 fbank / DiT / Vocos 拿到全零照样跑完、照样出文件、照样"播放中"，
    /// 光看界面分不开「没录到声音」和「播不出来」，所以把两边都写成数字。
    private func measure(_ url: URL) {
        Task.detached(priority: .utility) {
            guard let s = try? AudioProcessor.loadWAV16K(url) else {
                VoiceJournal.line("测录音失败：读不出 \(url.lastPathComponent)")
                return
            }
            var peak: Float = 0
            var sum = 0.0
            for v in s {
                let a = abs(v)
                if a > peak { peak = a }
                sum += Double(v) * Double(v)
            }
            let rms = (sum / Double(max(s.count, 1))).squareRoot()
            VoiceJournal.line(String(format: "录音实测 %d 样本 / 峰值 %.4f / rms %.5f%@",
                                     s.count, peak, rms,
                                     rms < 0.001 ? " ⇒ 这条基本是静音（麦克风没给声音）" : ""))
        }
    }
}
