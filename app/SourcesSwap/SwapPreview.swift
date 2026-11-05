import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreML
import CoreVideo
import Foundation
import UIKit
import Vision

/// 预览档：按目标表把画面里的 1–3 张目标脸各换成各自的替换脸。只看、不导出，手机侧一个字节的文件都不写。
///
/// 这一条为什么能一帧一帧地过：身份全在 ② 那一步归一化后的 512 维向量里、与帧无关，
/// 换一个人只要把 latent 换一下（几百字节，不读盘），所以一帧都不必缓存
/// ⇒ 长度上没有「超过 3 分钟就不行」那道墙。
///
/// 多人：检测本来就是一次出所有脸；身份只在一条轨迹开头算一次（新轨迹＝换人、出画再回来、切镜头），
/// 之后按上一格的框 IoU／中心距离接着认。一帧里有几张目标脸就各跑一次换脸网。
///
/// 每一帧的钱几乎全在那一张 30 GMAC 的换脸网上：其余各步（检测、裁 256、贴回）合起来只有几毫秒，
/// 而这一张按 CPU 跑是一秒到几秒一格 ⇒ 这一条链路的算力单元默认跟界面那格（0.40 起钉 CPU，可以手动换）。
/// 进链仍钉在 640 那一档：取样与回贴都按像素数走，小窗比成片便宜的就是这一截。
///
/// 减帧口径：解码不跳，只有每 1/16 秒挑最贴近的那一帧真换，其余帧沿用上一格画面。
/// 这一条是当场检测、没有整片对称平滑：边上会比成片抖。
final class SwapPreview {

    struct Cfg {
        var units: MLComputeUnits = .cpuOnly
        var unitsTxt = "CPU(cpuOnly)"
        var fpsTarget: Double = 16
        var minFacePx: Double = 40
        var longEdge = 640
    }

    /// 界面挂的口子：出画、点这一下的那句答案（只在被挡／开跑／停下时递，跑动中的逐秒实况不往这里走）、
    /// 进流水、停下来的那一句（连带这条素材的秒数＝滑杆的范围）
    var render: ((UIImage) -> Void)?
    var log: ((String) -> Void)?
    var onFinish: ((String, Double) -> Void)?
    /// 滑杆用的数字口径：（现在播到第几秒, 这条素材共几秒）。界面不许去解析上面那行字。
    var onProgress: ((Double, Double) -> Void)?
    /// 这一趟目标表装成什么样：只有整张表都验过、真开跑才回话
    var onPerson: ((String) -> Void)?

    private enum Outcome { case stop, ended, seek(Double) }

    private static let ci = CIContext(options: [.cacheIntermediates: false])

    private let q = DispatchQueue(label: "swap.preview")
    private let lock = NSLock()
    private var stopping = false
    private var seekTo: Double?
    private var pendingCast: [SwapCastMember] = []
    private var cfg = Cfg()
    private var busy = false

    // 下面这些只在 q 那条线程上读写，界面不许碰
    private var engine: FsxEngine?
    private var engineUnits: MLComputeUnits?
    private var usedMember = -1
    private var rep: [String] = []
    private var work: CVPixelBuffer?
    private var held: CVPixelBuffer?
    private var frameW = 0, frameH = 0
    private var att = [Float](), face = [Float]()
    private var c112 = [Float](repeating: 0, count: 3 * FsxGeo.side112 * FsxGeo.side112)
    private var pasteScratch = FsxGeo.PasteScratch()
    private var decodeMs: [Double] = [], detectMs: [Double] = [], warpMs: [Double] = []
    private var frameMs: [Double] = [], pasteMs: [Double] = [], swapMs: [Double] = []
    private var nSwap = 0, nFaces = 0, nDecode = 0, noFace = 0, unmatched = 0
    private var smallFace = 0, mirror = 0, fitFail = 0, netFail = 0, nTracks = 0
    /// 被手性闸门挡下的帧分两拨：点是从 Vision 五官来的、还是只按脸框猜的
    private var mirrorReal = 0, mirrorGuess = 0
    /// 画面停住（这一格没换新东西）的最长一段素材秒数、和超过 0.25 s 的次数：卡顿先量出来再说话
    private var gapN = 0, gapMax = 0.0
    private var pointSrc = "—"
    private var duration = 0.0

    private struct PTrack {
        var id: Int
        var member: Int
        var cos: Double
        var lastBox: CGRect
        var lastTick: Int
        var samples: Int
        var sampleAt: Int
    }

    private struct PFace {
        var pl: FsxGeo.Placed
        var member: Int
    }

    // MARK: - 界面进来的三条口

    /// 起一趟预览。返回 ""＝已经开跑；否则是当场拒绝的理由。
    /// 目标表就是这一刻定下来的，一整趟不换：要改是「停预览」→改表→再「开始预览」。
    func start(video: URL, members: [SwapCastMember], cfg newCfg: Cfg) -> String {
        lock.lock()
        if busy { lock.unlock(); return "预览正跑着，先点「停预览」" }
        guard FileManager.default.fileExists(atPath: video.path) else {
            lock.unlock()
            return "②那份视频副本上一趟已经还掉了，重新点②选一条"
        }
        guard !members.isEmpty else {
            lock.unlock()
            return "目标表是空的：先上传目标人脸图片，再给它选一张替换脸"
        }
        for (i, m) in members.enumerated() {
            let tn = FsxEngine.norm(m.targetEmb), sn = FsxEngine.norm(m.sourceEmb)
            if m.targetEmb.count != FsxNets.embDim || tn <= 0.5 {
                lock.unlock()
                return "目标\(i + 1) 的特征用不了（\(m.targetEmb.count) 维／模长 \(String(format: "%.3f", tn))），重新选那张目标照片"
            }
            if m.sourceEmb.count != FsxNets.embDim || sn <= 0.5 {
                lock.unlock()
                return "目标\(i + 1) 的替换脸「\(m.sourceLabel)」用不了（\(m.sourceEmb.count) 维／模长 \(String(format: "%.3f", sn))），重新选一个替换脸"
            }
        }
        cfg = newCfg
        stopping = false
        seekTo = nil
        pendingCast = members
        busy = true
        lock.unlock()
        q.async { [weak self] in self?.drive(video: video) }
        return ""
    }

    func stop() { lock.lock(); stopping = true; lock.unlock() }

    /// 拖滑杆：重开 reader 跳到那一秒（预览不缓存画面，拖回去就是把那一秒重算一遍）
    func seek(_ sec: Double) { lock.lock(); seekTo = max(0, sec); lock.unlock() }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return busy
    }

    private func snapCfg() -> Cfg {
        lock.lock()
        defer { lock.unlock() }
        return cfg
    }

    private func snapCast() -> [SwapCastMember] {
        lock.lock()
        defer { lock.unlock() }
        return pendingCast
    }

    // MARK: - 跑

    /// 只有拖进度条要重开一趟 pass（换 reader 跳到那一秒）
    private func drive(video: URL) {
        rep = []      // 一趟一份报告：不清就会把上一趟的整份日志背在身上，越跑越长
        let cast = snapCast()
        var sec = 0.0
        while true {
            let r = pass(video: video, fromSec: sec, cast: cast)
            var again = true
            switch r {
            case .stop, .ended:
                again = false
            case .seek(let s):
                sec = s
            }
            if !again {
                finishRun(r)
                return
            }
        }
    }

    private func finishRun(_ r: Outcome) {
        lock.lock(); busy = false; pendingCast = []; lock.unlock()
        // 停下来的那一刻把两张网和两块整幅缓冲交回去：出片那条自己还要装一份引擎，
        // 预览留着不放就是把下一次「开始换脸」顶到它自己的足迹闸门上
        engine = nil
        engineUnits = nil
        usedMember = -1
        work = nil
        held = nil
        let tail: String
        switch r {
        case .stop: tail = "预览停了"
        case .ended: tail = "预览跑到这条素材末尾"
        case .seek: tail = ""
        }
        if !tail.isEmpty { say(tail) }
        let txt = rep.joined(separator: "\n")
        let d = duration
        DispatchQueue.main.async { [weak self] in
            self?.onFinish?(tail.isEmpty ? txt : tail + "\n" + txt, d)
        }
    }

    private func pass(video: URL, fromSec: Double, cast: [SwapCastMember]) -> Outcome {
        let c = snapCfg()
        if engine == nil || engineUnits != c.units {
            say("预览装两张网 units=\(c.unitsTxt)｜足迹 \(SwapFacts.footprintMB()) MB")
            let got = FsxEngine.load(units: c.units) { self.say($0) }
            guard let e = got.engine else {
                say("预览装网失败：\(got.note)")
                return .stop
            }
            engine = e
            engineUnits = c.units
            // 新装的那份引擎身上没带身份：不清零的话同一位会以为 latent 还在，每帧都画不出
            usedMember = -1
        }
        guard let engine = engine else { return .stop }
        guard let src = SwapSource(url: video, longEdge: c.longEdge, onLine: { self.say($0) }) else {
            say("预览 这条片子读不出（见上面几行）")
            return .stop
        }
        duration = src.duration
        let dur = src.duration
        progress(min(max(0, fromSec), dur), dur)
        frameW = src.outW
        frameH = src.outH
        let side = FsxGeo.sideSwap
        guard let dst = SwapTech.pixelBuffer(src.outW, src.outH).pb,
              let hd = SwapTech.pixelBuffer(src.outW, src.outH).pb else {
            say("预览 建不出 \(src.outW)x\(src.outH) 的小窗缓冲")
            return .stop
        }
        work = dst
        held = hd
        att = [Float](repeating: 0, count: 3 * side * side)
        face = [Float](repeating: 0, count: 3 * side * side)
        decodeMs = []; detectMs = []; warpMs = []; frameMs = []
        pasteMs = []; swapMs = []
        nSwap = 0; nFaces = 0; nDecode = 0; noFace = 0; unmatched = 0
        smallFace = 0; mirror = 0; fitFail = 0; netFail = 0; nTracks = 0
        mirrorReal = 0; mirrorGuess = 0; gapN = 0; gapMax = 0

        guard let reader = try? AVAssetReader(asset: src.asset) else { say("预览 reader 建不起来"); return .stop }
        // 不读 asset.start：这一版 SDK 里 AVURLAsset 没有 start 这个成员（出片那条也一直按 0 起算），
        // 而这里的秒数本来就是拿头一块 PTS 当原点算的，timeRange 只要圈住「从这一秒到末尾」就够
        let from = CMTimeMakeWithSeconds(min(max(0, fromSec), max(0, src.duration - 0.05)), preferredTimescale: 600)
        let to = CMTimeMakeWithSeconds(src.duration, preferredTimescale: 600)
        if CMTimeCompare(to, from) > 0 { reader.timeRange = CMTimeRange(start: from, end: to) }
        let vOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: [src.track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.videoComposition = src.vc
        reader.add(vOut)
        guard reader.startReading() else {
            say("预览 reader 起不来：\(reader.error?.localizedDescription ?? "-")")
            return .stop
        }
        let req = VNDetectFaceLandmarksRequest()
        let tick = 1.0 / max(1.0, c.fpsTarget)
        let fps = max(1.0, src.fps)
        say("预览开跑 进链 \(src.outW)x\(src.outH)｜从 \(String(format: "%.2f", fromSec)) s"
            + "｜每 1/\(String(format: "%.0f", c.fpsTarget)) s 换一格新画面"
            + "｜目标表 " + castLabel(cast))
        confirm(castLabel(cast))

        var lastTick = -1
        var tickSeq = 0
        var tracks: [PTrack] = []
        var nextTrack = 0
        var basePTS: CMTime = .zero
        var haveBase = false
        var anchorWall = 0.0, anchorSec = fromSec
        var started = false
        var lastStat = -10.0
        var lastSec = fromSec
        let wall0 = seconds()
        var lastPub = fromSec
        var outcome = Outcome.ended

        while true {
            var done = false
            var sleepTo = 0.0
            autoreleasepool {
                if pollStop() { outcome = .stop; done = true; return }
                if let s = pollSeek() { outcome = .seek(s); done = true; return }

                let td = ns()
                guard let sb = vOut.copyNextSampleBuffer() else { outcome = .ended; done = true; return }
                defer { CMSampleBufferInvalidate(sb) }
                guard reader.status == .reading, let pb = CMSampleBufferGetImageBuffer(sb) else {
                    outcome = .ended
                    done = true
                    return
                }
                nDecode += 1
                decodeMs.append(msFrom(td))
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                if !haveBase { basePTS = pts; haveBase = true }
                let sec = CMTimeGetSeconds(CMTimeSubtract(pts, basePTS)) + fromSec
                lastSec = sec
                if !started { anchorWall = seconds(); anchorSec = sec; started = true }

                let n = Int((sec / tick).rounded())
                if n != lastTick {
                    lastTick = n
                    tickSeq += 1
                    let ts = ns()
                    let t1 = ns()
                    let (obs, derr) = SwapVision.faces(pb, req)
                    if !derr.isEmpty { say("预览检测抛错：\(derr)") }
                    detectMs.append(msFrom(t1))
                    // 隔两格没再见到就当归档：出画再回来会另起一条轨迹、重新认一次人
                    tracks.removeAll { tickSeq - $0.lastTick > 2 }
                    if SwapVision.yTopLeftOrigin == nil,
                       let l = SwapVision.largest(obs, w: frameW, h: frameH),
                       let line = SwapVision.settleOriginStrict(face: obs[l.index]) {
                        say("预览 y 原点靠第 \(nDecode) 帧这一帧判出来：\(line)")
                    }

                    var used = Set<Int>()
                    var faces: [PFace] = []
                    for o in obs {
                        let box = SwapVision.pixelBox(o.boundingBox, frameW, frameH)
                        let sd = Double(min(box.width, box.height))
                        if sd < 12 { continue }
                        let (p, pn) = SwapVision.sendPoints(face: o, w: frameW, h: frameH)
                        guard p.count == 5, let pl = FsxGeo.place(pts: p, src: pn, shortSide: sd) else {
                            fitFail += 1
                            continue
                        }
                        pointSrc = pl.src
                        if pl.mirrored {
                            mirror += 1
                            if pl.src == "框猜" { mirrorGuess += 1 } else { mirrorReal += 1 }
                            // 这一格挡掉的到底是些什么点：把原值写进报告，下一轮判镜像这条闸门就不用再猜
                            if mirror <= 5 {
                                let ptTxt = pl.pts.map { String(format: "%.0f,%.0f", $0.x, $0.y) }.joined(separator: " ")
                                say("预览 \(String(format: "%.2f", sec)) s 这帧手性与模板相反（y 口径判反）"
                                    + "｜叉 \(String(format: "%.0f", pl.chir.nose))／\(String(format: "%.0f", pl.chir.mouth))"
                                    + "｜点位 \(pl.src)｜短边 \(String(format: "%.0f", pl.shortSide)) px"
                                    + "｜小窗 \(frameW)x\(frameH)｜5 点 \(ptTxt)→这格不换")
                            }
                            continue
                        }
                        var best = -1
                        var bestIoU = 0.0
                        for (ti, t) in tracks.enumerated() where !used.contains(t.id) {
                            let v = iou(box, t.lastBox)
                            if v > bestIoU { bestIoU = v; best = ti }
                        }
                        // 框跳得快时 IoU 会掉到 0.25 以下：再按中心距离捞一次，同一个人别被切成好几条轨迹
                        if best < 0 || bestIoU < 0.25 {
                            var near = -1
                            var nearD = Double.greatestFiniteMagnitude
                            for (ti, t) in tracks.enumerated() where !used.contains(t.id) {
                                let dx = Double(box.midX - t.lastBox.midX)
                                let dy = Double(box.midY - t.lastBox.midY)
                                let d = (dx * dx + dy * dy).squareRoot()
                                let lim = 0.6 * max(Double(box.width), Double(box.height), Double(t.lastBox.width))
                                if d <= lim, d < nearD { nearD = d; near = ti }
                            }
                            if near >= 0 { best = near; bestIoU = 0.25 }
                        }
                        var member = -1
                        if best >= 0, bestIoU >= 0.25 {
                            used.insert(tracks[best].id)
                            var t = tracks[best]
                            t.lastBox = box
                            t.lastTick = tickSeq
                            // 轨迹开头那一格可能是运动糊的：隔十格再认一次，余弦更高的那次说了算
                            if t.samples < 2, tickSeq >= t.sampleAt {
                                let got = identify(pb, pl: pl, engine: engine, cast: cast)
                                if got.member >= 0, got.cos > t.cos {
                                    t.member = got.member
                                    t.cos = got.cos
                                    if got.cos > -8 {
                                        say("预览 轨迹 \(t.id) 第 \(nDecode) 帧复采 → "
                                            + "\(cast[got.member].sourceLabel) 余弦 \(String(format: "%.3f", got.cos))")
                                    }
                                }
                                t.samples += 1
                                t.sampleAt = tickSeq + 10
                            }
                            member = t.member
                            tracks[best] = t
                        } else {
                            let got = identify(pb, pl: pl, engine: engine, cast: cast)
                            member = got.member
                            tracks.append(PTrack(id: nextTrack, member: member, cos: got.cos,
                                                 lastBox: box, lastTick: tickSeq,
                                                 samples: 1, sampleAt: tickSeq + 10))
                            nextTrack += 1
                            if got.cos > -8 {
                                say("预览 新轨迹 \(nextTrack - 1) 第 \(nDecode) 帧（\(String(format: "%.2f", sec)) s）短边 "
                                    + String(format: "%.0f", sd) + " px｜最近 \(got.best >= 0 ? cast[got.best].targetLabel : "—")"
                                    + " 余弦 \(String(format: "%.3f", got.cos))"
                                    + (member >= 0 ? " → 换成「\(cast[member].sourceLabel)」" : " → 目标表外、不动"))
                            }
                        }
                        if member < 0 {
                            unmatched += 1
                            continue
                        }
                        if sd < c.minFacePx {
                            smallFace += 1
                            continue
                        }
                        faces.append(PFace(pl: pl, member: member))
                    }
                    if !faces.isEmpty {
                        if SwapTech.copyRows(from: pb, to: hd),
                           compose(engine, faces: faces, cast: cast) > 0 {
                            nSwap += 1
                            let hold = sec - lastPub
                            if hold > 0.25 { gapN += 1; gapMax = max(gapMax, hold) }
                            lastPub = sec
                            publish(dst)
                        } else {
                            netFail += 1
                        }
                    } else {
                        if obs.isEmpty { noFace += 1 }
                    }
                    nTracks = max(nTracks, tracks.count)
                    swapMs.append(msFrom(ts))
                }
                sleepTo = anchorWall + (sec - anchorSec)
                if sec - lastStat >= 1.0 {
                    lastStat = sec
                    progress(sec, src.duration)
                }
            }
            if done { break }
            let now = seconds()
            if sleepTo > now { Thread.sleep(forTimeInterval: min(0.2, sleepTo - now)) }
        }
        reader.cancelReading()
        reportPrice(c: c, wall: seconds() - wall0, play: lastSec - fromSec, fps: fps)
        return outcome
    }

    /// 新轨迹认人：这一帧的 5 点裁 112 过向量网，跟目标表比一次余弦。
    private func identify(_ pb: CVPixelBuffer, pl: FsxGeo.Placed, engine: FsxEngine,
                          cast: [SwapCastMember]) -> (member: Int, best: Int, cos: Double) {
        let ok = SwapTech.withPixels(pb) { base, bpr -> Bool in
            FsxGeo.warpCrop(UnsafeRawPointer(base), bytesPerRow: bpr, w: frameW, h: frameH,
                            fwd: pl.fwd112, size: FsxGeo.side112, out: &c112)
        }
        guard ok == true else { return (-1, -1, -9) }
        let e = engine.embedding(crop112_01: c112)
        guard !e.emb.isEmpty else { return (-1, -1, -9) }
        let m = SwapCast.nearest(e.emb, members: cast)
        return (m.cos >= SwapCast.matchCos ? m.index : -1, m.index, m.cos)
    }

    /// 一格画面里的所有目标脸：画布先从原帧重铺一次，然后一张一张 裁 256 → 前向 → 贴回。
    /// 与成片同一条链路、同一组数：预览只是进链尺寸小，没有另配一档算法。返回贴上去了几张。
    private func compose(_ engine: FsxEngine, faces: [PFace], cast: [SwapCastMember]) -> Int {
        guard let dst = work, let hd = held else { return 0 }
        let side = FsxGeo.sideSwap
        // 画布先从原帧重铺：不铺就只有脸框那一片有像素、其余整幅是空的，界面上看着＝黑底上一小块脸
        guard SwapTech.copyRows(from: hd, to: dst) else {
            if netFail < 2 { say("预览 画布重铺失败：\(frameW)x\(frameH) 两张缓冲对不上") }
            return 0
        }
        var painted = 0
        for f in faces {
            let t0 = ns()
            if CVPixelBufferLockBaseAddress(hd, .readOnly) != kCVReturnSuccess { continue }
            var got = true
            if let base = CVPixelBufferGetBaseAddress(hd) {
                got = FsxGeo.warpCrop(UnsafeRawPointer(base), bytesPerRow: CVPixelBufferGetBytesPerRow(hd),
                                      w: frameW, h: frameH, fwd: f.pl.fwdSwap, size: side, out: &att)
            } else { got = false }
            CVPixelBufferUnlockBaseAddress(hd, .readOnly)
            if !got { continue }
            warpMs.append(msFrom(t0))

            let t1 = ns()
            // 一格里有几张目标脸：换到谁就把谁的 latent 装上（几百字节，不是重新读盘）
            if usedMember != f.member {
                guard engine.useIdentity(emb: cast[f.member].sourceEmb) else {
                    netFail += 1
                    if netFail <= 2 { say("预览 目标表第 \(f.member + 1) 位的替换脸装不上→这张不动") }
                    continue
                }
                usedMember = f.member
            }
            let r = engine.swap(cropSwap_01: att)
            frameMs.append(msFrom(t1))
            if r.face.count != 3 * side * side {
                netFail += 1
                if netFail <= 2 { say("预览 网没回话：\(r.note)") }
                continue
            }
            face = r.face

            let t4 = ns()
            if CVPixelBufferLockBaseAddress(dst, []) != kCVReturnSuccess { continue }
            var pasted = false
            if let base = CVPixelBufferGetBaseAddress(dst) {
                pasted = FsxGeo.pasteBack(base, bytesPerRow: CVPixelBufferGetBytesPerRow(dst),
                                          w: frameW, h: frameH, face: face, fwd: f.pl.fwdSwap,
                                          scratch: &pasteScratch)
            }
            CVPixelBufferUnlockBaseAddress(dst, [])
            pasteMs.append(msFrom(t4))
            if pasted {
                painted += 1
                nFaces += 1
            }
        }
        return painted
    }

    private func castLabel(_ cast: [SwapCastMember]) -> String {
        cast.enumerated().map { "目标\($0.offset + 1)→「\($0.element.sourceLabel)」" }.joined(separator: "、")
    }

    private func publish(_ pb: CVPixelBuffer) {
        let im = CIImage(cvPixelBuffer: pb)
        guard let cg = SwapPreview.ci.createCGImage(im, from: im.extent) else {
            if nSwap < 2 { say("预览 画面转不成图（CoreImage 没给 CGImage）") }
            return
        }
        let img = UIImage(cgImage: cg)
        DispatchQueue.main.async { [weak self] in self?.render?(img) }
    }

    private func reportPrice(c: Cfg, wall: Double, play: Double, fps: Double) {
        let unit = avg(detectMs) + avg(warpMs) + avg(frameMs) + avg(pasteMs)
        let need = unit * c.fpsTarget + avg(decodeMs) * fps
        let rate = wall > 0.1 ? Double(nSwap) / wall : 0
        let verdict = rate >= c.fpsTarget - 0.6 ? "够 16 帧"
            : (need <= 1000 ? "算着够、这一趟没跑到（素材短或停在开头）" : "不够 16 帧")
        say("预览单价 每换一格 \(String(format: "%.2f", unit)) ms＝检测 \(SwapUtil.stat(detectMs))"
            + "＋裁 256 \(SwapUtil.stat(warpMs))＋换脸网整次 \(SwapUtil.stat(frameMs))"
            + "＋画布重铺＋贴回 \(SwapUtil.stat(pasteMs))")
        say("      \(engine?.statsLine() ?? "网没装上（这一趟没跑到）")")
        say("      解码 \(SwapUtil.stat(decodeMs))×\(String(format: "%.1f", fps)) 帧/秒"
            + "｜整帧含节奏 \(SwapUtil.stat(swapMs))")
        say("      这一趟 换出 \(nSwap) 格／共换 \(nFaces) 张脸／读掉 \(nDecode) 格｜轨迹最多 \(nTracks) 条"
            + "｜没脸 \(noFace)｜目标表外 \(unmatched)｜太小 \(smallFace)｜拟合没过 \(fitFail)"
            + "｜镜像 \(mirror)（真点位 \(mirrorReal)／框猜 \(mirrorGuess)）｜画不出 \(netFail)｜点位 \(pointSrc)")
        say("      画面停住 超过 0.25 s 素材 \(gapN) 次｜最长 \(String(format: "%.2f", gapMax)) s"
            + "（一格没换新东西就一直摆着上一格，卡顿先按这一条分账：停住＝被挡的格多，不掉＝单价跑不满 16 帧）")
        say("      16 帧/秒这笔账 \(String(format: "%.2f", unit)) ms×\(String(format: "%.0f", c.fpsTarget))"
            + "＋解码 \(String(format: "%.1f", avg(decodeMs) * fps)) ms＝每播 1 s 素材要 \(String(format: "%.0f", need)) ms（一秒 1000 ms）"
            + "｜实测出画 \(String(format: "%.1f", rate)) 帧/真实秒、素材推进 \(String(format: "%.2f", play / max(wall, 0.01)))×"
            + "⇒\(verdict)")
    }

    private func say(_ s: String) {
        rep.append(s)
        DispatchQueue.main.async { [weak self] in self?.log?(s) }
    }

    private func progress(_ sec: Double, _ dur: Double) {
        DispatchQueue.main.async { [weak self] in self?.onProgress?(sec, dur) }
    }

    /// 画面里现在装的是哪几张脸：只在整张表验过、真开跑时回话
    private func confirm(_ label: String) {
        DispatchQueue.main.async { [weak self] in self?.onPerson?(label) }
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let x0 = max(a.minX, b.minX), y0 = max(a.minY, b.minY)
        let x1 = min(a.maxX, b.maxX), y1 = min(a.maxY, b.maxY)
        guard x1 > x0, y1 > y0 else { return 0 }
        let inter = Double((x1 - x0) * (y1 - y0))
        let uni = Double(a.width * a.height + b.width * b.height) - inter
        return uni > 0 ? inter / uni : 0
    }

    private func pollStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func pollSeek() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let s = seekTo
        seekTo = nil
        return s
    }

    private func ns() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func msFrom(_ t0: UInt64) -> Double { Double(ns() &- t0) / 1_000_000 }
    private func seconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    private func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
}
