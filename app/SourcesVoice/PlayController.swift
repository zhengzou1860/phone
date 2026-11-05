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
///
/// ## 语速为什么不走 `AVAudioPlayer.rate`
/// 那个也有 rate，但它是**变调的**（磁带快进那种：1.5× 等于把整条频谱抬 7 个半音）。
/// 这一版 app 整个围着「音调得对上」做，快一点就变尖的声音不能用 ⇒ 播的时候走
/// `AVAudioEngine` + `AVAudioUnitTimePitch`，`rate` 只改时长、`pitch` 钉死 0 音分。
/// 引擎这条路真机上还没验过，起不来就退回原来那条 `AVAudioPlayer`（那一趟语速不生效，
/// 状态行会写清走的哪条）。
@MainActor
final class PlayController: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var status = ""
    /// 正在响的是哪一条。① 和 ④ 各挂一个播放器共用这一个 controller，
    /// 只留 isPlaying 的话「播放中」会同时点亮在两条上，看不出谁在响。
    @Published var playingURL: URL?

    /// 语速倍率 0.5–2.0，1.0 是原速，音高不动。正在播的那一条当场跟着变，不用停了重播。
    /// 存 UserDefaults：调顺手之后就别每次开 app 再调一遍。
    @Published var rate: Float {
        didSet {
            guard rate != oldValue else { return }
            timePitch.rate = rate
            UserDefaults.standard.set(rate, forKey: "playRate")
            VoiceJournal.line(String(format: "语速设成 %.2f×（音高不动）", rate))
        }
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var attached = false
    /// 引擎起不来时的退路：那条只有原速。
    private var player: AVAudioPlayer?

    override init() {
        let saved = UserDefaults.standard.float(forKey: "playRate")
        rate = (saved >= 0.5 && saved <= 2.0) ? saved : 1.0
        super.init()
        timePitch.pitch = 0
    }

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

        status = ""
        if !playWithEngine(url) {
            playWithPlayer(url)
        }
        measure(url)
    }

    /// 文件 → TimePitch → 输出。返回 false 就是没起来，调用方退回原速那条。
    private func playWithEngine(_ url: URL) -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            if !attached {
                engine.attach(node)
                engine.attach(timePitch)
                attached = true
            }
            // 每播一条重接：④ 的系统原声和链子成品的采样率不一定一样，接死了就绑在上一条的格式上。
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(node, to: timePitch, format: file.processingFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
            timePitch.rate = rate
            timePitch.pitch = 0
            engine.prepare()
            try engine.start()
            node.stop()
            node.scheduleFile(file, at: nil)
            node.play()
            isPlaying = true
            playingURL = url
            status = String(format: "播放中（语速 %.2f×，音高不动）", rate)
            VoiceJournal.line(String(format: "走引擎播 %@：语速 %.2f×｜%@",
                                     url.lastPathComponent, rate, formatText(url)))
            watchEngine()
            return true
        } catch {
            VoiceJournal.line("引擎这条路起不来：\(error.localizedDescription)｜退回原速播放")
            engine.pause()
            isPlaying = false
            playingURL = nil
            return false
        }
    }

    private func playWithPlayer(_ url: URL) {
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            player = p
            VoiceJournal.line("准备播 \(url.lastPathComponent)：" + formatText(url))
            if p.play() {
                isPlaying = true
                playingURL = url
                status = rate == 1.0 ? "播放中"
                    : String(format: "播放中（引擎没起来，语速 %.2f× 这一趟没生效）", rate)
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
    }

    func stop() {
        node.stop()
        engine.pause()
        player?.stop()
        player = nil
        isPlaying = false
        playingURL = nil
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

    /// 播完自己把状态收回来（引擎那条）。轮询的理由同下面 `watch`：回调在不在主线程没保证。
    private func watchEngine() {
        Task { [weak self] in
            guard let first = self else { return }
            let mine = first.playingURL
            while let s = self, s.isPlaying, s.playingURL == mine {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if !s.node.isPlaying {
                    s.isPlaying = false
                    s.playingURL = nil
                    s.status = "放完了"
                    s.engine.pause()
                    break
                }
            }
        }
    }

    /// 播完自己把状态收回来（退路那条 `AVAudioPlayer`）。
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
                    s.playingURL = nil
                    s.status = p.currentTime > 0 ? "放完了" : "播放中途停了"
                    break
                }
            }
        }
    }
}
