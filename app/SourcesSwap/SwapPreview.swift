import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreML
import CoreVideo
import Foundation
import UIKit
import Vision

/// 预览档：把「已存的人」逐个贴进小窗看效果。只看、不导出，手机侧一个字节的文件都不写。
///
/// 为什么这一条能实时、出片那条不能：身份全在 ② 烘出来的那 18 个权重里、与帧无关，
/// 换一个人只要读盘把权重装上（0.22 上机实测 0.29~0.85 ms），所以一帧都不必缓存
/// ⇒ 长度上没有「超过 3 分钟就不行」那道墙，足迹还是日志里那 25~100 MB 的量级。
///
/// 每帧省下来的钱来自 0.22 量出的两处（那一版预览试算 73.6 ms/帧，过不了 16 fps 的 62.5 ms 门槛）：
///   ① 进链钉死 640 那一档，交出去的是这条小链的整幅画面：回贴的像素数随尺寸平方缩
///      （整片 1920 那一格实测 16.85 ms）。0.23 上机两档都量过：640 档每换一帧 53.34 ms＝每播 1 s 素材
///      要 909 ms，960 档 63.45 ms＝1105 ms 已经过不了 16 帧那一头 ⇒ 脸小也不再自己抬尺寸
///   ② 逐帧网那趟调用里的搬运（实测 8.49 ms，改在 SwapModels 那两处 memcpy，出片那条一起省）
/// 高频回填（σ＝0.8 高通，实测 2.60 ms）0.25 起跟成片同一口径：0.23 砍它省下的 2.6 ms
/// 顶不住「皮肤比成片软一档」，加回来是 53.34＋2.60→每播 1 s 素材约 951 ms，还在 1000 ms 以内。
///
/// 减帧口径：解码不跳（3.9 ms/帧），只有每 1/16 秒挑最贴近的那一帧真换，其余帧沿用上一格画面。
/// 这一条是当场检测、没有整片对称平滑：边上会比成片抖（成片平滑后 0.94 px，这一路借成片口径约 1.9 px）。
final class SwapPreview {

    struct Cfg {
        var units: MLComputeUnits = .cpuOnly
        var unitsTxt = "CPU(cpuOnly)"
        var whiten = true
        var fpsTarget: Double = 16
        var minFacePx: Double = 40
        var longEdge = 640
    }

    /// 界面挂的口子：出画、点这一下的那句答案（只在被挡／开跑／停下时递，跑动中的逐秒实况不往这里走）、
    /// 进流水、停下来的那一句（连带这条素材的秒数＝滑杆的范围）
    var render: ((UIImage) -> Void)?
    var onShow: ((String) -> Void)?
    var log: ((String) -> Void)?
    var onFinish: ((String, Double) -> Void)?
    /// 滑杆用的数字口径：（现在播到第几秒, 这条素材共几秒）。界面不许去解析上面那行字。
    var onProgress: ((Double, Double) -> Void)?
    /// 装成功的那个人才回给界面：换人有三条失败路（读不出／空包／形状不对），
    /// 那三种情况画面里还是原来那个人，名字却跟着手指走就会假报「已经换成他」
    var onPerson: ((String) -> Void)?

    private enum Outcome { case stop, ended, seek(Double) }

    private static let ci = CIContext(options: [.cacheIntermediates: false])

    private let q = DispatchQueue(label: "swap.preview")
    private let lock = NSLock()
    private var stopping = false
    private var seekTo: Double?
    private var wantPerson: String?
    private var cfg = Cfg()
    private var busy = false

    // 下面这些只在 q 那条线程上读写，界面不许碰
    private var runner: SwapRunner?
    private var runnerUnits: MLComputeUnits?
    private var person = ""
    private var rep: [String] = []
    private var work: CVPixelBuffer?
    private var held: CVPixelBuffer?
    private var frameW = 0, frameH = 0
    private var att = [Float](), gen = [Float](), rawMask = [Float]()
    private var m2 = [Float](), alpha = [Float](), tailRows = [Float]()
    private var decodeMs: [Double] = [], detectMs: [Double] = [], warpMs: [Double] = []
    private var frameMs: [Double] = [], beautyMs: [Double] = [], maskMs: [Double] = []
    private var pasteMs: [Double] = [], swapMs: [Double] = [], detailMs: [Double] = []
    private var nSwap = 0, nDecode = 0, noFace = 0, smallFace = 0, mirror = 0, fitFail = 0, netFail = 0
    /// 被手性闸门挡下的帧分两拨：点是从 Vision 五官来的、还是只按脸框猜的
    private var mirrorReal = 0, mirrorGuess = 0
    /// 画面停住（这一格没换新东西）的最长一段素材秒数、和超过 0.25 s 的次数：卡顿先量出来再说话
    private var gapN = 0, gapMax = 0.0
    private var pointSrc = "—"
    private var duration = 0.0

    // MARK: - 界面进来的三条口

    /// 起一趟预览。返回 ""＝已经开跑；否则是当场拒绝的理由。
    /// 人就是这一刻定下来的，一整趟不换：要换人是「停预览」→点名字→再「开始预览」。
    func start(video: URL, personId: String, cfg newCfg: Cfg) -> String {
        lock.lock()
        if busy { lock.unlock(); return "预览正跑着，先点「停预览」" }
        guard FileManager.default.fileExists(atPath: video.path) else {
            lock.unlock()
            return "②那份视频副本上一趟已经还掉了，重新点②选一条"
        }
        guard !personId.isEmpty else {
            lock.unlock()
            return "预览只用「已存的人」：先点一个名字"
        }
        cfg = newCfg
        stopping = false
        seekTo = nil
        wantPerson = personId
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

    // MARK: - 跑

    /// 只有拖进度条要重开一趟 pass（换 reader 跳到那一秒）；装人在 pass 里就地办
    private func drive(video: URL) {
        rep = []      // 一趟一份报告：不清就会把上一趟的整份日志背在身上，越跑越长
        var sec = 0.0
        while true {
            let r = pass(video: video, fromSec: sec)
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
        lock.lock(); busy = false; lock.unlock()
        // 停下来的那一刻把三张网和两块整幅缓冲交回去：出片那条自己还要装一份 runner，
        // 预览留着不放就是把下一次「开始换脸」顶到它自己的足迹闸门上
        runner = nil
        runnerUnits = nil
        person = ""
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

    private func pass(video: URL, fromSec: Double) -> Outcome {
        let c = snapCfg()
        if runner == nil || runnerUnits != c.units {
            say("预览装三张网 units=\(c.unitsTxt)｜足迹 \(SwapFacts.footprintMB()) MB")
            let got = SwapRunner.load(units: c.units) { self.say($0) }
            guard let r = got.runner else {
                say("预览装网失败：\(got.note)")
                return .stop
            }
            runner = r
            runnerUnits = c.units
            // 新建的那张 runner 身上没带任何身份权重，而 person 还记着上一个人：
            // 不清零的话 applyPending 会以为「还是他」而跳过装权重，每一帧都画不出
            person = ""
        }
        guard let runner = runner else { return .stop }
        guard let src = SwapSource(url: video, longEdge: c.longEdge, onLine: { self.say($0) }) else {
            say("预览 这条片子读不出（见上面几行）")
            return .stop
        }
        duration = src.duration
        let dur = src.duration
        progress(min(max(0, fromSec), dur), dur)
        frameW = src.outW
        frameH = src.outH
        let side = SwapGeo.size
        guard let dst = SwapTech.pixelBuffer(src.outW, src.outH).pb,
              let hd = SwapTech.pixelBuffer(src.outW, src.outH).pb else {
            say("预览 建不出 \(src.outW)x\(src.outH) 的小窗缓冲")
            return .stop
        }
        work = dst
        held = hd
        att = [Float](repeating: 0, count: 3 * side * side)
        gen = [Float](repeating: 0, count: 3 * side * side)
        rawMask = [Float](repeating: 0, count: side * side)
        m2 = [Float](repeating: 0, count: side * side)
        alpha = [Float](repeating: 0, count: SwapGeo.maskRows * side)
        tailRows = [Float](repeating: 0, count: 3 * side)
        decodeMs = []; detectMs = []; warpMs = []; frameMs = []
        beautyMs = []; maskMs = []; pasteMs = []; swapMs = []; detailMs = []
        nSwap = 0; nDecode = 0; noFace = 0; smallFace = 0; mirror = 0; fitFail = 0; netFail = 0
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
            + "｜每 1/\(String(format: "%.0f", c.fpsTarget)) s 换一格新画面")

        var lastTick = -1
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
                applyPending(runner)

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
                    let ts = ns()
                    let t1 = ns()
                    let (obs, derr) = SwapVision.faces(pb, req)
                    if !derr.isEmpty { say("预览检测抛错：\(derr)") }
                    detectMs.append(msFrom(t1))
                    if let l = SwapVision.largest(obs, w: frameW, h: frameH) {
                        if SwapVision.yTopLeftOrigin == nil,
                           let line = SwapVision.settleOriginStrict(face: obs[l.index]) {
                            say("预览 y 原点靠第 \(nDecode) 帧这一帧判出来：\(line)")
                        }
                        let (p, pn) = SwapVision.sendPoints(face: obs[l.index], w: frameW, h: frameH)
                        pointSrc = pn
                        if l.shortSide < c.minFacePx {
                            smallFace += 1
                        } else if p.count == 5, let al = SwapVision.align(pts: p, src: pn, shortSide: l.shortSide) {
                            if al.mirrored {
                                mirror += 1
                                if al.src == "框猜" { mirrorGuess += 1 } else { mirrorReal += 1 }
                                // 这一格挡掉的到底是些什么点：把原值写进报告，下一轮判镜像这条闸门就不用再猜
                                if mirror <= 5 {
                                    let ptTxt = al.pts.map { String(format: "%.0f,%.0f", $0.x, $0.y) }.joined(separator: " ")
                                    say("预览 \(String(format: "%.2f", sec)) s 这帧手性与模板相反（y 口径判反）"
                                        + "｜叉 \(String(format: "%.0f", al.chir.nose))／\(String(format: "%.0f", al.chir.mouth))"
                                        + "｜点位 \(al.src)｜短边 \(String(format: "%.0f", al.shortSide)) px"
                                        + "｜小窗 \(frameW)x\(frameH)｜5 点 \(ptTxt)→这格不换")
                                }
                            } else if SwapTech.copyRows(from: pb, to: hd),
                                      compose(runner, al: al, whiten: snapCfg().whiten) {
                                nSwap += 1
                                let hold = sec - lastPub
                                if hold > 0.25 { gapN += 1; gapMax = max(gapMax, hold) }
                                lastPub = sec
                                publish(dst)
                            } else {
                                netFail += 1
                            }
                        } else {
                            fitFail += 1
                        }
                    } else {
                        noFace += 1
                    }
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

    /// 一帧的活：小窗那一幅 → 裁 224 → 逐帧网 → 高频回填 → 美白 → 遮罩 → 贴回小窗。
    /// 补丁这一段与成片同一口径（0.25 起把高频回填加回来）；省的只有回贴那一片的像素数（进链钉在 640）。
    private func compose(_ runner: SwapRunner, al: SwapVision.Alignment, whiten: Bool) -> Bool {
        guard let dst = work, let hd = held else { return false }
        let side = SwapGeo.size
        let t0 = ns()
        if CVPixelBufferLockBaseAddress(hd, .readOnly) != kCVReturnSuccess { return false }
        var got = true
        if let base = CVPixelBufferGetBaseAddress(hd) {
            SwapGeo.warpToCrop(UnsafeRawPointer(base), bytesPerRow: CVPixelBufferGetBytesPerRow(hd),
                               w: frameW, h: frameH, fwd: al.fwd, side: side, out: &att)
        } else { got = false }
        CVPixelBufferUnlockBaseAddress(hd, .readOnly)
        if !got { return false }
        warpMs.append(msFrom(t0))

        let t1 = ns()
        let r = runner.frame(att224_01: att)
        frameMs.append(msFrom(t1))
        if r.out.count != 3 * side * side || r.mask.count != side * side {
            if netFail < 2 { say("预览 网没回话：\(r.note)") }
            return false
        }
        gen = r.out
        rawMask = r.mask

        let t2a = ns()
        // 高频回填：把原帧 224 里那份高通细节加回补丁（成片同一式、同一参数）
        SwapGeo.restoreDetail(&gen, att, lam: 1.0, sigma: 0.8)
        detailMs.append(msFrom(t2a))

        let t2 = ns()
        if whiten { SwapGeo.whiten(&gen, side: side) }
        beautyMs.append(msFrom(t2))

        let t3 = ns()
        SwapGeo.preprocessMask(rawMask, &m2)
        SwapGeo.featherMask(m2, &alpha)
        for pl in 0..<3 {
            let b = pl * side * side + (side - 1) * side
            for x in 0..<side { tailRows[pl * side + x] = att[b + x] }
        }
        maskMs.append(msFrom(t3))

        let t4 = ns()
        // 画布每一格先从原帧重铺：不铺就只有脸框那一片有像素、其余整幅是空的，界面上看着＝黑底上一小块脸。
        // 出片那条同样是每帧先把原帧拷进 dst（SwapClip 的「拷帧失败」那一格）。
        guard SwapTech.copyRows(from: hd, to: dst) else {
            if netFail < 2 { say("预览 画布重铺失败：\(frameW)x\(frameH) 两张缓冲对不上") }
            return false
        }
        if CVPixelBufferLockBaseAddress(dst, []) != kCVReturnSuccess { return false }
        var pasted = false
        if let base = CVPixelBufferGetBaseAddress(dst) {
            SwapGeo.pasteBack(base, bytesPerRow: CVPixelBufferGetBytesPerRow(dst), w: frameW, h: frameH,
                              gen: gen, tail: tailRows, mask: alpha, fwd: al.fwd, back: al.back)
            pasted = true
        }
        CVPixelBufferUnlockBaseAddress(dst, [])
        pasteMs.append(msFrom(t4))
        return pasted
    }

    /// 「开始预览」定下那个人挂进来的那一步：读盘装权重。一整趟只在这里装一次，装完不再换人。
    private func applyPending(_ runner: SwapRunner) {
        lock.lock()
        let pid = wantPerson
        wantPerson = nil
        lock.unlock()
        guard let pid = pid, pid != person else { return }
        guard let one = SwapIdents.load(id: pid) else {
            refuse("预览开不起来：「\(SwapIdents.displayName(pid))」的存档读不出来，先停预览换一个人")
            return
        }
        let eNorm = SwapIdents.norm(one.emb), wNorm = SwapIdents.weightsNorm(one.weights)
        guard eNorm > 0.5, wNorm > 1e-6 else {
            refuse("预览开不起来：「\(one.name)」这份包里的数是空的（身份证模长 \(String(format: "%.4f", eNorm))"
                + "／权重合起来模长 \(String(format: "%.3f", wNorm))），先停预览换一个人")
            return
        }
        let t0 = ns()
        let put = runner.useWeights(one.weights)
        let ms = msFrom(t0)
        guard put.count == 18 else {
            refuse("预览开不起来：\(put.note)，先停预览换一个人")
            return
        }
        person = pid
        confirm(pid)
        say("预览 装到人「\(one.name)」：读盘＋装权重 \(SwapUtil.ms(ms))｜\(put.note)"
            + "｜跳过 ①②（上机实测这两步 70.61 + 18.27 ms）｜足迹 \(SwapFacts.footprintMB()) MB")
    }

    /// 开不起来：这句既进流水（发电脑要看的那份），也当场顶到界面那一行——点了「开始预览」总得有个说法
    private func refuse(_ s: String) {
        say(s)
        show(s)
        confirm("")
        refuseRun()
    }

    /// 身份权重装不上就别跑了：那张 runner 身上没身份，逐帧网只会凑出一张不认识的脸
    private func refuseRun() {
        lock.lock(); stopping = true; lock.unlock()
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
        let unit = avg(detectMs) + avg(warpMs) + avg(frameMs) + avg(detailMs) + avg(beautyMs) + avg(maskMs) + avg(pasteMs)
        let need = unit * c.fpsTarget + avg(decodeMs) * fps
        let rate = wall > 0.1 ? Double(nSwap) / wall : 0
        let verdict = rate >= c.fpsTarget - 0.6 ? "够 16 帧"
            : (need <= 1000 ? "算着够、这一趟没跑到（素材短或停在开头）" : "不够 16 帧")
        say("预览单价 每换一帧 \(String(format: "%.2f", unit)) ms＝检测 \(SwapUtil.stat(detectMs))"
            + "＋裁脸 \(SwapUtil.stat(warpMs))＋逐帧网 \(SwapUtil.stat(frameMs))"
            + "＋高频回填 \(SwapUtil.stat(detailMs))＋美白 \(SwapUtil.stat(beautyMs))＋羽化 \(SwapUtil.stat(maskMs))"
            + "＋画布重铺＋脸框回贴 \(SwapUtil.stat(pasteMs))")
        say("      解码 \(SwapUtil.stat(decodeMs))×\(String(format: "%.1f", fps)) 帧/秒"
            + "｜整帧含节奏 \(SwapUtil.stat(swapMs))｜美白这一趟\(c.whiten ? "开" : "关")")
        say("      这一趟 换出 \(nSwap) 格／读掉 \(nDecode) 格｜没脸 \(noFace)｜太小 \(smallFace)｜拟合没过 \(fitFail)"
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

    private func show(_ s: String) {
        DispatchQueue.main.async { [weak self] in self?.onShow?(s) }
    }

    private func progress(_ sec: Double, _ dur: Double) {
        DispatchQueue.main.async { [weak self] in self?.onProgress?(sec, dur) }
    }

    /// 画面里现在装的到底是谁：只在这一步真装上／没收时才回话
    private func confirm(_ pid: String) {
        DispatchQueue.main.async { [weak self] in self?.onPerson?(pid) }
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
