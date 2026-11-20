import Foundation
import AVFoundation
import SwiftUI
import UIKit

/// 「配音」那一格的画面泵：**只放画面，一个声音都不出**。
///
/// 为什么不用 AVKit 的 `VideoPlayer`：那个控件自带播放键和进度条，还会自己管音频会话；
/// 这一格要的恰好是「画面归我、声音归麦克风」——静音必须钉死，会话必须让给录音。
/// `AVPlayerLayer` 只画画面，正好，也不往包里多引一个框架。
///
/// 对时是这一格唯一的技术难点：录音和画面必须落在同一条时间轴上，否则他对着嘴念出来的
/// 那一条装回去就整体偏了。做法是**画面先起、等它真在走了再起录音**，然后读画面自己
/// 走到第几秒（`now`）—— 那个数就是录音头上要补的静音。不用墙钟去猜两台泵各花了多久。
@MainActor
final class MutedVideoPlayer: ObservableObject {
    @Published var isPlaying = false
    /// 画面走到第几秒（0.2 s 报一次，给界面上那行读数用）。
    @Published var seconds: Double = 0
    @Published var status = ""

    let player = AVPlayer()
    /// 画面放完了要顺手把录音也停掉：后面没画面可对，再录下去只是白占盘。
    var onEnd: (() -> Void)?

    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var seekDone = false
    private var keysReady = false
    private var loadedPath = ""

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .pause
        // 回调在不在主线程没保证（同 PlayController 那条理由）⇒ 一律跳回 MainActor 再动状态。
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self = self, t.isNumeric else { return }
                self.seconds = max(0, t.seconds)
            }
        }
    }

    /// 画面此刻真正走到哪儿。对时读的是这个，不是 `seconds`：
    /// 后者是 0.2 s 一次的采样，最多滞后一格，而那一格正好是要补进录音头上的量。
    var now: Double {
        let t = player.currentTime()
        return t.isNumeric ? max(0, t.seconds) : 0
    }

    /// 换片源时把上一片卸干净。**选视频那一步只做到这儿为止**：不建 item、不 preroll。
    /// 0.1/55 他选视频当场闪退，日志停在「历史文件扫目录」之后、本类的任何一行之前，
    /// 而 app 自带的未捕获异常钩子没喊话 ⇒ 不是 ObjC 异常，是硬死。落点就是原来在这儿
    /// 主线程当场 `AVPlayerItem(url:)` ＋ `preroll` 那两句。画面只有点「配音」时才需要。
    func unload() {
        VoiceJournal.line("配音画面卸载：停上一片、清 item（这一步不建新的）")
        stop()
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        loadedPath = ""
        seconds = 0
        status = "点「配音」画面才起来（静音，声音留给麦克风）"
        VoiceJournal.line("配音画面已卸")
    }

    /// 备画面，**照剪辑线在这台机上走通的那条顺序**（`app/Sources/Cut.swift:984`）：
    /// AVURLAsset → tracks/duration 先在分离线程等齐 → 回主线程 `AVPlayerItem(asset:)`。
    /// 不 preroll：那一句会在主线程把整条播放泵拉起来，剪辑线从来不用它。
    /// 首帧慢一点没关系 —— 头上补多少静音是读画面自己的钟量出来的，不是猜的。
    func prepare(_ url: URL, picSecs: Double) async {
        unload()
        loadedPath = url.path
        VoiceJournal.line("配音画面准备 \(url.lastPathComponent)（\(String(format: "%.1f", picSecs)) s）：先等 tracks/duration")
        let asset = AVURLAsset(url: url)
        keysReady = false
        asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { [weak self] in
            Task { @MainActor in self?.keysReady = true }
        }
        // 不用 continuation（同 seekDone 那条理由：宁可轮询也不赌回调一定来），最多等 3 s。
        for _ in 0..<150 {
            if keysReady { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let d = CMTimeGetSeconds(asset.duration)
        VoiceJournal.line("配音画面 keys \(keysReady ? "齐了" : "等了 3 s 没齐")／duration \(String(format: "%.2f", d)) s")
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        VoiceJournal.line("配音画面 item 已挂（不 preroll）")
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.stop()
                self.status = "画面放完了"
                VoiceJournal.line("配音：画面放到末尾，录音跟着停")
                self.onEnd?()
            }
        }
        status = String(format: "画面 %.1f s（静音，声音留给麦克风）", picSecs)
        VoiceJournal.line("配音画面已备 \(url.lastPathComponent)（\(String(format: "%.1f", picSecs)) s，静音）")
    }

    /// 从头放，并且**等到画面真的在走**才返回。返回后 `now` 就是画面已经走掉的秒数。
    func playFromStart() async {
        guard player.currentItem != nil else {
            status = "还没选视频"
            return
        }
        player.isMuted = true
        // 归零必须等它真落到位再放：seek 是异步的，上一趟停在 30 s 的话，
        // 紧接着读 now 会读到 30 ⇒ 录音头上白补 30 s 静音，整条声音全跑到画面后面去了。
        // 不用 continuation（这台机上宁可轮询也不赌回调一定来），最多等 2 s。
        seekDone = false
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.seekDone = true }
        }
        for _ in 0..<100 {
            if seekDone { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        player.play()
        isPlaying = true
        status = "画面播放中（静音）"
        // play() 返回不等于画面已经在动（首帧解码要几十到几百毫秒）。不等就读 now，
        // 会把「还没起」当成「起了 0 秒」，头上那段静音就补少了 ⇒ 整条录音早于画面。
        var rolled = false
        for _ in 0..<150 {
            if now > 0.02 { rolled = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        seconds = now
        VoiceJournal.line(String(format: "配音画面已起：走到 %.3f s（归零%@／%@）",
                                 now, seekDone ? "落了" : "等了 2 s 没落",
                                 rolled ? "真在走" : "等了 3 s 还没走，按 0 算"))
    }

    func stop() {
        let was = isPlaying
        player.pause()
        isPlaying = false
        if was { status = "画面已停" }
    }

    /// 暂停：画面冻在这儿，录音那一头同时摘 tap ⇒ 两边一起停，对位不动。
    func pause() {
        player.pause()
        isPlaying = false
        status = String(format: "画面暂停在 %.1f s（录音也暂停）", now)
    }

    /// 续播，并且**等到画面真在走了**才返回，调用方这才续录。
    /// 顺序和起播一样：录音先续的话，画面起播那几十毫秒里录进去的是空白，
    /// 每暂停一次就把声音整体往后推一点。
    func resumeFromPause() async {
        let at = now
        player.play()
        isPlaying = true
        status = "画面播放中（静音）"
        var rolled = false
        for _ in 0..<150 {
            if now > at + 0.02 { rolled = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        seconds = now
        VoiceJournal.line(String(format: "配音续播：从 %.3f s 走到 %.3f s（%@）",
                                 at, now, rolled ? "真在走" : "等了 3 s 还没走"))
    }

    /// 这一条还是不是当前备着的那一片（换片之后旧录音不能再拿去转换）。
    func holds(_ url: URL) -> Bool { loadedPath == url.path }
}

/// 把 `AVPlayerLayer` 铺进 SwiftUI。黑底、等比缩放，画面不改一个像素。
struct MutedVideoView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}