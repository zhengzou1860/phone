import AVFoundation
import AVKit
import CoreMedia
import CoreML
import Foundation
import SwiftUI
import UIKit

/// 实时左右眼：相册里选一条普通视频，边解码边形变边直接上屏，不写文件、不进相册。
///
/// 跟「先转完再播」那条两趟的区别，也是这条的天花板：
/// 深度单价实测 180~200 ms/帧（CPU、送检 518x392 钉死），30 帧的播放要 33 ms/帧，差 6 倍。
/// 所以深度线程只在空着的时候领最新那一帧去算，算完发布；显示线程照 30 帧的节奏走，
/// 没有新深度就复用上一张 ⇒ 画面动是流畅的，只有立体感的更新是 5 次/秒一级一级跳。
/// 整片 p1/p99 在这里拿不到（未来帧还没解出来），改成已见样本的滑动分位：开头几秒的幅度会偏，
/// 越播越准。这两条都在统计那三行里如实报出来。
final class VRLive {
    /// 与全片共用「一次只许一条」这条规矩：Metal 那份静态地基（keep/currentCommand）不给并发踩
    static let door = NSLock()
    static var inside = false
    /// 当前在跑的这一条：界面上的暂停/拖进度/位移都要转给它
    private static var current: VRLive?

    static func isBusy() -> Bool {
        door.lock(); defer { door.unlock() }
        return inside
    }

    /// 界面上那枚停止键走这里：转给当前在跑的那条。只改旗子，收兵还是两条线程自己走
    static func requestStopCurrent() {
        door.lock(); let c = current; door.unlock()
        c?.requestStop()
    }

    /// 左右眼水平位移存这一档：下次进来直接沿用，省得每部片子重对镜片
    static let shiftKey = "vr3d.live.xshift"
    static var storedShiftPct: Double { UserDefaults.standard.double(forKey: shiftKey) }

    let url: URL
    let eyeLong: Int
    let bpct: Float
    let zp: Float
    let smooth: Float
    let units: MLComputeUnits
    let rot: Bool
    /// 收兵后把报告交回界面（在主线程上调）
    var onEnd: ((String) -> Void)?

    // —— 两条线程之间的全部状态都由 dLock 保护 ——
    private let dLock = NSLock()
    private var running = false
    private var handPending = false
    private var handBusy = false
    private var latestRaw: [Float] = []
    private var latestSeq = -1
    private var depthTakes = 0
    private var depthSumMs = 0.0
    private var depthErr = ""
    private var depthFails = 0
    private var pool: [Float] = []
    private var lo: Float = 0
    private var span: Float = 1
    // —— 界面上的控件发过来的播放控制，跟上面这些同一条锁 ——
    private var paused = false
    private var seekTo: Double?
    private var pauseAt = UInt64(0)
    private var pausedAccum = 0.0
    /// 每眼水平位移（占每眼宽的比例，正=两只眼一起右移）
    private var shiftPct: Float = 0
    /// 位移每变一次 +1：显示线程看到它变了先把 6 块显示缓冲抹一次黑
    private var shiftSeq = 0
    /// 已经放到第几秒（界面每 0.25 s 来取一次，画进度条）
    private var posSeen = 0.0
    /// 这一段播放的起点：拖完进度就是拖到的那一点，声钟和墙钟都按它对齐
    private var t0sec = 0.0
    /// 整片长度，进度条的右端
    private(set) var duration = 0.0

    private var src: VRSource?
    private var feed: VRDepthFeed?
    private var warp: VRWarp?
    private var stream: VRFrameStream?
    private var framePB: CVPixelBuffer?
    private var handPB: CVPixelBuffer?
    private var showPBs: [CVPixelBuffer] = []
    private var fmtDesc: CMFormatDescription?
    private var layer: AVSampleBufferDisplayLayer?
    private var audio: AVAudioPlayer?
    private weak var label: UILabel?

    private var note = ""
    private var frames = 0
    private var holes = 0.0
    private var gpuSum = 0.0
    private var clock0 = UInt64(0)

    init(url: URL, eyeLong: Int, bpct: Float, zp: Float, smooth: Float,
         units: MLComputeUnits, rot: Bool) {
        self.url = url
        self.eyeLong = eyeLong
        self.bpct = bpct
        self.zp = zp
        self.smooth = smooth
        self.units = units
        self.rot = rot
    }

    /// 界面按「停止」调这个：只改旗子，真正的收兵在两条线程自己走到头之后
    func requestStop() {
        dLock.lock(); running = false; dLock.unlock()
    }

    var isPausedNow: Bool {
        dLock.lock(); defer { dLock.unlock() }
        return paused
    }

    /// 已经放到第几秒
    var position: Double {
        dLock.lock(); defer { dLock.unlock() }
        return posSeen
    }

    /// 暂停/继续。旗子给显示线程看，音频当场停/接（墙钟那头把暂停这段从走时间里扣掉）
    func setPaused(_ p: Bool) {
        dLock.lock()
        if p == paused { dLock.unlock(); return }
        paused = p
        let now = DispatchTime.now().uptimeNanoseconds
        if p { pauseAt = now } else { pausedAccum += Double(now &- pauseAt) / 1_000_000_000.0 }
        dLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let a = self?.audio else { return }
            if p { a.pause() } else { a.play() }
        }
    }

    /// 拖进度：旗子留给显示线程去落（解码器只有它能动），音频当场跟过去
    func seek(to seconds: Double) {
        let t = min(max(0, seconds), max(0, duration - 0.2))
        dLock.lock(); seekTo = t; dLock.unlock()
        let hold = isPausedNow
        DispatchQueue.main.async { [weak self] in
            guard let s = self, let a = s.audio else { return }
            a.currentTime = t
            if !hold { a.play() }
        }
    }

    /// 左右眼画面的水平位移（±12% 每眼宽封顶）。滑杆松手才调这里，一次抹一次缓冲
    func setShift(_ pct: Double) {
        let v = Float(max(-0.12, min(0.12, pct)))
        dLock.lock()
        if abs(v - shiftPct) < 1e-4 { dLock.unlock(); return }
        shiftPct = v
        shiftSeq += 1
        dLock.unlock()
        UserDefaults.standard.set(Double(v), forKey: VRLive.shiftKey)
        VRJournal.line("实时 水平位移 \(String(format: "%+.1f", Double(v) * 100))%")
    }

    /// 起头。成功返回空串并把两条线程放出去；失败返回那句原因，界面直接显示，不用等线程。
    func start(layer: AVSampleBufferDisplayLayer, label: UILabel) -> String {
        VRLive.door.lock()
        if VRLive.inside {
            VRLive.door.unlock()
            return "已经有一个实时播放在跑，这条不起。"
        }
        VRLive.inside = true
        VRLive.current = self
        VRLive.door.unlock()
        self.layer = layer
        self.label = label
        let first = setup()
        if !first.isEmpty {
            VRLive.door.lock(); VRLive.inside = false; VRLive.current = nil; VRLive.door.unlock()
            return first
        }
        dLock.lock(); running = true; dLock.unlock()
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in self?.depthPump() }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in self?.pump() }
        return ""
    }

    private func setup() -> String {
        guard VRTech.boot() else { return "Metal 起不来：\(VRTech.initNote)" }
        guard let s = VRSource(url: url, eyeLong: eyeLong) else {
            return "读不出这条片子（详情见磁盘日志）"
        }
        src = s
        let found = VRDepth.locate()
        guard let modelURL = found.url else { return "包里没有深度模型：\(found.note)" }
        let got = VRDepth.load(units)
        guard let model = got.model else {
            return "\(VRPilot.unitsName(units)) 加载失败（\(VRUtil.ms(got.ms))）: \(got.note)"
        }
        let tgt = VRDepth.inputTarget(model, eyeW: s.eyeW, eyeH: s.eyeH)
        var fn = ""
        guard let f = VRDepthFeed(model: model, eyeW: s.eyeW, eyeH: s.eyeH,
                                  mw: tgt.w, mh: tgt.h, rot: rot, note: &fn) else {
            return "送检通道建不起来：\(fn)"
        }
        feed = f
        var wn = ""
        guard let w = VRWarp(eyeW: s.eyeW, eyeH: s.eyeH, bpct: bpct, note: &wn) else {
            return "形变建不起来：\(wn)"
        }
        warp = w
        guard let st = VRFrameStream(src: s) else { return "顺序解码起不来（startReading 失败）" }
        stream = st
        guard let a = VRTech.pixelBuffer(width: s.eyeW, height: s.eyeH).pb,
              let b = VRTech.pixelBuffer(width: s.eyeW, height: s.eyeH).pb else {
            return "帧缓冲造不出来"
        }
        framePB = a
        handPB = b
        // 显示缓冲按轮转用固定的 6 份：每帧新造的话，纹理缓存里会一份一份攒着不回来（全片实测 1.65 MB/帧）
        for _ in 0..<6 {
            guard let pb = VRTech.pixelBuffer(width: s.eyeW * 2, height: s.eyeH).pb else {
                return "显示缓冲造不出来（已造 \(showPBs.count) 份）"
            }
            if fmtDesc == nil {
                var fd: CMFormatDescription?
                if CVVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                imageBuffer: pb,
                                                                formatDescriptionOut: &fd) == noErr {
                    fmtDesc = fd
                }
            }
            showPBs.append(pb)
        }
        guard fmtDesc != nil else { return "显示缓冲的格式描述建不出来" }
        duration = s.duration
        // 上一轮对镜片对出来的位移直接续上
        dLock.lock()
        shiftPct = Float(max(-0.12, min(0.12, VRLive.storedShiftPct)))
        dLock.unlock()
        // 声音尽力而为：读不出来（没音轨或格式不认）就退回墙钟，画面照走
        if let ap = try? AVAudioPlayer(contentsOf: url) {
            ap.prepareToPlay()
            audio = ap
        }
        let rotName = rot ? "转90°" : "摆正"
        let audioName = audio == nil ? "没有（走墙钟）" : "接上（走声钟）"
        let shiftName = String(format: "%+.1f", Double(shiftPct) * 100)
        // 这块是在后台线程跑的： UILabel 只能主线程碰，起手那行也一样交回主线程写
        let startLine = "实时起手：每眼 \(s.eyeW)x\(s.eyeH)｜\(String(format: "%.1f", s.fps)) fps"
            + "｜\(VRPilot.unitsName(units))｜深度 \(tgt.w)x\(tgt.h) 送检｜\(modelURL.lastPathComponent)"
            + "｜声音\(audioName)｜水平位移\(shiftName)%｜点屏幕出控件"
        DispatchQueue.main.async { [weak self] in self?.label?.text = startLine }
        VRJournal.line("实时 开始 \(url.lastPathComponent) 每眼 \(s.eyeW)x\(s.eyeH)"
            + " \(String(format: "%.1f", s.fps)) fps 视差\(bpct)% zp\(zp) 送检\(tgt.w)x\(tgt.h)"
            + " 朝向\(rotName) 水平位移\(shiftName)%")
        return ""
    }

    /// 深度线程：空着才领活，一次只算一帧；算完把眼格数组发布出去
    private func depthPump() {
        guard let f = feed, let h = handPB else {
            dLock.lock()
            depthErr = "深度线程拿不到送检通道或交接缓冲"
            dLock.unlock()
            return
        }
        while true {
            dLock.lock()
            if !running { dLock.unlock(); break }
            if !handPending || handBusy || depthFails >= 3 { dLock.unlock(); Thread.sleep(forTimeInterval: 0.004); continue }
            handPending = false
            handBusy = true
            dLock.unlock()

            let r = f.infer(srcPB: h)
            var fresh: [Float] = []
            var pms = 0.0
            if r.err == nil, !r.raw.isEmpty {
                fresh = r.raw
                pms = r.ms.predict
            } else {
                dLock.lock()
                depthFails += 1
                if depthErr.isEmpty { depthErr = r.err ?? "深度数组是空的" }
                dLock.unlock()
            }

            dLock.lock()
            handBusy = false
            if !fresh.isEmpty {
                latestRaw = fresh
                latestSeq += 1
                depthTakes += 1
                depthSumMs += pms
                // 在线分位的样本池：每 16 个取一个，满了就从最老那头滑掉
                var i = 0
                while i < fresh.count {
                    pool.append(fresh[i])
                    i += 16
                }
                if pool.count > 60000 { pool.removeFirst(pool.count - 60000) }
            }
            dLock.unlock()
        }
    }

    /// 显示线程：解码→形变→上屏，按帧号排节奏；界面发的暂停/拖进度/水平位移都在这一圈里落
    private func pump() {
        guard let s = src, let f = framePB, let w = warp, let lay = layer, let st = stream else {
            finish("实时 内部状态没建起来（setup 提前退了）")
            return
        }
        let px = s.eyeW * s.eyeH
        let fps = s.fps > 1 ? s.fps : 30.0
        let eyeWf = Float(s.eyeW)
        var dn = [Float](repeating: 0, count: px)
        var prev = [Float](repeating: 0, count: px)
        var usedSeq = -1
        // k = 这一段里已解出的源帧（排节奏、算单价用它）；n = 已上屏的样本数（只喂 PTS，
        // PTS 必须一直往前，否则显示层会把倒回去的样本丢掉 ⇒ 暂停期间的补帧也算在 n 里，不进 k）
        var k = 0
        var n = 0
        var lastSeq = -1
        clock0 = DispatchTime.now().uptimeNanoseconds
        audio?.play()
        while true {
            dLock.lock()
            let go = running
            let sd = seekTo
            let hold = paused
            let wantSeq = shiftSeq
            let xo = shiftPct * eyeWf
            dLock.unlock()
            if !go { note = "按了停止"; break }
            if let t = sd {
                if !reseat(t, layer: lay) {
                    note = "拖到 \(String(format: "%.1f", t)) s 起不动（解码器重开失败）"
                    break
                }
                k = 0
                usedSeq = -1
                continue
            }
            let moved = wantSeq != lastSeq
            if moved {
                lastSeq = wantSeq
                wipeShow()
            }
            if hold && !moved {
                // 停住：不解码不重画，屏上留最后那一帧；每 50 ms 回来听一次旗子
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            if !hold {
                guard st.next(into: f) else { note = "解码到片尾"; break }
                dLock.lock()
                if !handPending && !handBusy, let h = handPB {
                    VRUtil.copyRows(from: f, to: h)
                    handPending = true
                }
                dLock.unlock()
                var fresh = false
                dLock.lock()
                if latestSeq != usedSeq && !latestRaw.isEmpty { usedSeq = latestSeq; fresh = true }
                dLock.unlock()
                if fresh { recompute(px: px, dn: &dn, prev: &prev) }
            }
            let outPB = showPBs[n % showPBs.count]
            let rr = w.render(srcPB: f, dn: dn, zp: zp, xoff: xo, outPB: outPB)
            if let e = rr.err { note = "第 \(k + 1) 帧形变失败：\(e)"; break }
            guard let sb = sample(outPB, k: n, fps: fps) else { note = "第 \(k + 1) 帧的显示样本造不出来"; break }
            lay.enqueue(sb)
            if lay.status == .failed {
                note = "显示层出错：\(lay.error?.localizedDescription ?? "-")"
                break
            }
            n += 1
            // 停住期间只有刚拖完水平位移那一下走到这里：把静止这一帧按新位移重画一遍就回去
            if hold { Thread.sleep(forTimeInterval: 1.0 / fps); continue }
            holes += rr.holes
            gpuSum += rr.gpu
            k += 1
            frames = k
            dLock.lock(); posSeen = t0sec + Double(k) / fps; dLock.unlock()
            pace(k: k, fps: fps)
            if k % 30 == 0 { stat(fps: fps) }
        }
        st.close()
        finish("")
    }

    /// 拖进度落到解码器上：重开 reader、两种钟都对到新起点、把屏上的旧样本冲掉
    private func reseat(_ t: Double, layer lay: AVSampleBufferDisplayLayer) -> Bool {
        guard let st = stream, st.restart(from: t) else {
            VRJournal.line("实时 拖到 \(String(format: "%.1f", t)) s 解码器重开失败")
            return false
        }
        dLock.lock()
        t0sec = t
        pausedAccum = 0
        seekTo = nil
        posSeen = t
        let hold = paused
        dLock.unlock()
        clock0 = DispatchTime.now().uptimeNanoseconds
        lay.flush()
        if !hold { audio?.play() }
        let acPos = String(format: "%.1f", audio?.currentTime ?? -1)
        let tPos = String(format: "%.1f", t)
        VRJournal.line("实时 拖到 \(tPos) s（声钟 \(acPos) s）")
        return true
    }

    /// 位移一变，先把 6 块显示缓冲整块抹黑：平移会在半边的一头腾出几列谁都不写，
    /// 不清的话那几列露的是轮转缓冲里 6 帧前的残影，一跳一跳比黑边还难看。
    private func wipeShow() {
        for pb in showPBs {
            CVPixelBufferLockBaseAddress(pb, [])
            if let b = CVPixelBufferGetBaseAddress(pb) {
                let n = CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb)
                memset(b, 0, n)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
        }
    }

    /// 拿已见样本的 p1/p99 归一化，再跟上一张深度做时域平滑 0.4（只在真来了新深度时做）
    private func recompute(px: Int, dn: inout [Float], prev: inout [Float]) {
        dLock.lock()
        defer { dLock.unlock() }
        guard latestRaw.count >= px else { return }
        if pool.count >= 1024 {
            let sorted = pool.sorted()
            lo = sorted[sorted.count / 100]
            let hi = sorted[(sorted.count * 99) / 100]
            span = max(1e-6, hi - lo)
        }
        var i = 0
        while i < px {
            dn[i] = min(1.0, max(0.0, (latestRaw[i] - lo) / span))
            i += 1
        }
        if smooth > 0 {
            i = 0
            while i < px {
                dn[i] = (1 - smooth) * dn[i] + smooth * prev[i]
                prev[i] = dn[i]
                i += 1
            }
        } else {
            i = 0
            while i < px { prev[i] = dn[i]; i += 1 }
        }
    }

    private func sample(_ pb: CVPixelBuffer, k: Int, fps: Double) -> CMSampleBuffer? {
        guard let fd = fmtDesc else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(fps * 1000)),
                                        presentationTimeStamp: CMTime(value: Int64(k), timescale: Int32(fps * 1000)),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        let st = CMSampleBufferCreateReady(kCFAllocatorDefault, nil, pb, fd, 1, &timing, 0, nil, &sb)
        return st == noErr ? sb : nil
    }

    /// 有声音跟声钟，没声音跟墙钟。落后了就继续走（顺序解码器seek 一次 54 ms，不划算），滞后写进统计。
    /// 两边都对到 t0sec 这个起点上：拖完进度 t0sec 变了，暂停那段由 pausedAccum 扣掉。
    private func pace(k: Int, fps: Double) {
        dLock.lock()
        let base = t0sec
        let acc = pausedAccum
        dLock.unlock()
        let target = base + Double(k) / fps
        let now: Double
        if let a = audio, a.isPlaying { now = a.currentTime }
        else { now = base + Double(DispatchTime.now().uptimeNanoseconds &- clock0) / 1_000_000_000.0 - acc }
        let ahead = target - now
        if ahead > 0.001 { Thread.sleep(forTimeInterval: min(ahead, 0.25)) }
    }

    private func stat(fps: Double) {
        let secs = max(Double(DispatchTime.now().uptimeNanoseconds - clock0) / 1_000_000_000.0, 0.001)
        dLock.lock()
        let takes = depthTakes
        let avgD = takes > 0 ? depthSumMs / Double(takes) : 0.0
        let poolN = pool.count
        let err = depthErr
        dLock.unlock()
        let shown = Double(frames) / secs
        let hz = Double(takes) / secs
        let gpuPer = frames > 0 ? gpuSum / Double(frames) : 0.0
        let holePct = frames > 0 ? holes / Double(frames) : 0.0
        let errLine = err.isEmpty ? "" : "\n深度出错 \(err)（连续 3 次就不算了，画面退回平板）"
        let text = "实时 出帧 \(frames)＝\(String(format: "%.1f", shown)) 帧/秒（源 \(String(format: "%.1f", fps))）"
            + "\n深度更新 \(takes) 次＝\(String(format: "%.1f", hz)) 次/秒、单价 \(String(format: "%.0f", avgD)) ms"
            + "｜其余 \(frames - takes) 帧复用上一张"
            + "\n形变 \(String(format: "%.1f", gpuPer)) ms/帧｜补洞 \(String(format: "%.2f", holePct))%"
            + "｜归一化样本池 \(poolN) 个（实时没有整片 p1/p99，边播边攒）"
            + errLine
        if Thread.isMainThread { label?.text = text }
        else { DispatchQueue.main.async { [weak self] in self?.label?.text = text } }
    }

    private func finish(_ extra: String) {
        requestStop()
        audio?.stop()
        if let lay = layer { lay.flush() }
        let wall = Double(DispatchTime.now().uptimeNanoseconds - clock0) / 1_000_000_000.0
        dLock.lock()
        let takes = depthTakes
        let err = depthErr
        dLock.unlock()
        var rep = "实时 收兵：出帧 \(frames) 帧、跑了 \(String(format: "%.1f", wall)) s"
            + "｜深度 \(takes) 次｜形变 \(String(format: "%.1f", frames > 0 ? gpuSum / Double(frames) : 0)) ms/帧"
            + "｜足迹 \(VRFacts.footprintMB()) MB"
        if !note.isEmpty { rep += "｜\(note)" }
        if !extra.isEmpty { rep += "｜\(extra)" }
        if !err.isEmpty { rep += "｜深度错 \(err)" }
        VRJournal.line(rep)
        VRLive.door.lock()
        VRLive.inside = false
        if VRLive.current === self { VRLive.current = nil }
        VRLive.door.unlock()
        let text = rep
        DispatchQueue.main.async { [weak self] in self?.onEnd?(text) }
    }
}

// MARK: - 播放页的界面

/// 实时播放那页的宿主：根层就是 AVSampleBufferDisplayLayer，上面盖一层点播才出现的控制条
struct VRLiveHost: UIViewRepresentable {
    let url: URL
    let eyeLong: Int
    let bpct: Float
    let units: MLComputeUnits
    let rot: Bool
    let onEnd: (String) -> Void

    func makeUIView(context: Context) -> VRLiveView {
        let v = VRLiveView()
        let live = VRLive(url: url, eyeLong: eyeLong, bpct: bpct, zp: 0.15, smooth: 0.4,
                          units: units, rot: rot)
        let cb = onEnd
        live.onEnd = cb
        context.coordinator.live = live
        v.attach(live)
        // 起手（Metal + 模型加载）要两三秒，不抱着主线程：后台起，起不来把原因交回界面顺手关掉这页
        DispatchQueue.global(qos: .userInitiated).async { [weak v] in
            guard let vv = v else { return }
            let err = live.start(layer: vv.displayLayer, label: vv.stats)
            guard !err.isEmpty else { return }
            DispatchQueue.main.async {
                vv.stats.text = err
                cb(err)
            }
        }
        return v
    }

    func updateUIView(_ v: VRLiveView, context: Context) {
        if let l = context.coordinator.live { v.attach(l) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ v: VRLiveView, coordinator: Coordinator) {
        v.teardown()
    }

    final class Coordinator {
        var live: VRLive?
    }
}

/// 相册里那条已经是左右眼的成片：直接交给系统播放器，进度条、点播出现这些它本来就带得最全
struct VRPlainPlayerHost: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController()
        c.player = AVPlayer(url: url)
        c.player?.play()
        return c
    }

    func updateUIViewController(_ c: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ c: AVPlayerViewController, coordinator: Void) {
        c.player?.pause()
    }
}

/// 实时播放的容器视图：底下上屏、顶上三行实测、底下一条点播才出现的控制栏
final class VRLiveView: UIView {
    /// 顶部实测那几行（一直显示，测速要看）
    let stats = UILabel()
    private var live: VRLive?
    private let tapCatch = UIView()
    private let bar = UIView()
    private let playBtn = UIButton(type: .system)
    private let seekSl = UISlider()
    private let timeLbl = UILabel()
    private let shiftSl = UISlider()
    private let shiftLbl = UILabel()
    private let hintLbl = UILabel()
    private var ticker: Timer?
    private var hider: Timer?
    private var dragging = false
    private var shown = false

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = false
        // 显示层的这两样在这里定，不放 setup()：setup 跑在后台线程，图层配置该在主线程做
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        tapCatch.backgroundColor = .clear
        addSubview(tapCatch)
        stats.numberOfLines = 0
        stats.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        stats.textColor = .systemGreen
        stats.backgroundColor = UIColor(white: 0, alpha: 0.45)
        addSubview(stats)
        bar.backgroundColor = UIColor(white: 0, alpha: 0.6)
        bar.layer.cornerRadius = 12
        bar.isHidden = true
        addSubview(bar)
        playBtn.setTitle("暂停", for: .normal)
        playBtn.setTitleColor(.white, for: .normal)
        playBtn.backgroundColor = UIColor(white: 1, alpha: 0.16)
        playBtn.layer.cornerRadius = 8
        playBtn.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        bar.addSubview(playBtn)
        seekSl.tintColor = .systemGreen
        seekSl.minimumValue = 0
        seekSl.maximumValue = 1
        bar.addSubview(seekSl)
        timeLbl.textColor = .white
        timeLbl.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLbl.textAlignment = .right
        bar.addSubview(timeLbl)
        shiftSl.tintColor = .systemOrange
        shiftSl.minimumValue = -0.12
        shiftSl.maximumValue = 0.12
        bar.addSubview(shiftSl)
        shiftLbl.textColor = .white
        shiftLbl.font = UIFont.systemFont(ofSize: 12)
        bar.addSubview(shiftLbl)
        hintLbl.textColor = UIColor(white: 1, alpha: 0.6)
        hintLbl.font = UIFont.systemFont(ofSize: 10)
        hintLbl.text = "上面那条拖进度｜下面那条调左右眼水平位置（对镜片中心，存下来下次照用）"
        bar.addSubview(hintLbl)
        tapCatch.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        playBtn.addTarget(self, action: #selector(tappedPlay), for: .touchUpInside)
        seekSl.addTarget(self, action: #selector(seekStart), for: .touchDown)
        seekSl.addTarget(self, action: #selector(seekMoved), for: .valueChanged)
        seekSl.addTarget(self, action: #selector(seekEnd), for: [.touchUpInside, .touchUpOutside, .cancel])
        shiftSl.addTarget(self, action: #selector(shiftMoved), for: .valueChanged)
        shiftSl.addTarget(self, action: #selector(shiftEnd), for: [.touchUpInside, .touchUpOutside, .cancel])
    }

    required init?(coder: NSCoder) { fatalError("这块不用 xib") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        tapCatch.frame = bounds
        // 右边留出 100 pt：那格是 SwiftUI 那枚「停止」的落点，别把实测那几行铺到它底下去
        stats.frame = CGRect(x: 6, y: 6, width: max(40, w - 112), height: 56)
        let bh: CGFloat = 132
        bar.frame = CGRect(x: 6, y: h - bh - 6, width: max(40, w - 12), height: bh)
        let bw = bar.bounds.width
        playBtn.frame = CGRect(x: 8, y: 14, width: 56, height: 32)
        timeLbl.frame = CGRect(x: bw - 118, y: 14, width: 110, height: 32)
        seekSl.frame = CGRect(x: 72, y: 20, width: max(30, bw - 72 - 126), height: 22)
        shiftLbl.frame = CGRect(x: 8, y: 58, width: 118, height: 30)
        shiftSl.frame = CGRect(x: 130, y: 62, width: max(30, bw - 130 - 12), height: 22)
        hintLbl.frame = CGRect(x: 8, y: 96, width: max(40, bw - 16), height: 30)
    }

    /// 起好的一条交进来（同一条重复交不做任何事）
    func attach(_ l: VRLive) {
        guard live !== l else { return }
        live = l
        seekSl.maximumValue = Float(max(1.0, l.duration))
        seekSl.value = 0
        // attach 比 setup 早到，那条上存着的还是 0 ⇒ 位移直接读存档，跟 setup 用的是同一档
        shiftSl.value = Float(max(-0.12, min(0.12, VRLive.storedShiftPct)))
        shiftLbl.text = shiftText(Double(shiftSl.value))
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// 页面收走：线程必须停，不然 inside 一直占着，全片和下一条实时都起不来
    func teardown() {
        ticker?.invalidate()
        ticker = nil
        hider?.invalidate()
        hider = nil
        live?.requestStop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    @objc private func tapped() { showControls(!shown) }

    @objc private func tappedPlay() {
        guard let l = live else { return }
        l.setPaused(!l.isPausedNow)
        refresh()
        armHide()
    }

    @objc private func seekStart() { dragging = true }

    @objc private func seekMoved() {
        guard dragging else { return }
        timeLbl.text = fmt(Double(seekSl.value)) + " / " + fmt(live?.duration ?? 0)
    }

    @objc private func seekEnd() {
        dragging = false
        live?.seek(to: Double(seekSl.value))
        refresh()
        armHide()
    }

    @objc private func shiftMoved() {
        shiftLbl.text = shiftText(Double(shiftSl.value))
    }

    /// 位移只在松手这一下落地：每变一次显示线程要抹一轮缓冲，拖着Continuous 发就是白白抹几十次
    @objc private func shiftEnd() {
        live?.setShift(Double(shiftSl.value))
        shiftLbl.text = shiftText(Double(shiftSl.value))
        armHide()
    }

    private func shiftText(_ pct: Double) -> String {
        "水平 " + String(format: "%+.1f%%", pct * 100)
    }

    private func fmt(_ t: Double) -> String {
        let s = Int(max(0, t).rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func showControls(_ on: Bool) {
        shown = on
        bar.isHidden = !on
        ticker?.invalidate()
        ticker = nil
        hider?.invalidate()
        hider = nil
        guard on else { return }
        refresh()
        // .common 模式：拖着滑杆（tracking 模式）的时候也得照常刷新、照常收起来
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        armHide()
    }

    /// 控件出来 4 秒没动静就自己收回去；暂停着不收——那正是停下来慢慢调的时候
    private func armHide() {
        hider?.invalidate()
        guard shown else { return }
        let t = Timer(timeInterval: 4.0, repeats: false) { [weak self] _ in
            guard let s = self, s.shown, s.live?.isPausedNow == false else { return }
            s.showControls(false)
        }
        RunLoop.main.add(t, forMode: .common)
        hider = t
    }

    private func refresh() {
        guard let l = live else { return }
        let dur = max(1.0, l.duration)
        if abs(seekSl.maximumValue - Float(dur)) > 0.5 { seekSl.maximumValue = Float(dur) }
        let p = l.position
        if !dragging { seekSl.value = Float(min(max(0, p), dur)) }
        timeLbl.text = fmt(p) + " / " + fmt(l.duration)
        playBtn.setTitle(l.isPausedNow ? "播放" : "暂停", for: .normal)
    }
}
