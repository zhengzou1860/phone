import AVFoundation
import CoreMedia
import CoreML
import Foundation
import SwiftUI
import UIKit

/// 实时左右眼：相册里选一条普通视频，边解码边形变边直接上屏，不写文件、不进相册。
/// sbs=true 是同一套骨架的另一副面孔：相册里那条本身已是左右眼，深度和形变都不跑，
/// 只在各自半幅里做水平平移，暂停/拖进度/出声/横屏这些跟实时那条完全一致。
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
    /// 两图之间的距离存这一档：眼镜的镜片间距是硬件定的，一次对好就一直用（没存过＝0＝两半正好挨在中缝）
    static let gapKey = "vr3d.live.gap"
    static var storedGapPct: Double { UserDefaults.standard.double(forKey: gapKey) }
    /// 鱼眼强度存这一档：镜片是硬件，弯多少一次对好就一直用（0~1；0＝不弯＝手持直看）。
    /// 弯的是像素不是画框：画面外圈挤向中心，直边的中段才看着往外弓，而且源图一个像素都不裁（见 kSbsFish）。
    static let fishKey = "vr3d.live.fish"
    static let fishMax: Double = 1.0
    /// 没存过默认 0.35：这页本来就是塞进眼镜里看的，第一次进来就该是镜片里那个样子
    static var storedFish: Double {
        UserDefaults.standard.object(forKey: fishKey) == nil ? 0.35 : UserDefaults.standard.double(forKey: fishKey)
    }

    let url: URL
    let eyeLong: Int
    let bpct: Float
    let zp: Float
    let smooth: Float
    let units: MLComputeUnits
    let rot: Bool
    /// 相册里那条本身已是左右眼：不跑深度不形变，只按半幅水平平移，进度/暂停/位移这些照旧
    let sbs: Bool
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
    /// 深度那张图到底按什么读法读的（16 位=半浮点还是整数）：只报一次，好跟上机日志对账
    private var depthFmt = ""
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
    /// 两图之间的距离（占每眼宽的比例）：正=两只眼互相离远（中缝多出黑带来），负=互相靠近；
    /// 每张图自己多大始终不动，也永不越过中缝 ⇒ 这个旋钮只改距离，不改大小、不串眼
    private var gapPct: Float = 0
    /// 鱼眼强度（0~1，0=不弯）：只作用在上屏那一趟，深度和成片都不碰它
    private var fishPct: Float = 0
    /// 位移/间距/鱼眼每变一次 +1：显示线程看到它变了先把 6 块显示缓冲抹一次黑、再把静止这帧重画
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
    /// 只有 sbs 那条用：整幅左右眼的半幅平移
    private var shift: VRSbsShift?
    private var stream: VRFrameStream?
    private var framePB: CVPixelBuffer?
    private var handPB: CVPixelBuffer?
    private var showPBs: [CVPixelBuffer] = []
    private var fmtDesc: CMFormatDescription?
    private var layer: AVSampleBufferDisplayLayer?
    /// 声音：只能走 AVPlayer。AVAudioPlayer 认的是 CAF/WAV/MP3/M4A 这类纯音频文件，
    /// 相册里这条是 .mov（QuickTime 容器），0.18/0.19 两次日志都是「AVAudioPlayer 建不出来」⇒ 那不是类别没配，是这个类压根读不了。
    private var audio: AVPlayer?
    private weak var label: UILabel?

    private var note = ""
    private var frames = 0
    private var holes = 0.0
    private var gpuSum = 0.0
    private var clock0 = UInt64(0)

    init(url: URL, eyeLong: Int, bpct: Float, zp: Float, smooth: Float,
         units: MLComputeUnits, rot: Bool, sbs: Bool = false) {
        self.url = url
        self.eyeLong = eyeLong
        self.bpct = bpct
        self.zp = zp
        self.smooth = smooth
        self.units = units
        self.rot = rot
        self.sbs = sbs
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
            a.seek(to: CMTime(seconds: t, preferredTimescale: 600))
            if !hold { a.play() }
        }
    }

    /// 两张图一起水平移（±12% 每眼宽封顶，对镜片中心用）。滑杆松手才调这里，一次抹一次缓冲
    func setShift(_ pct: Double) {
        let v = Float(max(-0.12, min(0.12, pct)))
        dLock.lock()
        if abs(v - shiftPct) < 1e-4 { dLock.unlock(); return }
        shiftPct = v
        shiftSeq += 1
        dLock.unlock()
        UserDefaults.standard.set(Double(v), forKey: VRLive.shiftKey)
        VRJournal.line("实时 一起移 \(String(format: "%+.1f", Double(v) * 100))%")
    }

    /// 两图之间的距离（±25% 每眼宽封顶）：只把两张图互相推远/拉近，各自大小不动。
    /// 和位移一样松手才落地：一变就要重画一轮，拖着连续发等于白白重画几十轮
    func setGap(_ pct: Double) {
        let v = Float(max(-0.25, min(0.25, pct)))
        dLock.lock()
        if abs(v - gapPct) < 1e-4 { dLock.unlock(); return }
        gapPct = v
        shiftSeq += 1
        dLock.unlock()
        UserDefaults.standard.set(Double(v), forKey: VRLive.gapKey)
        VRJournal.line("实时 间距 \(String(format: "%+.1f", Double(v) * 100))%")
    }

    /// 鱼眼强度（0~1）：把每只眼那半幅按桶形往中心挤一遍，戴镜看直边就往外弓，内容一个像素不裁。
    /// 落地方式跟位移、间距一样松手才发：变一次要重画一轮；出片那条完全不受它影响
    func setFish(_ pct: Double) {
        let v = Float(max(0, min(VRLive.fishMax, pct)))
        dLock.lock()
        if abs(v - fishPct) < 1e-4 { dLock.unlock(); return }
        fishPct = v
        shiftSeq += 1
        dLock.unlock()
        UserDefaults.standard.set(Double(v), forKey: VRLive.fishKey)
        VRJournal.line("实时 鱼眼 \(String(format: "%.0f", Double(v) * 100))%")
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
        if !sbs {
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in self?.depthPump() }
        }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in self?.pump() }
        return ""
    }

    private func setup() -> String {
        guard VRTech.boot() else { return "Metal 起不来：\(VRTech.initNote)" }
        // 出声的开关必须在起 AVAudioPlayer 之前调好，不然那条还是按默认类别被静音拨片管着
        VRSound.enable(sbs ? "左右眼原样" : "实时形变")
        guard let s = VRSource(url: url, eyeLong: eyeLong, sbs: sbs) else {
            return "读不出这条片子（详情见磁盘日志）"
        }
        src = s
        var modelTag = ""
        var depthTag = ""
        var fn = ""
        if sbs {
            // 这一条整趟不碰 CoreML：深度、形变、送检框一样都不建，起得比实时那条快得多
            guard let sh = VRSbsShift(frameW: s.frameW, frameH: s.frameH, eyeW: s.eyeW,
                                      note: &fn) else {
                return "左右眼平移建不起来：\(fn)"
            }
            shift = sh
        } else {
            let found = VRDepth.locate()
            guard let modelURL = found.url else { return "包里没有深度模型：\(found.note)" }
            let got = VRDepth.load(units)
            guard let model = got.model else {
                return "\(VRPilot.unitsName(units)) 加载失败（\(VRUtil.ms(got.ms))）: \(got.note)"
            }
            let tgt = VRDepth.inputTarget(model, eyeW: s.eyeW, eyeH: s.eyeH)
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
            modelTag = "｜\(modelURL.lastPathComponent)"
            depthTag = "｜\(VRPilot.unitsName(units)) 送检 \(tgt.w)x\(tgt.h)"
        }
        guard let st = VRFrameStream(src: s) else { return "顺序解码起不来（startReading 失败）" }
        stream = st
        guard let a = VRTech.pixelBuffer(width: s.frameW, height: s.frameH).pb else {
            return "帧缓冲造不出来"
        }
        framePB = a
        if !sbs {
            // 交接给深度线程的那一块只有实时那条要：sbs 那条不跑深度，白占一整帧内存
            guard let b = VRTech.pixelBuffer(width: s.frameW, height: s.frameH).pb else {
                return "送检交接缓冲造不出来"
            }
            handPB = b
        }
        // 显示缓冲按轮转用固定的 6 份：每帧新造的话，纹理缓存里会一份一份攒着不回来（全片实测 1.65 MB/帧）
        // ⚠️ 上屏这一份的宽不跟 s.frameW 走：实时那条是形变把两只眼并排写出来，宽 = 每眼 ×2；
        // 只有 sbs 那条整幅本来就带着两只眼。0.18 我把这里统一写成 s.frameW（=每眼宽），
        // VRWarp 照样按 2×每眼 去建纹理，手上却是半宽的缓冲 ⇒ 第 1 帧就 -6684，整页退回主页像闪退（11-06 15:34 实测）。
        let outW = sbs ? s.frameW : s.eyeW * 2
        let outH = sbs ? s.frameH : s.eyeH
        for _ in 0..<6 {
            guard let pb = VRTech.pixelBuffer(width: outW, height: outH).pb else {
                return "显示缓冲造不出来（已造 \(showPBs.count) 份）"
            }
            if fmtDesc == nil {
                var fd: CMFormatDescription?
                if CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                imageBuffer: pb,
                                                                formatDescriptionOut: &fd) == noErr {
                    fmtDesc = fd
                }
            }
            showPBs.append(pb)
        }
        guard fmtDesc != nil else { return "显示缓冲的格式描述建不出来" }
        duration = s.duration
        // 上一轮对镜片对出来的位移、对出来的间距直接续上
        dLock.lock()
        shiftPct = Float(max(-0.12, min(0.12, VRLive.storedShiftPct)))
        gapPct = Float(max(-0.25, min(0.25, VRLive.storedGapPct)))
        fishPct = Float(max(0, min(VRLive.fishMax, VRLive.storedFish)))
        dLock.unlock()
        // 声音尽力而为：起不来就退回墙钟，画面照走
        if let p = soundPlayer() {
            audio = p
        }
        let audioName = audio == nil ? "没有（走墙钟）" : "接上（走声钟）"
        let shiftName = String(format: "%+.1f", Double(shiftPct) * 100)
        let gapName = String(format: "%+.1f", Double(gapPct) * 100)
        let fishTag = "鱼眼\(String(format: "%.0f", VRLive.storedFish * 100))%"
        // 这块是在后台线程跑的： UILabel 只能主线程碰，起手那行也一样交回主线程写
        // 「上屏」那对数才是真正进眼睛的尺寸：实时形变拼出来的是 每眼×2，sbs 那条就是原片整幅
        let headName = sbs ? "左右眼原样起手" : "实时起手"
        let startLine = "\(headName)：每眼 \(s.eyeW)x\(s.eyeH)｜上屏 \(outW)x\(outH)"
            + "｜\(String(format: "%.1f", s.fps)) fps\(depthTag)\(modelTag)"
            + "｜声音\(audioName)｜一起移\(shiftName)% 间距\(gapName)%\(fishTag)｜点屏幕出控件"
        DispatchQueue.main.async { [weak self] in self?.label?.text = startLine }
        let modeTag = sbs ? "左右眼原样（不跑深度）" : "实时形变 视差\(bpct)% zp\(zp) 朝向\(rot ? "转90°" : "摆正")"
        VRJournal.line("播放 开始 \(url.lastPathComponent) \(modeTag) 每眼 \(s.eyeW)x\(s.eyeH)"
            + " 上屏 \(outW)x\(outH) \(String(format: "%.1f", s.fps)) fps"
            + " 一起移\(shiftName)% 间距\(gapName)% \(fishTag)")
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
                if depthFmt.isEmpty { depthFmt = r.plane.fmt }
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

    /// 显示线程：解码→（形变｜半幅平移）→上屏，按帧号排节奏；
    /// 界面发的暂停/拖进度/一起移/间距都在这一圈里落。sbs 那条深度整趟不参与。
    private func pump() {
        guard let s = src, let f = framePB, let lay = layer, let st = stream else {
            finish("实时 内部状态没建起来（setup 提前退了）")
            return
        }
        let w = warp
        let sh = shift
        if sbs {
            guard sh != nil else { finish("左右眼原样：平移那趟没建起来"); return }
        } else {
            guard w != nil else { finish("实时：形变那趟没建起来"); return }
        }
        // sbs 那条根本不碰深度：两块眼格数组留空，别白占 0.66 MB
        let px = sbs ? 0 : s.eyeW * s.eyeH
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
        playAudio()
        while true {
            dLock.lock()
            let go = running
            let sd = seekTo
            let hold = paused
            let wantSeq = shiftSeq
            let xo = shiftPct * eyeWf
            let gp = gapPct * eyeWf
            let fh = 2.0 * fishPct
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
                if !sbs {
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
            }
            let outPB = showPBs[n % showPBs.count]
            var gpuMs = 0.0
            if sbs {
                let rr = sh!.render(srcPB: f, xoff: xo, gap: gp, fish: fh, outPB: outPB)
                if let e = rr.err { note = "第 \(k + 1) 帧平移失败：\(e)"; break }
                gpuMs = rr.gpu
            } else {
                let rr = w!.render(srcPB: f, dn: dn, zp: zp, xoff: xo, gap: gp, fish: fh, outPB: outPB)
                if let e = rr.err { note = "第 \(k + 1) 帧形变失败：\(e)"; break }
                gpuMs = rr.gpu
                holes += rr.holes
            }
            guard let sb = sample(outPB, k: n, fps: fps) else { note = "第 \(k + 1) 帧的显示样本造不出来"; break }
            lay.enqueue(sb)
            if lay.status == .failed {
                note = "显示层出错：\(lay.error?.localizedDescription ?? "-")"
                break
            }
            n += 1
            // 停住期间只有刚拖完位移、间距或鱼眼那一下走到这里：把静止这一帧按新数值重画一遍就回去
            if hold { Thread.sleep(forTimeInterval: 1.0 / fps); continue }
            gpuSum += gpuMs
            k += 1
            frames = k
            dLock.lock(); posSeen = t0sec + Double(k) / fps; dLock.unlock()
            pace(k: k, fps: fps)
            if k % 30 == 0 { stat(fps: fps) }
        }
        st.close()
        finish("")
    }

    /// 用 AVPlayer 出这条片子的声音：不挂 AVPlayerLayer 就是不画视频，只出声，
    /// 画面仍由我们自己那条解码器管。音轨在不在、时长多少都留一行账，好跟「类别没配上」分清。
    private func soundPlayer() -> AVPlayer? {
        let asset = AVURLAsset(url: url)
        let na = asset.tracks(withMediaType: .audio).count
        let d = CMTimeGetSeconds(asset.duration)
        guard na > 0 else {
            VRJournal.line("声音 这条没有音轨（音频轨 0 条），走墙钟")
            return nil
        }
        let p = AVPlayer(url: url)
        p.isMuted = false
        VRJournal.line("声音 AVPlayer 起用 音频轨 \(na) 条 素材时长"
            + "\(String(format: "%.1f", d.isFinite ? d : -1)) s")
        return p
    }

    /// 起音频。这一步能不能出声是这版最要紧的一件事，所以每一支都留一行账：
    /// 类别没配上（VRSound 那行）、player 没建起来（soundPlayer 那行）、play() 后 rate 还是 0（这行）三样分开看。
    private func playAudio() {
        guard let p = audio else {
            VRJournal.line("声音 没有 player，这一条走墙钟")
            return
        }
        p.play()
        let at = CMTimeGetSeconds(p.currentTime())
        VRJournal.line("声音 play() 后 rate \(p.rate) 位置 \(String(format: "%.2f", at.isFinite ? at : -1)) s"
            + " 静音\(p.isMuted ? "是" : "否")")
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
        // 拖完进度，交接给深度线程的那一帧是旧位置的 ⇒ 丢掉，别让拖完的头一帧拿它做立体
        handPending = false
        let hold = paused
        dLock.unlock()
        clock0 = DispatchTime.now().uptimeNanoseconds
        lay.flush()
        if !hold {
            audio?.seek(to: CMTime(seconds: t, preferredTimescale: 600))
            playAudio()
        }
        let acSec = audio.map { CMTimeGetSeconds($0.currentTime()) } ?? -1
        let acPos = String(format: "%.1f", acSec.isFinite ? acSec : -1)
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
        let ts = Int32(max(1.0, fps * 1000.0))
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: ts),
                                        presentationTimeStamp: CMTime(value: Int64(k), timescale: ts),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        // CMSampleBufferCreateReady 压根没有 imageBuffer 这一项（CI 报的 extra argument）；
        // 从像素缓冲起样本要用带 ForImageBuffer 的那条，八项标签一个都不能少
        let st = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                    imageBuffer: pb,
                                                    dataReady: true,
                                                    makeDataReadyCallback: nil,
                                                    refcon: nil,
                                                    formatDescription: fd,
                                                    sampleTiming: &timing,
                                                    sampleBufferOut: &sb)
        return st == noErr ? sb : nil
    }

    /// 有声音跟声钟，没声音跟墙钟。落后了就继续走（顺序解码器 seek 一次 54 ms，不划算），滞后写进统计。
    /// 两边都对到 t0sec 这个起点上：拖完进度 t0sec 变了，暂停那段由 pausedAccum 扣掉。
    private func pace(k: Int, fps: Double) {
        dLock.lock()
        let base = t0sec
        let acc = pausedAccum
        dLock.unlock()
        let target = base + Double(k) / fps
        let now: Double
        // rate>0 才算在放（AVPlayer 播到头 rate 归 0，那时退回墙钟，别让画面卡在最后一帧等一个不来的钟）
        if let p = audio, p.rate > 0 {
            let s = CMTimeGetSeconds(p.currentTime())
            now = s.isFinite ? s : target
        } else {
            now = base + Double(DispatchTime.now().uptimeNanoseconds &- clock0) / 1_000_000_000.0 - acc
        }
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
        let fmt = depthFmt
        dLock.unlock()
        let shown = Double(frames) / secs
        let gpuPer = frames > 0 ? gpuSum / Double(frames) : 0.0
        let text: String
        if sbs {
            text = "左右眼原样 出帧 \(frames)＝\(String(format: "%.1f", shown)) 帧/秒（源 \(String(format: "%.1f", fps))）"
                + "\n平移 \(String(format: "%.1f", gpuPer)) ms/帧｜不跑深度：屏上就是相册里那两个半幅"
                + "\n拖下面那条只在各半幅里挪，绝不跨过接缝（串眼的脏边会落在视场正中）"
        } else {
            let hz = Double(takes) / secs
            let holePct = frames > 0 ? holes / Double(frames) : 0.0
            let errLine = err.isEmpty ? "" : "\n深度出错 \(err)（连续 3 次就不算了，画面退回平板）"
                + (takes == 0 ? "\n一次深度都没算成：屏上这条是平的，没有立体" : "")
            text = "实时 出帧 \(frames)＝\(String(format: "%.1f", shown)) 帧/秒（源 \(String(format: "%.1f", fps))）"
                + "\n深度更新 \(takes) 次＝\(String(format: "%.1f", hz)) 次/秒、单价 \(String(format: "%.0f", avgD)) ms"
                + "｜其余 \(frames - takes) 帧复用上一张"
                + "\n形变 \(String(format: "%.1f", gpuPer)) ms/帧｜补洞 \(String(format: "%.2f", holePct))%"
                + "｜归一化样本池 \(poolN) 个（实时没有整片 p1/p99，边播边攒）"
                + (fmt.isEmpty || takes == 0 ? "" : "\n深度读法 \(fmt)")
                + errLine
        }
        if Thread.isMainThread { label?.text = text }
        else { DispatchQueue.main.async { [weak self] in self?.label?.text = text } }
    }

    private func finish(_ extra: String) {
        requestStop()
        // AVPlayer 没有 stop()：pause 完再撒手，让那条音频解码器跟着释放
        audio?.pause()
        audio = nil
        if let lay = layer { lay.flush() }
        let wall = Double(DispatchTime.now().uptimeNanoseconds - clock0) / 1_000_000_000.0
        dLock.lock()
        let takes = depthTakes
        let err = depthErr
        let fmt = depthFmt
        let fish = fishPct
        dLock.unlock()
        var rep = "\(sbs ? "左右眼原样" : "实时") 收兵：出帧 \(frames) 帧、跑了 \(String(format: "%.1f", wall)) s"
        if sbs {
            rep += "｜平移 \(String(format: "%.1f", frames > 0 ? gpuSum / Double(frames) : 0)) ms/帧"
        } else {
            rep += "｜深度 \(takes) 次｜形变 \(String(format: "%.1f", frames > 0 ? gpuSum / Double(frames) : 0)) ms/帧"
                + "｜补洞 \(String(format: "%.2f", frames > 0 ? holes / Double(frames) : 0))%"
        }
        rep += "｜足迹 \(VRFacts.footprintMB()) MB"
        if !note.isEmpty { rep += "｜\(note)" }
        if !extra.isEmpty { rep += "｜\(extra)" }
        if !err.isEmpty { rep += "｜深度错 \(err)" }
        if takes > 0 && !fmt.isEmpty { rep += "｜深度读法 \(fmt)" }
        rep += "｜鱼眼 \(String(format: "%.0f", Double(fish) * 100))%"
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

/// 实时播放的容器视图：自己这一层上屏，点播才出控制栏（实测那几行跟着它一起出）
final class VRLiveView: UIView {
    /// 实测那几行：平时不收眼睛看，点播跟控制栏一起出来（横屏戴镜时它一直亮着最碍事）
    let stats = UILabel()
    private var live: VRLive?
    private let tapCatch = UIView()
    private let bar = UIView()
    private let playBtn = UIButton(type: .system)
    private let seekSl = UISlider()
    private let timeLbl = UILabel()
    private let shiftSl = UISlider()
    private let shiftLbl = UILabel()
    private let gapSl = UISlider()
    private let gapLbl = UILabel()
    private let fishSl = UISlider()
    private let fishLbl = UILabel()
    private let hintLbl = UILabel()
    private var ticker: Timer?
    private var hider: Timer?
    private var dragging = false
    private var shown = false

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    /// 上屏的就是这一层：整幅铺满，两图之间的距离由 GPU 在画面里挪，图层自己不缩
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    /// 间距滑杆的档位是「占每眼宽的百分比」，±25% 封顶：拉到 +25% 中缝空出半只眼的四分之一宽
    private let gapRange: Double = 0.25
    /// 鱼眼滑杆是强度 0~1（送进 GPU 折成 k=2·强度）：1 顶格时画面缩到半幅的七成半径，黑边最厚
    private let fishRange: Double = VRLive.fishMax

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = false
        // 这一样在 init 定，不放 setup()：setup 跑在后台线程，图层配置该在主线程做
        displayLayer.videoGravity = .resize
        tapCatch.backgroundColor = .clear
        addSubview(tapCatch)
        stats.numberOfLines = 0
        stats.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        stats.textColor = .systemGreen
        stats.backgroundColor = UIColor(white: 0, alpha: 0.45)
        stats.isHidden = true
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
        gapSl.tintColor = .systemPurple
        gapSl.minimumValue = Float(-gapRange)
        gapSl.maximumValue = Float(gapRange)
        bar.addSubview(gapSl)
        gapLbl.textColor = .white
        gapLbl.font = UIFont.systemFont(ofSize: 12)
        bar.addSubview(gapLbl)
        fishSl.tintColor = .systemTeal
        fishSl.minimumValue = 0
        fishSl.maximumValue = Float(fishRange)
        bar.addSubview(fishSl)
        fishLbl.textColor = .white
        fishLbl.font = UIFont.systemFont(ofSize: 12)
        fishLbl.textAlignment = .right
        bar.addSubview(fishLbl)
        hintLbl.textColor = UIColor(white: 1, alpha: 0.6)
        hintLbl.font = UIFont.systemFont(ofSize: 10)
        hintLbl.text = "第一条拖进度｜第二条「一起移」=两张图同方向挪，对准两只镜片中心｜第三条「间距」=把两张图互相推远或拉近，图本身大小不变（+ 拉开、中缝出黑边；− 靠近、外侧各裁一条）｜第四条「鱼眼」=把每只眼那半幅按镜片的桶形弯一遍：画面外圈挤向中心，直边的中段就往外弓，黑只落在画框外，源图一个像素都不裁（拉到 0＝不弯＝手持直看；顶格黑边最厚）｜这些都存下来下次照用"
        bar.addSubview(hintLbl)
        tapCatch.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        playBtn.addTarget(self, action: #selector(tappedPlay), for: .touchUpInside)
        seekSl.addTarget(self, action: #selector(seekStart), for: .touchDown)
        seekSl.addTarget(self, action: #selector(seekMoved), for: .valueChanged)
        seekSl.addTarget(self, action: #selector(seekEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        shiftSl.addTarget(self, action: #selector(shiftMoved), for: .valueChanged)
        shiftSl.addTarget(self, action: #selector(shiftEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        gapSl.addTarget(self, action: #selector(gapMoved), for: .valueChanged)
        gapSl.addTarget(self, action: #selector(gapEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        fishSl.addTarget(self, action: #selector(fishMoved), for: .valueChanged)
        fishSl.addTarget(self, action: #selector(fishEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    required init?(coder: NSCoder) { fatalError("这块不用 xib") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        tapCatch.frame = bounds
        // 右边留出 100 pt：那格是 SwiftUI 那枚「停止」的落点，别把实测那几行铺到它底下去
        // 高 120：起手那行要绕两三行，实测连「深度读法」「深度出错」一起最多六行，写死 56 会把尾巴裁掉
        stats.frame = CGRect(x: 6, y: 6, width: max(40, w - 112), height: 120)
        let bh: CGFloat = 206
        bar.frame = CGRect(x: 6, y: h - bh - 6, width: max(40, w - 12), height: bh)
        let bw = bar.bounds.width
        playBtn.frame = CGRect(x: 8, y: 14, width: 56, height: 32)
        timeLbl.frame = CGRect(x: bw - 118, y: 14, width: 110, height: 32)
        seekSl.frame = CGRect(x: 72, y: 20, width: max(30, bw - 72 - 126), height: 22)
        shiftLbl.frame = CGRect(x: 8, y: 56, width: 118, height: 30)
        shiftSl.frame = CGRect(x: 130, y: 60, width: max(30, bw - 130 - 12), height: 22)
        gapLbl.frame = CGRect(x: 8, y: 88, width: 118, height: 30)
        gapSl.frame = CGRect(x: 130, y: 92, width: max(30, bw - 130 - 12), height: 22)
        fishLbl.frame = CGRect(x: 8, y: 120, width: 118, height: 30)
        fishSl.frame = CGRect(x: 130, y: 124, width: max(30, bw - 130 - 12), height: 22)
        hintLbl.frame = CGRect(x: 8, y: 156, width: max(40, bw - 16), height: 46)
    }

    /// 起好的一条交进来（同一条重复交不做任何事）
    func attach(_ l: VRLive) {
        guard live !== l else { return }
        live = l
        seekSl.maximumValue = Float(max(1.0, l.duration))
        seekSl.value = 0
        // attach 比 setup 早到，那条上存着的还是 0 ⇒ 位移、间距直接读存档，跟 setup 用的是同一档
        shiftSl.value = Float(max(-0.12, min(0.12, VRLive.storedShiftPct)))
        shiftLbl.text = shiftText(Double(shiftSl.value))
        gapSl.value = Float(max(-gapRange, min(gapRange, VRLive.storedGapPct)))
        gapLbl.text = gapText(Double(gapSl.value))
        // 鱼眼这档也读存档：滑杆藏在控制栏里，但戴镜进来的第一眼就该已经是弯好的（setup 已经把同一档发给 GPU）
        fishSl.value = Float(max(0, min(fishRange, VRLive.storedFish)))
        fishLbl.text = fishText(Double(fishSl.value))
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

    @objc private func gapMoved() {
        gapLbl.text = gapText(Double(gapSl.value))
    }

    /// 间距和位移一样松手才落地：落一次显示线程重画一轮
    @objc private func gapEnd() {
        live?.setGap(Double(gapSl.value))
        gapLbl.text = gapText(Double(gapSl.value))
        armHide()
    }

    @objc private func fishMoved() {
        fishLbl.text = fishText(Double(fishSl.value))
    }

    /// 鱼眼跟位移、间距一样松手才落地：落一次显示线程重画一轮（存档和日志在 setFish 里记）
    @objc private func fishEnd() {
        let v = max(0, min(fishRange, Double(fishSl.value)))
        live?.setFish(v)
        fishLbl.text = fishText(v)
        armHide()
    }

    /// 到底那一格要说人话：它不是「弯得小一点」，是完全不弯
    private func fishText(_ v: Double) -> String {
        "鱼眼 " + (v < 0.005 ? "不弯" : String(format: "%.0f%%", v * 100))
    }

    private func shiftText(_ pct: Double) -> String {
        "一起移 " + String(format: "%+.1f%%", pct * 100)
    }

    private func gapText(_ pct: Double) -> String {
        "间距 " + String(format: "%+.1f%%", pct * 100)
    }

    private func fmt(_ t: Double) -> String {
        let s = Int(max(0, t).rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func showControls(_ on: Bool) {
        shown = on
        bar.isHidden = !on
        // 实测那几行跟着控制栏走：戴进眼镜里它一直亮着最碍事，点播要看的时候才给看
        stats.isHidden = !on
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
