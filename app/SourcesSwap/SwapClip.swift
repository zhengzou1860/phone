import AVFoundation
import CoreMedia
import CoreML
import CoreVideo
import Foundation
import Photos
import UIKit
import Vision

/// 像素缓冲和编码器那边的小工具，写法照 VR3D 那条线已经上机跑通的抄。
enum SwapTech {

    /// 容器写的旋转角（0/90/180/270）
    static func deg(_ t: CGAffineTransform) -> Int {
        var d = Int((atan2(t.b, t.a) * 180 / .pi).rounded())
        if d < 0 { d += 360 }
        return d
    }

    /// 长边不超过 cap，宽高取偶数（h264 要偶数尺寸）。cap 用不上就原样取偶。
    static func fitEven(_ w: Int, _ h: Int, longEdge cap: Int) -> (w: Int, h: Int) {
        let long = max(w, h)
        var ow = w, oh = h
        if cap > 0, long > cap {
            let s = Double(cap) / Double(long)
            ow = Int((Double(w) * s).rounded())
            oh = Int((Double(h) * s).rounded())
        }
        return (max(16, ow & ~1), max(16, oh & ~1))
    }

    static func pixelBuffer(_ w: Int, _ h: Int) -> (pb: CVPixelBuffer?, note: String) {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferBytesPerRowAlignmentKey as String: w * 4,
        ]
        var pb: CVPixelBuffer?
        let r = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                    attrs as CFDictionary, &pb)
        guard r == kCVReturnSuccess, let out = pb else {
            return (nil, "建 \(w)x\(h) BGRA 缓冲失败 CVReturn=\(r)")
        }
        return (out, "")
    }

    /// 从 adaptor 的池里要一块。池没了就返回 nil，调用方退回每帧新造。
    static func poolBuffer(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }

    /// 逐行拷像素（两张的 bytesPerRow 不一定相同，不能一次 memcpy 到底）
    static func copyRows(from src: CVPixelBuffer, to dst: CVPixelBuffer) -> Bool {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        guard w == CVPixelBufferGetWidth(dst), h == CVPixelBufferGetHeight(dst) else { return false }
        if CVPixelBufferLockBaseAddress(src, .readOnly) != kCVReturnSuccess { return false }
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        if CVPixelBufferLockBaseAddress(dst, []) != kCVReturnSuccess { return false }
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }
        guard let sb = CVPixelBufferGetBaseAddress(src), let db = CVPixelBufferGetBaseAddress(dst) else { return false }
        let sr = CVPixelBufferGetBytesPerRow(src), dr = CVPixelBufferGetBytesPerRow(dst)
        let n = min(sr, dr)
        for y in 0..<h {
            memcpy(db.advanced(by: y * dr), sb.advanced(by: y * sr), n)
        }
        return true
    }

    /// 读写一块缓冲的像素。锁不开或拿不到基址就返回 nil（调用方必须把这一帧当失败处理，不许静默跳过）。
    /// 模型预测期间不握着锁：取像素和回贴各自锁一次。
    static func withPixels<T>(_ pb: CVPixelBuffer, _ body: (UnsafeMutableRawPointer, Int) -> T) -> T? {
        guard CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        return body(base, CVPixelBufferGetBytesPerRow(pb))
    }

    /// 把 CGImage 画进一块 BGRA 缓冲：静帧和取样器只认缓冲这一种形状
    static func pixelBuffer(from cg: CGImage) -> (pb: CVPixelBuffer?, note: String) {
        let w = cg.width, h = cg.height
        let made = pixelBuffer(w, h)
        guard let pb = made.pb else { return (nil, made.note) }
        guard CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess else {
            return (nil, "静帧缓冲锁不上")
        }
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return (nil, "静帧缓冲没有基址") }
        let cs = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return (nil, "静帧建不出画到缓冲的上下文")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (pb, "")
    }

    /// 存进相册。成功返回「已存到相册」，失败带回错误文本。
    static func toPhotos(_ file: URL) -> String {
        let sem = DispatchSemaphore(value: 0)
        var result = "没发起"
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
        }) { ok, error in
            result = ok ? "已存到相册" : "存相册失败: \(error?.localizedDescription ?? "-")"
            sem.signal()
        }
        sem.wait()
        return result
    }
}

/// 一条片子：摆正后的尺寸、时长、帧率，以及"直出来就是摆正的帧"的那份 videoComposition。
/// 走 composition 这条路是 VR3D 上机验过的（一分钟素材跑通），好处是 app 里根本不存在朝向这件事。
final class SwapSource {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let vc: AVMutableVideoComposition
    let upW: Int
    let upH: Int
    let outW: Int
    let outH: Int
    let deg: Int
    let duration: Double
    let fps: Double

    init?(url: URL, longEdge: Int, onLine: (String) -> Void) {
        asset = AVURLAsset(url: url)
        guard let t = asset.tracks(withMediaType: .video).first else {
            onLine("源 没有视频轨 \(url.lastPathComponent)")
            return nil
        }
        track = t
        let tf = t.preferredTransform
        let nat = t.naturalSize
        let cs = [CGPoint(x: 0, y: 0), CGPoint(x: nat.width, y: 0),
                  CGPoint(x: 0, y: nat.height), CGPoint(x: nat.width, y: nat.height)]
            .map { $0.applying(tf) }
        deg = SwapTech.deg(tf)
        upW = max(2, Int((cs.map { $0.x }.max()! - cs.map { $0.x }.min()!).rounded()))
        upH = max(2, Int((cs.map { $0.y }.max()! - cs.map { $0.y }.min()!).rounded()))
        let fit = SwapTech.fitEven(upW, upH, longEdge: longEdge)
        outW = fit.w
        outH = fit.h
        duration = CMTimeGetSeconds(asset.duration)
        fps = Double(t.nominalFrameRate) > 1 ? Double(t.nominalFrameRate) : 30.0
        let v = AVMutableVideoComposition()
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: t)
        // 源的摆正变换之后再接一层缩放，直出「摆正且已经是进链尺寸」的帧
        let sc = CGAffineTransform(scaleX: CGFloat(outW) / CGFloat(upW), y: CGFloat(outH) / CGFloat(upH))
        li.setTransform(tf.concatenating(sc), at: .zero)
        let ti = AVMutableVideoCompositionInstruction()
        ti.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        ti.layerInstructions = [li]
        v.instructions = [ti]
        v.renderSize = CGSize(width: outW, height: outH)
        v.frameDuration = CMTime(value: 1, timescale: 600)
        vc = v
        onLine("源 \(url.lastPathComponent) 存 \(Int(nat.width))x\(Int(nat.height)) 容器转 \(deg)° → 摆正 \(upW)x\(upH)"
             + "｜进链 \(outW)x\(outH)（长边上限 \(longEdge)）｜\(String(format: "%.1f", duration)) s @ \(String(format: "%.1f", fps)) fps")
        guard duration > 0.1 else {
            onLine("源 时长读不出来 \(duration)")
            return nil
        }
    }
}

/// 整片真换脸：目标表（视频里要换谁 → 换成谁）→ 预检整片把每张脸挂到轨迹上、每条轨迹认一次人
/// → 逐帧 对齐→256 前向→贴回（一帧里有几张目标脸就换几张）→ 编码器写新片。
/// 每一步的单价、身份余弦、足迹水位全部进流水；跑完存相册，成功才删沙盒那份。
///
/// 这一条链路只有两张网（脸向量网＋hyperswap_1c_256），
/// 逐帧的钱全在那一张 30 GMAC 的换脸网上，其余每一步都是几十字节的算术；
/// 多人换脸加的钱是多张脸各一次前向，检测仍是一帧一次（Vision 本来就是一次出所有脸）。
enum SwapClip {
    struct Args {
        var units: MLComputeUnits = .cpuOnly  // 0.39 上机四档实测：CPU 890／GPU 1043／all 1045／ANE 815 ms 一格，
                                              // all 落回的就是 GPU（比纯 CPU 慢 18 %，足迹还要 854 MB），所以默认按 CPU 钉住；
                                              // CPU 这一档也正是 CI 转换时对账用的那条 fp32 路。界面那格能换
        var longEdge: Int = 1920
        var minFacePx: Double = 40
        var sampleEvery: Int = 60
        /// 收兵线：换脸网单张 onnx 权重 403 MB，装成 fp32 包还要更大；旧那条线四张小网定的 900 MB 会把正常跑当成越界。
        /// iPhone 11 的单进程水位线在 1.5 GB 上下，踩到就是系统直接杀进程（连一行流水都留不下），所以这条线只能往下压着留。
        var footprintStopMB: Int = 1300
    }

    static func run(members: [SwapCastMember], video: URL, args: Args,
                    onLine: @escaping (String) -> Void) -> (out: URL?, note: String) {
        var rep: [String] = []
        func say(_ s: String) { rep.append(s); onLine(s) }
        func fail(_ s: String) -> (out: URL?, note: String) {
            say(s)
            SwapJournal.digest(rep, failed: true)
            return (nil, rep.joined(separator: "\n"))
        }

        // —— 1. 两张网 ——
        let got = FsxEngine.load(units: args.units, onLine: onLine)
        guard let engine = got.engine else { return fail("装网失败：\n" + got.note) }

        // —— 2. 目标表：视频里要换谁、换成谁（两张身份证在界面上传照片时就算好了；这里只验形状） ——
        let req = VNDetectFaceLandmarksRequest()
        guard !members.isEmpty else { return fail("目标表是空的：先上传目标人脸图片并选一张替换脸") }
        for (i, m) in members.enumerated() {
            let tn = FsxEngine.norm(m.targetEmb)
            guard m.targetEmb.count == FsxNets.embDim, tn > 0.5 else {
                return fail("\(m.targetLabel) 的目标特征用不了：\(m.targetEmb.count) 维／模长 \(String(format: "%.3f", tn))"
                    + "——重新选一张视频里那个人的正脸照")
            }
            let sn = FsxEngine.norm(m.sourceEmb)
            guard m.sourceEmb.count == FsxNets.embDim, sn > 0.5 else {
                return fail("\(m.targetLabel) 的替换脸「\(m.sourceLabel)」用不了：\(m.sourceEmb.count) 维／模长 \(String(format: "%.3f", sn))"
                    + "——重新选一个已存的人或一张源脸照片")
            }
            say("目标表 \(i + 1)/\(members.count)：\(m.targetLabel) → 替换「\(m.sourceLabel)」"
                + "｜认得脸用的余弦闸门 \(String(format: "%.2f", SwapCast.matchCos))"
                + "，短边 < \(String(format: "%.0f", max(SwapCast.identFloor(longEdge: args.longEdge), args.minFacePx))) px 的不量身份"
                + "（进链 \(args.longEdge) 折算；糊过 112 那一档的还要领先次近 "
                + String(format: "%.2f", SwapCast.matchMargin) + "）"
                + "｜足迹 \(SwapFacts.footprintMB()) MB")
        }

        // —— 3. 片子 ——
        guard let src = SwapSource(url: video, longEdge: args.longEdge, onLine: onLine) else {
            return fail("这条片子读不出（见上面几行）")
        }
        let estFrames = max(1, Int((src.duration * src.fps).rounded()))
        let bitrate = max(6_000_000, Int(Double(src.outW * src.outH * 6) * 1.5))
        let need = Double(bitrate) / 8.0 * src.duration * 1.2 + 200_000_000
        let free = (Double(SwapFacts.diskFreeGB()) ?? 0) * 1_073_741_824
        say("磁盘闸门 这条要 \(String(format: "%.0f", need / 1_048_576)) MB（码率 \(String(format: "%.1f", Double(bitrate) / 1e6)) Mbps）"
            + "｜可用 \(String(format: "%.1f", free / 1_073_741_824)) GB")
        if need > free { return fail("可用空间不够，不出片：素材 \(String(format: "%.0f", src.duration)) s") }
        say("补丁口径 贴区＝256 那张方块投回帧空间自己盖住的那一片平行四边形（官方那套 preprocess_mask，一刀不减）："
            + "白图随逆矩阵映回来 → >20 的格子拉成 255 → 按这块贴区量出的边长腐蚀 k=max(mask_size/10,10) "
            + "→ 再糊一刀，核长 2*max(mask_size/20,5)+1、σ 由核长现算 → out = mask*补丁 + (1−mask)*原帧。"
            + "不叠分割网、不做色彩搬运、不回填高频、不美白＝PC 那条被肉眼认过的链路里根本没有这几步，"
            + "多一步就多一处能把画面搬错的地方（对账凭据在 ci/fsx_fixtures，链路出处在 fsx/netstage.py）。"
            + "补丁先量化到 8 位才贴（PC 是 clip 后 astype(uint8) 再 warp，跳过这步边上差半格）。")

        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        // 上一轮留下的半成品和旧选片先清掉：手机侧不许留残料
        var reclaimed = 0
        for one in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [])) ?? [] {
            guard one.lastPathComponent.hasPrefix("swap_") else { continue }
            guard one.lastPathComponent != video.lastPathComponent else { continue }   // 本次要用的这条输入不能当残留删
            let sz = (try? one.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if (try? fm.removeItem(at: one)) != nil { reclaimed += sz }
        }
        if reclaimed > 0 { say("先清掉上轮残留的半成品 \(String(format: "%.1f", Double(reclaimed) / 1_048_576)) MB") }
        let dfmt = DateFormatter()
        dfmt.dateFormat = "yyyyMMdd-HHmmss"
        let out = dir.appendingPathComponent("swap_\(dfmt.string(from: Date())).mp4")
        try? fm.removeItem(at: out)

        // —— 2.5 预检趟：整片先只解码＋检测 ——
        // ① 对称平滑要往后看 6 帧，出片这趟是单向流水、拿不到未来的点；只看过去的滤波本机量过＝补丁落后
        //    16.6 px（p95 36 px），快动段成重影。② 多人换脸要认「这一帧这张脸是谁」：检测本来就是一次出所有脸，
        //    身份只在一条轨迹开头算一次，不能每帧每张脸都过向量网。轨迹按相邻帧的脸框 IoU 串起来；
        //    新轨迹（换人、出画再回来、切镜头）再认一次。钱＝这趟多一次解码＋一次检测，出片那趟从此不再检测。
        struct PreFace {
            var pts: [CGPoint]
            var side: Double
            var src: String
            var box: CGRect
            var track: Int
            var member: Int
        }
        struct LiveTrack {
            var id: Int
            var member: Int
            var cos: Double
            var lastBox: CGRect
            var lastFrame: Int
            var samples: Int
            var sampleAt: Int
        }
        var preFrames: [[PreFace]] = []
        var trackMember: [Int: Int] = [:]
        var active: [LiveTrack] = []
        var nextTrack = 0
        var trackLog: [String] = []
        var preDecodeMs: [Double] = [], preDetectMs: [Double] = []
        // 量身份的门槛：跟着进链折算（出片 1920 ⇒ 64 px），再和太小线取大者；长边调小它跟着缩
        let floorPx = max(SwapCast.identFloor(longEdge: args.longEdge), args.minFacePx)
        let pre0 = DispatchTime.now().uptimeNanoseconds
        // 从这一帧的像素缓冲裁 112、过向量网，和目标表比一次余弦。两条路用它：预检的新轨迹、预检失败时的现检。
        func identify(_ pb: CVPixelBuffer, w: Int, h: Int, pts: [CGPoint], src: String, side: Double)
            -> (member: Int, best: Int, cos: Double, note: String) {
            guard let pl = FsxGeo.place(pts: pts, src: src, shortSide: side) else {
                return (-1, -1, -9, "5 点映不进模板")
            }
            if pl.mirrored { return (-1, -1, -9, "手性与模板相反") }
            var crop = [Float](repeating: 0, count: 3 * FsxGeo.side112 * FsxGeo.side112)
            let ok = SwapTech.withPixels(pb) { base, bpr -> Bool in
                FsxGeo.warpCrop(UnsafeRawPointer(base), bytesPerRow: bpr, w: w, h: h,
                                fwd: pl.fwd112, size: FsxGeo.side112, out: &crop)
            }
            guard ok == true else { return (-1, -1, -9, "裁不出 112") }
            let e = engine.embedding(crop112_01: crop)
            guard !e.emb.isEmpty else { return (-1, -1, -9, "向量网没回话：\(e.note)") }
            let m = SwapCast.nearest(e.emb, members: members)
            return (SwapCast.accept(cos: m.cos, second: m.second, shortSide: side) ? m.index : -1,
                    m.index, m.cos, e.note)
        }
        func iou(_ a: CGRect, _ b: CGRect) -> Double {
            let x0 = max(a.minX, b.minX), y0 = max(a.minY, b.minY)
            let x1 = min(a.maxX, b.maxX), y1 = min(a.maxY, b.maxY)
            guard x1 > x0, y1 > y0 else { return 0 }
            let inter = Double((x1 - x0) * (y1 - y0))
            let uni = Double(a.width * a.height + b.width * b.height) - inter
            return uni > 0 ? inter / uni : 0
        }
        say("先跑预检这一趟：整片只解码＋检测，按轨迹记下每张脸的 5 点（新轨迹在机上算一次目标身份），"
            + "再逐轨迹对称平滑（出片那趟就不再检测了）")
        if let pr = try? AVAssetReader(asset: src.asset) {
            let pv = AVAssetReaderVideoCompositionOutput(
                videoTracks: [src.track],
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            pv.videoComposition = src.vc
            pr.add(pv)
            if pr.startReading() {
                while true {
                    guard let sb = pv.copyNextSampleBuffer() else { break }
                    defer { CMSampleBufferInvalidate(sb) }      // 这一趟不把块交给 writer，取出来就该还
                    let pd0 = DispatchTime.now().uptimeNanoseconds
                    guard let pb = CMSampleBufferGetImageBuffer(sb) else { break }
                    let pw = CVPixelBufferGetWidth(pb), ph = CVPixelBufferGetHeight(pb)
                    preDecodeMs.append(Double(DispatchTime.now().uptimeNanoseconds - pd0) / 1_000_000)
                    let frame = preFrames.count
                    let pt0 = DispatchTime.now().uptimeNanoseconds
                    let (pObs, pErr) = SwapVision.faces(pb, req)
                    if !pErr.isEmpty { say("预检检测抛错：\(pErr)") }
                    preDetectMs.append(Double(DispatchTime.now().uptimeNanoseconds - pt0) / 1_000_000)
                    // y 口径在这一趟就要定下来：定晚了，整条轨迹的 5 点是映反的，平滑只会把它抹得更圆
                    if SwapVision.yTopLeftOrigin == nil,
                       let first = SwapVision.largest(pObs, w: pw, h: ph) {
                        say("预检 " + SwapVision.settleOrigin(face: pObs[first.index]))
                    }
                    // 连着 5 帧（60 fps 下 0.08 s）没再见到才归档：Vision 偶尔漏一帧，
                    // 丢早了同一个人会被切成两条轨迹、每条都重认一次，轨迹边界上还会来回换人。
                    active.removeAll { frame - $0.lastFrame > 4 }
                    var used = Set<Int>()
                    var out: [PreFace] = []
                    for obs in pObs {
                        let box = SwapVision.pixelBox(obs.boundingBox, pw, ph)
                        let side = Double(min(box.width, box.height))
                        if side < 12 { continue }      // 比这还小的不跟踪：检测噪声
                        let (pp, pn) = SwapVision.sendPoints(face: obs, w: pw, h: ph)
                        guard pp.count == 5 else { continue }
                        var best = -1
                        var bestIoU = 0.0
                        for (ti, t) in active.enumerated()
                        where !used.contains(t.id) && SwapVision.sameScale(box, t.lastBox) {
                            let v = iou(box, t.lastBox)
                            if v > bestIoU { bestIoU = v; best = ti }
                        }
                        // 框跳得快（转头、走动）时相邻帧的 IoU 会掉到 0.25 以下：再按中心距离捞一次。
                        // 不捞的话同一个人被切成好几条轨迹，每条都要重算身份，轨迹边界上人还会来回换。
                        if best < 0 || bestIoU < 0.25 {
                            var near = -1
                            var nearD = Double.greatestFiniteMagnitude
                            for (ti, t) in active.enumerated()
                            where !used.contains(t.id) && SwapVision.sameScale(box, t.lastBox) {
                                let dx = Double(box.midX - t.lastBox.midX)
                                let dy = Double(box.midY - t.lastBox.midY)
                                let d = (dx * dx + dy * dy).squareRoot()
                                let lim = 0.6 * max(Double(box.width), Double(box.height), Double(t.lastBox.width))
                                if d <= lim, d < nearD { nearD = d; near = ti }
                            }
                            if near >= 0 { best = near; bestIoU = 0.25 }
                        }
                        if best >= 0, bestIoU >= 0.25 {
                            used.insert(active[best].id)
                            var t = active[best]
                            t.lastBox = box
                            t.lastFrame = frame
                            // 轨迹开头那一帧可能是运动糊的：在机上再采一次身份，余弦更高的那次说了算。
                            // 脸太小时不采（上采样出来的余弦不算数），等它长到 floorPx 再采。
                            if t.samples < 2, frame >= t.sampleAt, side >= floorPx {
                                let got = identify(pb, w: pw, h: ph, pts: pp, src: pn, side: side)
                                if got.member >= 0, got.cos > t.cos {
                                    let prev = t.cos
                                    t.member = got.member
                                    t.cos = got.cos
                                    trackMember[t.id] = got.member
                                    if trackLog.count < 40 {
                                        trackLog.append("轨迹 \(t.id) 第 \(frame) 帧复采：\(members[got.member].targetLabel)"
                                            + " 余弦 \(String(format: "%.3f", got.cos))（原来 \(String(format: "%.3f", prev))）")
                                    }
                                }
                                t.samples += 1
                                t.sampleAt = frame + 10
                            }
                            active[best] = t
                            out.append(PreFace(pts: pp, side: side, src: pn, box: box,
                                               track: t.id, member: t.member))
                        } else {
                            let id = nextTrack
                            nextTrack += 1
                            // 够不上 floorPx 的不算脸：这一帧不认，轨迹先留着，等它长到门槛再采
                            let canId = side >= floorPx
                            let got = canId
                                ? identify(pb, w: pw, h: ph, pts: pp, src: pn, side: side)
                                : (member: -1, best: -1, cos: -9.0, note: "不是脸")
                            let member = got.member
                            let t = LiveTrack(id: id, member: member, cos: got.cos, lastBox: box,
                                              lastFrame: frame, samples: canId ? 1 : 0,
                                              sampleAt: canId ? frame + 10 : frame)
                            if member >= 0 { trackMember[id] = member }
                            active.append(t)
                            if trackLog.count < 40 {
                                let near: String
                                if !canId {
                                    near = "不是脸，先不认（要 "
                                        + String(format: "%.0f", floorPx) + " px）"
                                } else if got.cos > -8 {
                                    near = got.best >= 0
                                        ? "最近 \(members[got.best].targetLabel) 余弦 \(String(format: "%.3f", got.cos))"
                                        : "跟目标表都不像（最高 \(String(format: "%.3f", got.cos))）"
                                } else {
                                    near = "身份没量成：\(got.note)"
                                }
                                trackLog.append("轨迹 \(id) 第 \(frame) 帧起：短边 \(String(format: "%.0f", side)) px｜\(near)"
                                    + (member >= 0 ? " → 换成「\(members[member].sourceLabel)」" : " → 不动"))
                            }
                            out.append(PreFace(pts: pp, side: side, src: pn, box: box,
                                               track: id, member: member))
                        }
                    }
                    preFrames.append(out)
                    if preFrames.count % 150 == 0 {
                        let el = Double(DispatchTime.now().uptimeNanoseconds - pre0) / 1_000_000_000
                        let per = el / Double(preFrames.count)
                        let estP = Int(src.duration * max(src.fps, 1))
                        let left = estP > preFrames.count ? String(format: "%.0f", per * Double(estP - preFrames.count)) : "0"
                        say("  预检到第 \(preFrames.count) 帧｜已用 \(String(format: "%.1f", el)) s｜约还需 \(left) s"
                            + "｜足迹 \(SwapFacts.footprintMB()) MB")
                    }
                }
            }
            if pr.status == .reading { pr.cancelReading() }
        }
        let preWall = Double(DispatchTime.now().uptimeNanoseconds - pre0) / 1_000_000_000
        // 轨迹定人的最终答案回填到每一帧，再逐轨迹平滑（一条轨迹上的点属于同一张脸；
        // 平滑只看本轨迹，缺口两边不会拽向 0）
        var trackFrames: [Int: [(frame: Int, idx: Int)]] = [:]
        for f in 0..<preFrames.count {
            for i in 0..<preFrames[f].count {
                let id = preFrames[f][i].track
                preFrames[f][i].member = trackMember[id] ?? -1
                trackFrames[id, default: []].append((f, i))
            }
        }
        var smoothedTracks = 0
        for (tid, seq) in trackFrames {
            let raw = seq.map { preFrames[$0.frame][$0.idx].pts }
            let sm = SwapVision.smoothTrack(raw)
            guard sm.count == raw.count else { continue }
            for k in 0..<sm.count { preFrames[seq[k].frame][seq[k].idx].pts = sm[k] }
            smoothedTracks += 1
        }
        let faceCount = preFrames.reduce(0) { $0 + $1.count }
        let matchedCount = preFrames.reduce(0) { $0 + $1.filter { $0.member >= 0 }.count }
        if !preFrames.isEmpty {
            say("预检 \(preFrames.count) 帧（脸 \(faceCount) 个／挂上目标 \(matchedCount) 个）｜轨迹 \(nextTrack) 条"
                + "（平滑 \(smoothedTracks) 条）｜墙钟 \(String(format: "%.1f", preWall)) s"
                + "｜解码 \(SwapUtil.stat(preDecodeMs))｜检测 \(SwapUtil.stat(preDetectMs)) ms/帧")
            for line in trackLog.prefix(40) { say("  " + line) }
            if nextTrack > 40 { say("  （轨迹日志只留前 40 条，其余看逐帧计数）") }
        } else {
            say("预检没跑成（reader 起不来或 0 帧）⇒ 这一退回逐帧现检、不平滑，并在当场给每张脸算身份")
        }

        guard let reader = try? AVAssetReader(asset: src.asset) else { return fail("AVAssetReader 建不起来") }
        let vOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: [src.track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.videoComposition = src.vc
        reader.add(vOut)

        guard let writer = try? AVAssetWriter(outputURL: out, fileType: .mp4) else { return fail("AVAssetWriter 建不起来") }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: src.outW,
            AVVideoHeightKey: src.outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: Int(src.fps * 2),
                AVVideoExpectedSourceFrameRateKey: Int(src.fps),
            ],
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        vIn.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: src.outW,
            kCVPixelBufferHeightKey as String: src.outH,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(vIn) else {
            return fail("canAdd 为假：这套 outputSettings 本机不支持（\(src.outW)x\(src.outH) h264）")
        }
        writer.add(vIn)

        // 音频：原样搬过去（不解码不重编）。这一段整条是尽力而为，挂了也不许拖累画面。
        var aIn: AVAssetWriterInput?
        var aOut: AVAssetReaderTrackOutput?
        if let at = src.asset.tracks(withMediaType: .audio).first {
            let fds = at.formatDescriptions
            // 空数组才没提示；非空时这个元素本身就是 CMFormatDescription（SDK 里 `as?` 到 CF 类型是 error：恒成立）
            let hint: CMFormatDescription? = fds.isEmpty ? nil : (fds[0] as! CMFormatDescription)
            var sub = "-"
            if let h = hint {
                let t = CMFormatDescriptionGetMediaSubType(h)
                let bs = [UInt8((t >> 24) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8((t >> 8) & 0xFF), UInt8(t & 0xFF)]
                    .filter { $0 >= 32 && $0 < 127 }
                sub = String(decoding: bs, as: UTF8.self)
            }
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            ai.expectsMediaDataInRealTime = false
            let ao = try? AVAssetReaderTrackOutput(track: at, outputSettings: nil)
            // 三种失败分开报：上一版挤成一句「建不出透传或 canAdd 为假」，死在哪一环看不出来
            if hint == nil {
                say("音频 这条音轨的 formatDescriptions 是空的（\(fds.count) 条）→ 没提示可给")
            }
            if ao == nil {
                say("音频 reader 的透传输出建不出来 → 成片没声音")
            } else if !writer.canAdd(ai) {
                say("音频 canAdd 为假（子类型 \(sub)）→ 成片没声音")
            } else if let a = ao {
                writer.add(ai)
                reader.add(a)
                aIn = ai
                aOut = a
                say("音频 原样搬运（不解码不重编）：子类型 \(sub)｜提示取自音轨自己的 formatDescriptions"
                    + "｜往前喂的顶＝画面末尾再多 0.4 s｜前沿自己记秒数（某块时戳回读无效也不停下，照块长往前累加）")
            }
        } else {
            say("音频 这条片子没有音轨")
        }

        do { try writer.startWriting() } catch {
            reader.cancelReading()
            return fail("startWriting 抛错: \(error)")
        }
        writer.startSession(atSourceTime: .zero)
        // 不显式开读，copyNextSampleBuffer 第一下就回 nil ⇒ 看起来"跑完了"其实 0 帧
        guard reader.startReading() else {
            writer.cancelWriting()
            try? fm.removeItem(at: out)
            return fail("reader startReading 失败：\(reader.error?.localizedDescription ?? "-")")
        }

        var detectMs: [Double] = [], alignMs: [Double] = [], netMs: [Double] = [], pasteMs: [Double] = []
        var appendMs: [Double] = [], decodeMs: [Double] = [], sampleMs: [Double] = [], resids: [Double] = []
        /// 裁脸＝warpCrop 那一整块（含缓冲锁）；逐帧整次＝engine.swap 整趟调用（建输入＋装字典＋predict＋取输出摊平）。
        /// 这两格之前一毫秒都没量，netMs 只框住 predict 那一句，所以 每帧合计 一直是个被低估的数。
        var warpMs: [Double] = [], frameAllMs: [Double] = []
        var residsSwap: [Double] = [], facePx: [Double] = []
        var cosList: [String] = []
        var made = 0, swapped = 0, swappedFaces = 0, noFace = 0, smallFace = 0, fitFail = 0
        var mirror = 0, netFail = 0, poolMiss = 0
        var preHit = 0, preFramesHit = 0, preNoFace = 0, liveDetect = 0, trackMiss = 0, unmatched = 0
        // preHit／preFramesHit＝这帧的脸取自预检（按张／按帧）｜preNoFace＝预检判这格本来就没脸
        // trackMiss＝预检跑了但帧号越界｜unmatched＝有脸、但跟目标表都不像（不动的那几张）
        let hasTrack = !preFrames.isEmpty      // 预检整个没跑成时出片这趟退回逐帧现检（不平滑）
        var probeLeft = 6                       // 「没脸」帧只挑前 6 帧做二次检测对照
        var pointSrc = "—"
        var why = ""
        // CMTime 的 == .invalid 在机上不可信：0.10 那趟 6019 帧里「音频 起点比画面晚」逐块重印，
        // 印出来的还是那块自己的绝对时间＝那个判断一直为真。首块只认 Bool，不认 CMTime。
        var basePTS: CMTime = .zero
        var haveBase = false
        let mem0 = SwapFacts.footprintMB()
        var memMax = mem0
        let wall0 = DispatchTime.now().uptimeNanoseconds
        var lastMark = wall0

        // 音频跟画面在同一趟里交替喂，绝不等到整条画面跑完才开始搬音轨：
        // 挂着一条音轨输入却一块不喂，编码队列中途就不收画面了（第 9 轮 418 帧只走到 30 帧，随后闪退）。
        // 交出去给 writer 的块一律不许 CMSampleBufferInvalidate——append 只是入队，取数据在另一条线程上。
        // 10-13 对上机四条片子的账：画面全停在「编码器队列 15 秒不收」，停止点＝最后喂进去那块音频的起点。
        // muxer 是按时间交错的，音轨 frontier 落到画面后头就不收画面了，
        // 而老写法只在 append 成功之后才喂音频——画面不收、音频不喂，两边互等死锁。
        // 所以这一版：① 喂到画面前面 2 秒（见调用处）② 音频队列满了不当场干等，下一帧再来 ③ 音轨先到末尾就立刻关闸。
        var aOK = 0, aBad = 0, aNote = ""
        // 音频前沿自己记秒数，不信时戳回读：这条轨上有块的 PTS 读出来是无效的，
        // 而 CMTimeCompare 摊上无效值恒回 0 ⇒ 旧写法把「比不出大小」判成「早就喂够了」，
        // 从此不再向 reader 取下一块，画面就停在最后一块有效音频的起点上（0.16 上机：一条停在第 36 帧，
        // 两条长片尾巴少 63/79/109 帧，四处日志印的都是「音频喂到 nan s」）。
        var aFedSec: Double = 0
        var aHaveFed = false
        var aDone = false
        // 音频往前喂的顶＝画面这条轨的末尾再多 0.4 秒：顶要是收在画面末尾之前，
        // 最后那几帧（PTS＝画面末尾−1/帧率）就压着音频一头，muxer 不收，成片尾巴缺帧。
        // 不是容器长度：容器常带一段比画面长的音轨尾巴，喂满它成片就变成结尾有声音没画面。
        let vDur = CMTimeGetSeconds(src.track.timeRange.duration)
        let picLen = vDur > 0.1 ? vDur : src.duration
        let audioCeil = CMTimeMakeWithSeconds(max(0.0, picLen + 0.4), preferredTimescale: 600)
        func pumpAudio(until pts: CMTime) {
            guard let ai = aIn, let ao = aOut, aNote.isEmpty, !aDone else { return }
            let ptsSec = CMTimeGetSeconds(pts)
            while writer.status == .writing {
                if aHaveFed && aFedSec >= ptsSec { return }
                if !ai.isReadyForMoreMediaData { return }
                guard let s = ao.copyNextSampleBuffer() else {
                    if writer.status == .writing && reader.status == .reading {
                        aNote = "音轨已到末尾（读到 \(aOK) 块）"
                    } else {
                        aNote = "音轨停止：writer \(writerName(writer.status))｜reader \(readerName(reader.status))｜读到 \(aOK) 块"
                    }
                    // 音轨比画面短：当场关音频那条闸，不然 muxer 一直等音轨，画面最后那截永远写不进去
                    ai.markAsFinished()
                    aDone = true
                    return
                }
                let sPTS = CMSampleBufferGetPresentationTimeStamp(s)
                let sec = CMTimeGetSeconds(sPTS)
                let dur = CMTimeGetSeconds(CMSampleBufferGetDuration(s))
                let step = dur.isFinite && dur > 0 ? dur : 0
                if sec.isFinite { aFedSec = max(aFedSec, sec + step) } else { aFedSec += step }
                let aStart = String(format: "%.0f", (sec.isFinite ? sec : 0) * 1000)
                let vStart = String(format: "%.0f", CMTimeGetSeconds(basePTS) * 1000)
                let isFirst = !aHaveFed
                aHaveFed = true
                if ai.append(s) {
                    aOK += 1
                    if isFirst {
                        say("音频 头一块进去了（\(aStart) ms 处）｜画面头一块起点 \(vStart) ms"
                            + (haveBase ? "" : "（画面的数还没记上，这条别看）")
                            + "｜这一版两条轨都不移位，起点不同成片口型就偏")
                    }
                } else {
                    aBad = 1
                    aNote = "第 \(aOK + 1) 块 append 被拒｜writer \(writerName(writer.status))"
                        + " \(writer.error?.localizedDescription ?? "-")"
                    return
                }
            }
            if writer.status != .writing { aNote = "writer 已不是 writing（\(writerName(writer.status))）" }
        }

        // 整片复用同几块数组：几千帧每帧新造 0.2 MB 是给分配器添垃圾
        let side = FsxGeo.sideSwap
        var att = [Float](repeating: 0, count: 3 * side * side)      // 目标这一帧的 256 裁片＝换脸网的入参
        var face = [Float](repeating: 0, count: 3 * side * side)     // 换出来的那张脸（已量化到 8 位）
        var f112 = [Float](repeating: 0, count: 3 * FsxGeo.side112 * FsxGeo.side112)   // 复测：256 缩到 112
        var c112 = [Float](repeating: 0, count: 3 * FsxGeo.side112 * FsxGeo.side112)   // 复测：从成片帧直接裁 112
        var pasteScratch = FsxGeo.PasteScratch()   // 贴回的工作数组一整趟复用（每帧现造是几百 KB 分配＋清零）
        var usedMember = -1                        // 换脸网里此刻装着哪一位的身份证：同一位连着换就不重装

        while why.isEmpty {
            var ended = ""
            autoreleasepool {
                let td0 = DispatchTime.now().uptimeNanoseconds
                guard let sb = vOut.copyNextSampleBuffer() else { ended = "片源到末尾"; return }
                defer { CMSampleBufferInvalidate(sb) }
                guard reader.status == .reading else {
                    ended = "reader 状态 \(reader.status.rawValue): \(reader.error?.localizedDescription ?? "-")"; return
                }
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { ended = "sample 里没有像素缓冲"; return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                if !haveBase { basePTS = pts; haveBase = true }
                let rel = CMTimeSubtract(pts, basePTS)

                var mine: CVPixelBuffer?
                if let pool = adaptor.pixelBufferPool { mine = SwapTech.poolBuffer(pool) }
                if mine == nil {
                    mine = SwapTech.pixelBuffer(src.outW, src.outH).pb
                    poolMiss += 1
                }
                guard let dst = mine else { ended = "拿不出成片缓冲"; return }
                guard SwapTech.copyRows(from: pb, to: dst) else { ended = "拷帧失败"; return }
                decodeMs.append(Double(DispatchTime.now().uptimeNanoseconds - td0) / 1_000_000)

                let w = CVPixelBufferGetWidth(dst), h = CVPixelBufferGetHeight(dst)
                let t1 = DispatchTime.now().uptimeNanoseconds
                // 每帧的脸及其目标从预检那一趟按同一帧号取（已平滑、已挂目标）。
                // 退回当场检测只留两种：预检整个没跑成（preFrames 空）、帧号越界（两趟读出来的长度不一致）。
                // 预检里这帧没脸＝这帧本来就不换，不重检：同一把尺重检也是 0 张，只多花钱。
                var faces: [PreFace] = []
                var liveCount = -1          // ≥0 只在当场真检过时有效：给「没脸」那两行对照用
                if made < preFrames.count {
                    faces = preFrames[made]
                    preHit += faces.count
                    preFramesHit += 1
                    if faces.isEmpty { preNoFace += 1 }
                } else {
                    if hasTrack { trackMiss += 1 }
                    liveDetect += 1
                    let (obs, derr) = SwapVision.faces(dst, req)
                    if !derr.isEmpty { say("检测抛错：\(derr)") }
                    liveCount = obs.count
                    // y 口径没定过就当场判：这一路没有源脸照片可判时，默认值当结论会把整片 5 点映成镜像
                    if SwapVision.yTopLeftOrigin == nil {
                        for i in obs.indices {
                            if let line = SwapVision.settleOriginStrict(face: obs[i]) {
                                say("y 原点靠第 \(made) 帧这一帧判出来（这一趟没有预检轨迹）：" + line)
                                break
                            }
                        }
                    }
                    // 现检这条路没有预检轨迹可用：当场给每张脸算一次身份再比目标表（只在预检整趟失败时走）
                    for obs1 in obs {
                        let box = SwapVision.pixelBox(obs1.boundingBox, w, h)
                        let side1 = Double(min(box.width, box.height))
                        if side1 < 12 { continue }
                        let (p, n) = SwapVision.sendPoints(face: obs1, w: w, h: h)
                        guard p.count == 5 else { continue }
                        // 现检这条路也一样：够不上 floorPx 的不量身份
                        let got = side1 >= floorPx
                            ? identify(dst, w: w, h: h, pts: p, src: n, side: side1)
                            : (member: -1, best: -1, cos: -9.0, note: "不是脸")
                        faces.append(PreFace(pts: p, side: side1, src: n, box: box,
                                             track: -1, member: got.member))
                    }
                }
                detectMs.append(Double(DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000)

                var did = false
                var frameFaces = 0
                for (fi, ff) in faces.enumerated() {
                    // 两笔账分开：太小＝补丁贴出来也没用；表外＝量过、跟目标表都不像
                    if ff.side < args.minFacePx {
                        smallFace += 1
                        continue
                    }
                    if ff.member < 0 {
                        unmatched += 1
                        continue
                    }
                    guard ff.pts.count == 5, let pl = FsxGeo.place(pts: ff.pts, src: ff.src, shortSide: ff.side)
                    else {
                        fitFail += 1
                        continue
                    }
                    pointSrc = pl.src
                    if pl.mirrored {
                        // 5 点的手性与模板相反＝y 口径判反了，这张脸换出来是一张翻面的脸，宁可这张脸不动
                        // （相似拟合表达不了镜像，det＝a²＋b² 恒正，只能这样判）
                        mirror += 1
                        if mirror <= 3 {
                            let ptTxt = pl.pts.map { String(format: "%.0f,%.0f", $0.x, $0.y) }.joined(separator: " ")
                            say("第 \(made) 帧第 \(fi + 1) 张脸 5 点手性与模板相反（y 口径判反）"
                                + "｜叉 \(String(format: "%.0f", pl.chir.nose))／\(String(format: "%.0f", pl.chir.mouth))"
                                + "｜点位 \(pl.src)｜短边 \(String(format: "%.0f", pl.shortSide)) px｜5 点 \(ptTxt)→这张不换")
                        }
                        continue
                    }
                    let t2 = DispatchTime.now().uptimeNanoseconds
                    resids.append(pl.residPx)
                    residsSwap.append(pl.residSwap)
                    facePx.append(pl.shortSide)
                    alignMs.append(Double(DispatchTime.now().uptimeNanoseconds - t2) / 1_000_000)
                    let tw = DispatchTime.now().uptimeNanoseconds
                    let took = SwapTech.withPixels(dst) { base, bpr -> Bool in
                        FsxGeo.warpCrop(UnsafeRawPointer(base), bytesPerRow: bpr, w: w, h: h,
                                        fwd: pl.fwdSwap, size: side, out: &att)
                    }
                    warpMs.append(Double(DispatchTime.now().uptimeNanoseconds - tw) / 1_000_000)
                    var r: (face: [Float], ms: Double, note: String) =
                        (face: [], ms: 0.0, note: "裁不出 256")
                    let tf = DispatchTime.now().uptimeNanoseconds
                    if took == true {
                        // 一张帧里可能有两三个人：换到谁就把谁的身份证装上（几百字节，不是重新读盘）
                        if usedMember != ff.member {
                            let put = engine.useIdentity(emb: members[ff.member].sourceEmb)
                            if !put {
                                netFail += 1
                                if netFail <= 3 {
                                    say("第 \(made) 帧 目标表第 \(ff.member + 1) 位的替换脸装不上→这张脸不动")
                                }
                                frameAllMs.append(Double(DispatchTime.now().uptimeNanoseconds - tf) / 1_000_000)
                                continue
                            }
                            usedMember = ff.member
                        }
                        r = engine.swap(cropSwap_01: att)
                    }
                    frameAllMs.append(Double(DispatchTime.now().uptimeNanoseconds - tf) / 1_000_000)
                    if r.face.count != 3 * side * side {
                        // 网没回话：这一帧原样交出去，绝不许丢帧（丢了成片就比素材短）
                        netFail += 1
                        if netFail <= 3 { say("第 \(made) 帧网没回话：\(r.note)→这张脸原样交") }
                        continue
                    }
                    netMs.append(r.ms)
                    face = r.face
                    let tm = DispatchTime.now().uptimeNanoseconds
                    let pasted = SwapTech.withPixels(dst) { base, bpr -> Bool in
                        FsxGeo.pasteBack(base, bytesPerRow: bpr, w: w, h: h, face: face,
                                         fwd: pl.fwdSwap, scratch: &pasteScratch)
                    }
                    pasteMs.append(Double(DispatchTime.now().uptimeNanoseconds - tm) / 1_000_000)
                    if pasted == true {
                        did = true
                        frameFaces += 1
                    } else {
                        netFail += 1
                        if netFail <= 3 { say("第 \(made) 帧贴回没成（256 方块映不进这一帧）→这张脸原样交") }
                        continue
                    }

                    // 每 sampleEvery 帧复测一次"换完这张脸还剩多少这张替换脸的身份"
                    if made % max(1, args.sampleEvery) == 0 {
                        let t4 = DispatchTime.now().uptimeNanoseconds
                        let srcEmb = members[ff.member].sourceEmb
                        // 换后那一张直接从成片帧按同一组点位重裁 112：量的就是最终画面，不是网吐出来的那半张
                        var after = (emb: [Float](), rawNorm: 0.0, ms: 0.0, note: "成片裁不出 112")
                        let cut = SwapTech.withPixels(dst) { base, bpr -> Bool in
                            FsxGeo.warpCrop(UnsafeRawPointer(base), bytesPerRow: bpr, w: w, h: h,
                                            fwd: pl.fwd112, size: FsxGeo.side112, out: &c112)
                        }
                        if cut == true { after = engine.embedding(crop112_01: c112) }
                        // 换前那一张＝目标本人这一帧的脸（同一帧的 256 裁片缩到 112）
                        FsxGeo.resizePlanar(att, from: side, to: FsxGeo.side112, into: &f112)
                        let before = engine.embedding(crop112_01: f112)
                        sampleMs.append(Double(DispatchTime.now().uptimeNanoseconds - t4) / 1_000_000)
                        // -9 不是「不像」，是这把尺没量成。只印 -9.000 的话「空存档」「维度不对」「全零」
                        // 这三种在机上分不开，所以量不成就把量不成的原因写出来。
                        let cSrc = FsxMath.cosine(after.emb, srcEmb)
                        let cTgt = FsxMath.cosine(before.emb, srcEmb)
                        // 换后<->换前 不吃存档身份：专答「这张脸到底动没动」——
                        // 低＝动过，接近 1＝网基本原样交（或这人本来就和视频里的是同一个人）。
                        let cSelf = FsxMath.cosine(after.emb, before.emb)
                        let sSrc = cSrc < -8 ? "量不出（" + FsxMath.whyNot(cSrc, after.emb, srcEmb) + "）" : String(format: "%.3f", cSrc)
                        let sTgt = cTgt < -8 ? "量不出（" + FsxMath.whyNot(cTgt, before.emb, srcEmb) + "）" : String(format: "%.3f", cTgt)
                        let sSelf = cSelf < -8 ? "量不出（" + FsxMath.whyNot(cSelf, after.emb, before.emb) + "）" : String(format: "%.3f", cSelf)
                        cosList.append("第 \(made) 帧 \(members[ff.member].targetLabel)→「\(members[ff.member].sourceLabel)」"
                            + " 换后<->源 \(sSrc)｜换前<->源 \(sTgt)｜换后<->换前 \(sSelf)"
                            + (after.note.isEmpty ? "" : "｜" + after.note))
                        say("  身份 " + cosList.last!)
                    }
                }
                swappedFaces += frameFaces
                if faces.isEmpty {
                    noFace += 1
                    // 当场对照：默认档 0 张脸的，换老一版检测器（revision1）再检同一帧。
                    // 这个 SDK 的 face 请求已经没有 accuracy 旋钮了，能换口径的只有 revision。
                    // 分不清「漏检」还是「这帧真没脸」时，整片跑完也判不了，只能这样钉死。
                    if probeLeft > 0 {
                        probeLeft -= 1
                        let req2 = VNDetectFaceLandmarksRequest()
                        req2.revision = VNDetectFaceLandmarksRequestRevision1
                        let (o2, e2) = SwapVision.faces(dst, req2)
                        let s2 = SwapVision.largest(o2, w: w, h: h)
                        let defTxt = liveCount < 0 ? "预检那趟 0 张" : "\(liveCount) 张"
                        say("  没脸对照 第 \(made) 帧：默认档 \(defTxt)｜rev1 老检测器 \(o2.count) 张"
                            + (s2 == nil ? "" : "｜最大短边 \(String(format: "%.0f", s2!.shortSide)) px")
                            + (e2.isEmpty ? "" : "｜\(e2)"))
                    }
                }
                if !did && made < 3 {
                    let whyTxt = faces.isEmpty ? "这一帧没检到脸"
                        : "检到 \(faces.count) 张脸，挂上目标表 \(frameFaces) 张"
                    say("第 \(made) 帧没换上脸（\(whyTxt)）")
                }

                let t5 = DispatchTime.now().uptimeNanoseconds
                // 音频往前喂 2 秒，但不越过画面轨的末尾：越过去成片就会比画面长出一截
                var ahead = CMTimeAdd(rel, CMTime(value: 2, timescale: 1))
                if CMTimeCompare(ahead, audioCeil) > 0 { ahead = audioCeil }
                pumpAudio(until: ahead)
                var spins = 0
                while !vIn.isReadyForMoreMediaData {
                    spins += 1
                    // 0.5 上机证伪了我上一轮的归因：闸放宽到 60 秒，编码器在第 397 帧照样连着 60 秒不收
                    // （源 418 帧的 PTS 逐帧 1/30 严格单调，不是时间戳的事）。是真停，不是打嗝，等 60 秒纯白等。
                    if spins > 3_000 {
                        let fed = aHaveFed ? String(format: "%.3f", aFedSec) : "-"
                        let an = aNote.isEmpty ? "" : "｜\(aNote)"
                        ended = "编码器队列 15 秒不收（第 \(made) 帧，PTS \(String(format: "%.3f", CMTimeGetSeconds(rel))) s"
                            + "｜音频喂到 \(fed) s、\(aOK) 块\(an)）"
                        return
                    }
                    if spins % 400 == 0 {
                        say("  编码器不收第 \(made) 帧，已等 \(String(format: "%.1f", Double(spins) * 0.005)) s")
                    }
                    pumpAudio(until: ahead)   // 卡住的这一会儿正是该往前喂音频的时候
                    Thread.sleep(forTimeInterval: 0.005)
                }
                var tries = 0
                while !adaptor.append(dst, withPresentationTime: rel) {
                    tries += 1
                    if writer.status == .failed {
                        // -11846 operationInterrupted 是 iOS 把进程冻住时写盘那头的回话：锁屏或切后台就这个。
                        // 上机 22:33 那一趟就是这么停在第 26 帧的（墙钟 9.5 分钟只走 26 帧），
                        // 不点名就会被当成「换脸慢」。
                        let iv = (writer.error as? AVError)?.code == .operationInterrupted
                        ended = "append 失败，writer failed: \(writer.error?.localizedDescription ?? "-")"
                            + (iv ? "｜这趟中途被系统冻住了（锁屏／切后台）：出片要亮屏在前台跑完" : "")
                        return
                    }
                    if tries > 400 { ended = "append 连续失败 400 轮"; return }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                appendMs.append(Double(DispatchTime.now().uptimeNanoseconds - t5) / 1_000_000)
                if did { swapped += 1 }
                made += 1
                let now = SwapFacts.footprintMB()
                if now > memMax { memMax = now }
                if now > args.footprintStopMB {
                    ended = "足迹 \(now) MB 超收兵线 \(args.footprintStopMB) MB"; return
                }
                if made % 60 == 0 {
                    let el = Double(DispatchTime.now().uptimeNanoseconds - wall0) / 1_000_000_000
                    let per = el / Double(max(1, made))
                    // 近 60 帧那一格的均速单独报：A13 跑五分钟会热降频，只看整趟均速看不出来
                    let win = Double(DispatchTime.now().uptimeNanoseconds - lastMark) / 1_000_000 / 60.0
                    lastMark = DispatchTime.now().uptimeNanoseconds
                    say("换到第 \(made)/\(estFrames) 帧｜已用 \(String(format: "%.1f", el)) s"
                        + "｜约还需 \(String(format: "%.1f", per * Double(max(0, estFrames - made)))) s｜足迹 \(now) MB"
                        + "｜近 60 帧每帧 \(String(format: "%.0f", win)) ms"
                        + "｜音频 \(aOK) 块")
                }
            }
            if !ended.isEmpty { why = ended }
        }
        // 画面这条走到哪一步、reader/writer 各是什么状态、因何停：音频那块紧接着要搬，死因得先落在盘上
        let stopWhy = why.isEmpty ? "自然到末尾" : "因：\(why)"
        say("画面这条结束 读到 \(made)/\(estFrames) 帧｜\(stopWhy)"
            + "｜reader \(readerName(reader.status)) \(reader.error?.localizedDescription ?? "-")"
            + "｜writer \(writerName(writer.status)) \(writer.error?.localizedDescription ?? "-")")
        // 「预估」是我拿容器时长×帧率算的，容器常比画面轨长一截：少的那些帧从来就不在画面轨里。
        // 上一版只印「读到 397/418」，读的人以为丢了 21 帧。
        if estFrames > made {
            let gap = estFrames - made
            let gapS = String(format: "%.2f", Double(gap) / max(src.fps, 1))
            let trackS = String(format: "%.2f", picLen)
            let contS = String(format: "%.2f", src.duration)
            say("      读到比预估少 \(gap) 帧（\(gapS) s）：画面轨 \(trackS) s／容器 \(contS) s，差的那截只有声音没有画面，不是丢帧")
        }

        // 音频收尾：搬运已在画面循环里做完（pumpAudio 往前喂 2 秒），这里只补尾巴、关闸、报账
        if let ai = aIn {
            if !aDone {
                pumpAudio(until: audioCeil)
                if aNote.isEmpty { aNote = "跟到画面末尾" }
            }
            let fed = aHaveFed ? String(format: "%.2f", aFedSec) : "-"
            say("音频 \(aOK) 块原样搬过去（拒 \(aBad) 块）｜\(aNote)"
                + "｜音频前沿 \(fed) s／画面 \(String(format: "%.2f", picLen)) s")
            if !aDone { ai.markAsFinished() }
        }

        vIn.markAsFinished()
        if reader.status == .reading { reader.cancelReading() }
        let tail0 = DispatchTime.now().uptimeNanoseconds
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        let tailMs = Double(DispatchTime.now().uptimeNanoseconds - tail0) / 1_000_000
        guard writer.status == .completed else {
            let iv = (writer.error as? AVError)?.code == .operationInterrupted
            return fail("writer 没收尾 status=\(writer.status.rawValue): \(writer.error?.localizedDescription ?? "-")"
                + (iv ? "（这一趟中途被系统冻住了：锁屏或切后台；出片要亮屏在前台跑完）" : ""))
        }
        let attrsOfOut = try? fm.attributesOfItem(atPath: out.path)
        let size = (attrsOfOut?[.size] as? NSNumber)?.int64Value ?? 0
        let wall = Double(DispatchTime.now().uptimeNanoseconds - wall0) / 1_000_000_000 + preWall
        let madeSec = Double(made) / max(src.fps, 1)
        // 预检那一趟的钱要算进每帧合计：它整片先跑了一遍解码＋检测，出片这趟从此不再检测（detectMs 里那格因此接近 0）
        let perFrame = avg(preDecodeMs) + avg(preDetectMs) + avg(decodeMs) + avg(detectMs) + avg(alignMs) + avg(warpMs) + avg(frameAllMs) + avg(pasteMs) + avg(appendMs)
        // 只框住 predict 那一句的另一式：跨版比速度只比这一格（上一版报的就是这种口径）
        let perFrameNet = avg(preDecodeMs) + avg(preDetectMs) + avg(decodeMs) + avg(detectMs) + avg(alignMs) + avg(netMs) + avg(pasteMs) + avg(appendMs)
        // 预览档＝单趟（解码只跑一遍、检测按真跑过的那格）＋不做提交（不进编码器）；贴回借整片那一格的数＝上限
        let pvUnit = avg(decodeMs) + max(avg(preDetectMs), avg(detectMs)) + avg(warpMs) + avg(frameAllMs) + avg(pasteMs)
        say("换完 \(made) 帧（编码器头/尾 \(SwapUtil.ms(tailMs))）"
            + "｜成片 \(String(format: "%.1f", Double(size) / 1_048_576)) MB"
            + "｜缓冲 池子给 \(made - poolMiss)／自造 \(poolMiss)"
            + "｜\(why.isEmpty ? "跑到末尾" : why)")
        say("单价 预检趟 解码 \(SwapUtil.stat(preDecodeMs))／检测 \(SwapUtil.stat(preDetectMs))")
        let detNote = trackMiss > 0 ? "（出片这趟有 \(trackMiss) 帧退回现检）" : ""
        say("      出片趟 解码 \(SwapUtil.stat(decodeMs))｜检测 \(SwapUtil.stat(detectMs))\(detNote)｜对齐 \(SwapUtil.stat(alignMs))")
        say("      换脸网 \(SwapUtil.stat(netMs))｜裁脸 \(SwapUtil.stat(warpMs))｜逐帧整次 \(SwapUtil.stat(frameAllMs))"
            + "｜贴回 \(SwapUtil.stat(pasteMs))｜提交 \(SwapUtil.stat(appendMs))"
            + "｜这一条链路逐帧只有这三刀：裁 256→一次前向→按官方那三刀贴回（没有分割网、没有高频回填、没有美白）")
        say("      注：换脸网＝只有 predict 那一句；逐帧整次＝整趟调用（建输入数组＋装字典＋predict＋取输出摊平＋量化到 8 位），两栏之差＝搬运")
        say("      贴回底边：方块往下多贴 \(FsxGeo.extDown) 格、最下面 \(FsxGeo.fadeDown) 格把 alpha 收到 0"
            + "（官方四边同宽那一刀没动：遮罩底落在 256 框第 240 格，下巴在 268 格——差的是方块自己没装进下巴；"
            + "PC 上四臂并排量过、看过片定的这一档：第 20 帧中心列 alpha 过半到 y=1337，下巴实测 1338，256 口径按 size/128 折算）")
        say("      \(engine.statsLine())｜几何自测 \(FsxGeo.selfTest())")
        say("总耗时 \(String(format: "%.1f", wall)) s（素材实到 \(String(format: "%.1f", madeSec)) s）"
            + "＝\(String(format: "%.2f", wall / max(madeSec, 0.01)))× 实时｜每帧合计 \(String(format: "%.1f", perFrame)) ms"
            + "｜身份复测每次 \(SwapUtil.stat(sampleMs))")
        say("      每帧合计把 裁脸＋逐帧整次 都计进来了；只算 predict 那一式的口径是 \(String(format: "%.1f", perFrameNet)) ms（跨版比速度用这一格）")
        say("预览试算 单趟不编码每帧 \(String(format: "%.1f", pvUnit)) ms＝解码＋检测＋裁脸＋逐帧整次＋贴回（提交那格去掉＝不进编码器；贴回借整片那一格的数＝上限）"
            + "｜16 帧/秒的格＝62.5 ms/帧，这一趟每播 1 s 要 \(String(format: "%.0f", pvUnit * 16)) ms（一秒 1000 ms）")
        say("换上人 \(swapped) 帧（共换上 \(swappedFaces) 张脸）｜没脸 \(noFace)｜太小 \(smallFace)"
            + "｜拟合没过 \(fitFail)｜镜像 \(mirror)｜网失败 \(netFail)｜跟目标表都不像 \(unmatched)｜点位 \(pointSrc)")
        var detSrcTxt = "全部当场真检 \(made) 帧（预检没跑成）"
        if hasTrack {
            detSrcTxt = "取自预检 \(preFramesHit) 帧／\(preHit) 张脸（其中没脸 \(preNoFace) 帧）｜"
                      + "帧号越界当场真检 \(trackMiss) 帧｜当场手检 \(liveDetect) 帧"
        }
        say("      点位来路 \(detSrcTxt)")
        if !resids.isEmpty {
            say("对齐残差 中位 \(String(format: "%.2f", median(resids)))／最大 \(String(format: "%.2f", resids.max() ?? 0)) px（原图像素口径）"
                + "｜折进 256 方块 中位 \(String(format: "%.2f", median(residsSwap)))／最大 \(String(format: "%.2f", residsSwap.max() ?? 0)) px")
            say("      注：原图像素那个数会随脸在片里的大小成比例放大，跨片子只能看 256 那一列；"
                + "PC 那张 ±2~4 px 容忍表是 128 口径、在 141 px 的脸上量的，折到 256 是 ±4~8 px")
            let fm = median(facePx), fmax = facePx.max() ?? 0
            say("      脸短边 中位 \(String(format: "%.0f", fm))／p90 \(String(format: "%.0f", pct(facePx, 0.9)))／最大 \(String(format: "%.0f", fmax)) px"
                + "｜256 补丁撑到最大脸＝\(String(format: "%.2f", fmax / 256.0))×（>1＝把 256 的结果放大贴，糊边成一层膜）")
        }
        say("足迹 \(mem0)→\(SwapFacts.footprintMB()) MB，本次峰值 \(memMax) MB")
        if !cosList.isEmpty {
            say("身份复测 \(cosList.count) 次（PC 参照：hyperswap_1c_256 换后<->源 0.79 上下（八帧中位 0.794），inswapper 是 0.779；"
                + "换前<->源 ≈0.1~0.3）")
            say("      换后<->换前 那一列不吃存档身份，只答「这张脸动没动」：低＝动过，接近 1＝原样交或本来就是同一个人；这一列 PC 上我没量过")
            for c in cosList.suffix(12) { say("  " + c) }
        }

        let saved = SwapTech.toPhotos(out)
        say("存相册 " + saved)
        if saved.hasPrefix("已存") {
            try? fm.removeItem(at: out)
            say("沙盒那份已删（\(out.lastPathComponent)）")
            SwapJournal.digest(rep)
            return (nil, rep.joined(separator: "\n"))
        }
        say("本地还留着 \(out.path)")
        SwapJournal.digest(rep)
        return (out, rep.joined(separator: "\n"))
    }

    private static func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
    private static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return -1 }
        let s = v.sorted()
        return s[s.count / 2]
    }
    private static func pct(_ v: [Double], _ q: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        let i = min(s.count - 1, max(0, Int((Double(s.count - 1) * min(1, max(0, q))).rounded())))
        return s[i]
    }
}

// 状态词按 rawValue 翻：这些枚举在本 SDK 里不保证每个成员都有 Swift 名字（第 11 轮就死在
// AVAssetReader.Status 没有 .paused 上）。AVAssetWriterStatus / AVAssetReaderStatus 的编号是 Objective-C 定死的。
private func writerName(_ s: AVAssetWriter.Status) -> String {
    switch s.rawValue {
    case 0: return "unknown"
    case 1: return "writing"
    case 2: return "completed"
    case 3: return "failed"
    case 4: return "cancelled"
    default: return "其他(\(s.rawValue))"
    }
}

private func readerName(_ s: AVAssetReader.Status) -> String {
    switch s.rawValue {
    case 0: return "unknown"
    case 1: return "reading"
    case 2: return "completed"
    case 3: return "paused"
    case 4: return "failed"
    case 5: return "cancelled"
    default: return "其他(\(s.rawValue))"
    }
}
