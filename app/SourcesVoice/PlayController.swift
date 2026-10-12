import Foundation
import AVFoundation

/// 播放转换结果。
///
/// 「界面显示播放中、一点声音没有」这件事有三个来源，这里一个个堵掉：
/// 1. 录完音之后 AVAudioSession 还是 `.playAndRecord`，这种会话默认把输出路由到**听筒**，
///    不贴耳朵就听不见 ⇒ 播之前切成 `.playback`（外放）。
/// 2. `AVAudioPlayer.play()` 是**返回 Bool** 的，旧代码直接忽略 ⇒ 失败了 `isPlaying` 还置成
///    true，按钮永远停在「播放中」。
/// 3. 放完之后没人把状态收回来 ⇒ 同一格第二次点不动。
///
/// 顺带把这条 wav 的峰值/rms 写进磁盘日志：手机上「链子到底有没有出声」只有这一处能看出来，
/// 别靠耳朵猜。
@MainActor
final class PlayController: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var status = ""

    private var player: AVAudioPlayer?

    func play(url: URL) {
        stop()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            VoiceJournal.line("会话已切 playback；输出路由 " + routeText(session))
        } catch {
            VoiceJournal.line("播放前设会话失败：\(error.localizedDescription)")
        }

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            player = p
            VoiceJournal.line("准备播 \(url.lastPathComponent)：" + formatText(url))
            if p.play() {
                isPlaying = true
                status = "播放中"
                watch(p)
            } else {
                isPlaying = false
                status = "play() 返回 false（详见日志）"
                VoiceJournal.line("AVAudioPlayer.play() 返回 false")
            }
        } catch {
            isPlaying = false
            status = "打不开：\(error.localizedDescription)"
            VoiceJournal.line("AVAudioPlayer 建不出来：\(error.localizedDescription)")
        }
        measure(url)
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    /// 现在的输出设备一句话写进日志（听筒/外放/耳机在日志里分得开）
    private func routeText(_ session: AVAudioSession) -> String {
        session.currentRoute.outputs.map { "\($0.portName)/\($0.portType.rawValue)" }
            .joined(separator: ",")
    }

    /// AVAudioPlayer 没有 sampleRate 这个成员，真实格式要从文件头读。
    private func formatText(_ url: URL) -> String {
        guard let f = try? AVAudioFile(forReading: url) else { return "格式读不出来" }
        let fmt = f.processingFormat
        let frames = Int(f.length)
        return String(format: "%d 帧 / %d Hz / %d 声道 / %.2f s",
                      frames, Int(fmt.sampleRate), Int(fmt.channelCount),
                      Double(frames) / fmt.sampleRate)
    }

    private func measure(_ url: URL) {
        Task.detached(priority: .utility) {
            guard let s = try? AudioProcessor.loadWAV16K(url) else {
                VoiceJournal.line("测峰值失败：读不出 \(url.lastPathComponent)")
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
            // 文件名必须在这一行里：他一次跑会连着播「系统原声」和「转换成品」两个文件，
            // 只留三个数就成了两行没有主人的读数，正是要分的时候分不出来。
            VoiceJournal.line(String(format: "输出实测 %@ 样本 %d / 峰值 %.4f / rms %.5f%@",
                                     url.lastPathComponent, s.count, peak, rms,
                                     rms < 0.001 ? " ⇒ 这条基本是静音" : ""))
        }
    }

    /// 播完自己把状态收回来。
    ///
    /// 没用 AVAudioPlayerDelegate：那个协议的回调到底在不在主线程没有保证，
    /// 声明成 nonisolated 还是 MainActor 都可能撞上隔离不匹配，编译先过不去。
    /// 100 ms 轮询一次，代价是状态最多晚 0.1 s 翻转。
    private func watch(_ p: AVAudioPlayer) {
        Task { [weak self] in
            while let s = self, s.player === p, s.isPlaying {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if !p.isPlaying {
                    s.isPlaying = false
                    s.status = p.currentTime > 0 ? "放完了" : "播放中途停了"
                    break
                }
            }
        }
    }
}
