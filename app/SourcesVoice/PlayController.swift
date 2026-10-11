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
final class PlayController: NSObject, ObservableObject, AVAudioPlayerDelegate {
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
            p.delegate = self
            player = p
            VoiceJournal.line(String(format: "准备播 %@：%d Hz / %d 声道 / %.2f s / 音量 %.4f",
                                     url.lastPathComponent, Int(p.sampleRate),
                                     Int(p.numberOfChannels), p.duration, p.volume))
            if p.play() {
                isPlaying = true
                status = "播放中"
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
            VoiceJournal.line(String(format: "输出实测 样本 %d / 峰值 %.4f / rms %.5f%@",
                                     s.count, peak, rms,
                                     rms < 0.001 ? " ⇒ 这条基本是静音" : ""))
        }
    }

    // MARK: - AVAudioPlayerDelegate（回调线程不保证在主线程，一律跳回去改状态）

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.status = flag ? "放完了" : "播放中途停了"
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.isPlaying = false
            self.status = "解码出错：\(error?.localizedDescription ?? "无")"
            VoiceJournal.line("AVAudioPlayer 解码出错 " + (error?.localizedDescription ?? "无"))
        }
    }
}
