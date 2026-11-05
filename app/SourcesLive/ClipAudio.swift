//
//  ClipAudio.swift
//  PC 回来的是一路 MJPEG，没有声音。原声只能在手机本地放：片源本来就是手机这份，
//  所以不重新编码，只把音轨摘成一条纯音频 composition 交给 AVPlayer；
//  视频轨不参与，免得同一段 1080p 为出声再解一遍，把推帧节奏拖垮。
//
//  画面上看到的帧要过 PC 的换脸链才出现，所以声音必须落后 reader 的 PTS 一个流水线延迟。
//  延迟量由 LiveAudio 从 /live_status 的 input_age_ms + output_age_ms 算出来，
//  这里只负责按给定位置起播、以及偏太多时纠一次。
//

import AVFoundation
import Foundation

final class ClipAudio {
    private var player: AVPlayer?
    private var wantPlaying = false
    private var pendingStart: DispatchWorkItem?
    private var generation = 0

    /// 这一片有没有音轨；没有就只推画面，界面那边会说明。
    private(set) var hasTrack = false

    /// 换片：摘音轨、装 player。同步做完，免得「选完马上点播放」时声音还没就绪。
    func load(url: URL) {
        stop()
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { return }

        let range = track.timeRange
        let startSec = CMTimeGetSeconds(range.start)
        let durSec = CMTimeGetSeconds(range.duration)
        guard startSec.isFinite, startSec >= 0, durSec.isFinite, durSec > 0 else { return }

        let comp = AVMutableComposition()
        guard let dst = comp.addMutableTrack(withMediaType: .audio,
                                             preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return }
        do {
            // 原位置插入：音轨比视频晚开始（片头空白）时，时间轴不能往前挪。
            try dst.insertTimeRange(range, of: track, at: range.start)
        } catch {
            return
        }

        let item = AVPlayerItem(asset: comp)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        p.automaticallyWaitsToMinimizeStalling = false
        player = p
        hasTrack = true
    }

    /// 从片的第 seconds 秒开始，延后 delay 秒出声——delay 就是 PC 那条链的延迟。
    func start(at seconds: Double, delay: Double) {
        guard let player = player, hasTrack else { return }
        wantPlaying = true
        generation += 1
        let gen = generation
        pendingStart?.cancel()
        pendingStart = nil
        player.pause()                 // 暂停态/拖过进度条时可能还在响，先按住再 seek
        let from = max(0, seconds.isFinite ? seconds : 0)
        player.seek(to: CMTime(seconds: from, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)

        let wait = max(0, delay.isFinite ? delay : 0)
        guard wait > 0 else {
            activate()
            player.play()
            return
        }
        let work = DispatchWorkItem { [weak self, weak player] in
            guard let self = self, let player = player,
                  self.generation == gen, self.wantPlaying else { return }
            self.pendingStart = nil
            self.activate()
            player.play()
        }
        pendingStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// 目标：此刻屏幕上显示的是片的第 target 秒。偏出阈值才拉回来，
    /// 平时让音频钟和 reader 的墙钟自己走——每秒 seek 一次会听出咔哒声。
    func sync(to target: Double) {
        guard let player = player, hasTrack, wantPlaying, pendingStart == nil,
              target.isFinite else { return }
        let pos = CMTimeGetSeconds(player.currentTime())
        guard pos.isFinite else { return }
        if abs(pos - target) > 0.35 {
            player.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // 来电/系统打断会把 player 按停；wantPlaying 还是 true，这里把它接回去。
        if player.rate == 0 {
            activate()
            player.play()
        }
    }

    func pause() {
        wantPlaying = false
        generation += 1
        pendingStart?.cancel()
        pendingStart = nil
        player?.pause()
        deactivate()
    }

    func stop() {
        pause()
        player?.seek(to: .zero)
        player = nil
        hasTrack = false
    }

    private func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    private func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false,
                                                      options: [.notifyOthersOnDeactivation])
    }

    deinit {
        pendingStart?.cancel()
        player?.pause()
    }
}
