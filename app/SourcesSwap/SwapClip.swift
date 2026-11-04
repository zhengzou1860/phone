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

/// 整片真换脸：源身份（新照片跑一次那两步、已存的人从盘上直接装）→ 逐帧 检测→对齐→128 前向→贴回 → 编码器写新片。
/// 每一步的单价、身份余弦、足迹水位全部进流水；跑完存相册，成功才删沙盒那份。
///
/// 这一条链路只有两张网（脸向量网＋inswapper）和一张 512×512 的 latent 映射，
/// 逐帧的钱全在那一张 200 GMAC 的换脸网上，其余每一步都是几十字节的算术。
enum SwapClip {
    struct Args {
        var units: MLComputeUnits = .cpuOnly  // 0.39 上机四档实测：CPU 890／GPU 1043／all 1045／ANE 815 ms 一格，
                                              // all 落回的就是 GPU（比纯 CPU 慢 18 %，足迹还要 854 MB），所以默认按 CPU 钉住；
                                              // CPU 这一档也正是 CI 转换时对账用的那条 fp32 路。界面那格能换
        var longEdge: Int = 1920
        var minFacePx: Double = 40
        var sampleEvery: Int = 30
        /// 收兵线：换脸网单张权重就 554 MB（fp32）／277 MB（fp16），旧那条线四张小网定的 900 MB 会把正常跑当成越界。
        /// iPhone 11 的单进程水位线在 1.5 GB 上下，踩到就是系统直接杀进程（连一行流水都留不下），所以这条线只能往下压着留。
        var footprintStopMB: Int = 1300
    }

    /// 源身份的两条来路：新挑的照片（要跑"每人一次"那两步）或列表里已存的人（直接从盘上装）。
    enum Person {
        case photo(UIImage)
        case saved(String)
    }

    static func run(person: Person, video: URL, args: Args, onLine: @escaping (String) -> Void) -> (out: URL?, note: String) {
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

        // —— 2. 源身份：已存的人只读盘装 latent，新照片才跑下面那两步 ——
        let req = VNDetectFaceLandmarksRequest()
        var srcEmb: [Float] = []
        switch person {
        case .saved(let pid):
            guard let one = SwapIdents.load(id: pid) else {
                return fail("已存的人「\(SwapIdents.displayName(pid))」的存档读不出来"
                    + "（不是这一版写的、或字节缺了），重选一张源脸照片")
            }
            let l0 = DispatchTime.now().uptimeNanoseconds
            let put = engine.useIdentity(emb: one.emb)
            let lMs = Double(DispatchTime.now().uptimeNanoseconds - l0) / 1_000_000
            // 身份证是 L2 归一化过的⇒模长本该≈1；掉到 0.5 以下只有"这份包里的数是空的"这一种解释。
            // 空 latent 出的画面跟没换一样（他这次看到的"还是原视频的脸"），这种趟不许再往下跑。
            let eNorm = FsxEngine.norm(one.emb)
            guard put, eNorm > 0.5 else {
                return fail("已存的人「\(one.name)」用不了：身份证 \(one.emb.count) 维／模长 \(String(format: "%.4f", eNorm))"
                    + (one.emb.count == FsxNets.embDim ? "" : "（这一版要 \(FsxNets.embDim) 维，这份是旧口径写的）")
                    + "——不出片，重选一张源脸照片")
            }
            say("用已存的人「\(one.name)」：读盘＋乘 latent \(SwapUtil.ms(lMs))"
                + "｜身份证从盘上带回来 \(one.emb.count) 维／模长 \(String(format: "%.4f", eNorm))"
                + "｜跳过 ①（这一格上机实测过，每人一次）｜足迹 \(SwapFacts.footprintMB()) MB")
            say("  读档自检 \(SwapIdents.probe(id: pid))")
            srcEmb = one.emb
        case .photo(let source):
            // —— 2a. 每人一次的那两步（身份证→latent），这一版第一次在机上量出钱来 ——
            let up = SwapVision.uprightImage(source)
            guard let cg = up.cg else { return fail("源脸静帧取不出：\(up.note)") }
            let (sObs, sErr) = SwapVision.faces(cg, req)
            if !sErr.isEmpty { say("源脸检测：\(sErr)") }
            guard let sl = SwapVision.largest(sObs, w: cg.width, h: cg.height) else {
                return fail("源脸检测：这张图里没检到脸（\(up.note)）")
            }
            say("源脸：" + SwapVision.settleOrigin(face: sObs[sl.index]) + "｜短边 \(String(format: "%.0f", sl.shortSide)) px")
            let (sPts, sSrcTxt) = SwapVision.sendPoints(face: sObs[sl.index], w: cg.width, h: cg.height)
            guard let srcPlace = FsxGeo.place(pts: sPts, src: sSrcTxt, shortSide: sl.shortSide) else {
                return fail("源脸对齐失败：5 点映不进模板")
            }
            say("源脸对齐 点位=\(srcPlace.src)｜残差 \(String(format: "%.2f", srcPlace.resid128))（128 内）"
                + "＝\(String(format: "%.2f", srcPlace.residPx)) px｜缩放 \(String(format: "%.2f", srcPlace.scale))"
                + "｜手性 \(srcPlace.mirrored ? "与模板相反" : "合")")
            // 源脸排成镜像＝身份网拿到是一张翻面的人脸，整片都换不对；出片那趟同一格有这道闸，这一路以前没有
            if srcPlace.mirrored {
                return fail("源脸对齐 5 点手性与模板相反（y 口径判反）：这张源脸映不进模板，不出片")
            }
            let sPb = SwapTech.pixelBuffer(from: cg)
            guard let sbuf = sPb.pb else { return fail("源静帧 \(sPb.note)") }
            var crop112 = [Float](repeating: 0, count: 3 * FsxGeo.side112 * FsxGeo.side112)
            let warpsrc = SwapTech.withPixels(sbuf) { base, bpr -> Bool in
                FsxGeo.warpCrop(UnsafeRawPointer(base), bytesPerRow: bpr, w: cg.width, h: cg.height,
                                fwd: srcPlace.fwd112, size: FsxGeo.side112, out: &crop112)
            }
            guard warpsrc == true else { return fail("源脸裁不出 112") }
            let id0 = DispatchTime.now().uptimeNanoseconds
            let ident = engine.embedding(crop112_01: crop112)
            let idMs = Double(DispatchTime.now().uptimeNanoseconds - id0) / 1_000_000
            guard !ident.emb.isEmpty else {
                return fail("① 身份证失败：\(ident.note)（PC 参照：这一步 CPU 上几百毫秒）")
            }
            say("① 身份证 \(SwapUtil.ms(idMs))（纯网 \(SwapUtil.ms(ident.ms))，\(ident.note)）"
                + "｜模长 \(String(format: "%.1f", ident.rawNorm))｜足迹 \(SwapFacts.footprintMB()) MB"
                + "｜PC 参照同一步模长 2.84~3.72（逐维 ±0.5 上下；口径错了形状照样合法、只有模长露馅）")
            let w0 = DispatchTime.now().uptimeNanoseconds
            let put = engine.useIdentity(emb: ident.emb)
            let wMs = Double(DispatchTime.now().uptimeNanoseconds - w0) / 1_000_000
            guard put else { return fail("② latent 没乘出来（身份证 \(ident.emb.count) 维／emap \(engine.emap.count) 个数）") }
            say("② 身份证×emap＝latent \(SwapUtil.ms(wMs))｜512×512 那一乘在手机上自己走（图上那份 buff2fs 转换器不带）"
                + "｜足迹 \(SwapFacts.footprintMB()) MB")
            srcEmb = ident.emb
            let sv = SwapIdents.save(emb: ident.emb, taken: SwapIdents.list())
            say("③ 身份存档：\(sv.note)｜足迹 \(SwapFacts.footprintMB()) MB")
            if !sv.id.isEmpty {
                say("  存档自检 盘上：\(SwapIdents.probe(id: sv.id))")
            }
        }
        guard engine.hasIdentity else { return fail("整趟跑到这里还没装上身份，不出片") }

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
        say("补丁口径 贴区＝128 那张方块投回帧空间自己盖住的那一片平行四边形（官方 inswapper 的 preprocess_mask 那一刀，一刀不减）："
            + "白图随逆矩阵映回来 → >20 的格子拉成 255 → 按这块贴区量出的边长腐蚀 k=max(mask_size/10,10) "
            + "→ 再糊一刀，核长 2*max(mask_size/20,5)+1、σ 由核长现算 → out = mask*补丁 + (1−mask)*原帧。"
            + "不叠分割网、不做色彩搬运、不回填高频、不美白＝PC 那条被肉眼认过的链路里根本没有这几步，"
            + "多一步就多一处能把画面搬错的地方（对账凭据在 ci/fsx_fixtures，链路出处在 fsx/swapcore.py）。"
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

        // —— 2.5 预检趟：整片先只解码＋检测，把每帧那 5 个点存下来 ——
        // 为什么要单跑一趟：对称平滑要往后看 6 帧，出片这趟是单向流水、拿不到未来的点。
        // 只看过去的滤波本机量过＝每帧把补丁甩在头后面 16.6 px（p95 36 px），快动段直接成重影，所以不用它。
        // 钱＝这趟多一次解码＋一次检测，出片那趟从此不再检测：一进一出，每帧合计只多一次解码的钱。
        // 点位按帧号存，出片那趟同一格取；没脸的帧留空位，只为缺口附近的平滑不跳到 0 才拿最近一帧补。
        var trackPts: [[CGPoint]] = []
        var trackSide: [Double] = []
        var trackName: [String] = []
        var preDecodeMs: [Double] = [], preDetectMs: [Double] = []
        let pre0 = DispatchTime.now().uptimeNanoseconds
        say("先跑预检这一趟：整片只解码＋检测，把每帧那 5 个点存下来，再整片对称平滑（出片那趟就不再检测了）")
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
                    let pt0 = DispatchTime.now().uptimeNanoseconds
                    let (pObs, pErr) = SwapVision.faces(pb, req)
                    if !pErr.isEmpty { say("预检检测抛错：\(pErr)") }
                    preDetectMs.append(Double(DispatchTime.now().uptimeNanoseconds - pt0) / 1_000_000)
                    guard let pl = SwapVision.largest(pObs, w: pw, h: ph) else {
                        trackPts.append([]); trackSide.append(0); trackName.append("—")
                        continue
                    }
                    // y 口径在这一趟就要定下来：定晚了，整条轨迹的 5 点是映反的，平滑只会把它抹得更圆
                    if SwapVision.yTopLeftOrigin == nil {
                        say("预检 " + SwapVision.settleOrigin(face: pObs[pl.index]))
                    }
                    let (pp, pn) = SwapVision.sendPoints(face: pObs[pl.index], w: pw, h: ph)
                    trackPts.append(pp.count == 5 ? pp : [])
                    trackSide.append(pp.count == 5 ? pl.shortSide : 0)
                    trackName.append(pn)
                    if trackPts.count % 150 == 0 {
                        let el = Double(DispatchTime.now().uptimeNanoseconds - pre0) / 1_000_000_000
                        let per = el / Double(trackPts.count)
                        let estP = Int(src.duration * max(src.fps, 1))
                        let left = estP > trackPts.count ? String(format: "%.0f", per * Double(estP - trackPts.count)) : "0"
                        say("  预检到第 \(trackPts.count) 帧｜已用 \(String(format: "%.1f", el)) s｜约还需 \(left) s"
                            + "｜足迹 \(SwapFacts.footprintMB()) MB")
                    }
                }
            }
            if pr.status == .reading { pr.cancelReading() }
        }
        let preWall = Double(DispatchTime.now().uptimeNanoseconds - pre0) / 1_000_000_000
        // 空位拿最近一帧的点填（这些帧本来就不换脸，填只为让缺口两侧的平均不拽向 0）
        var filled: [[CGPoint]] = trackPts
        var lastIdx = -1
        for i in 0..<filled.count {
            if !filled[i].isEmpty { lastIdx = i }
            else if lastIdx >= 0 { filled[i] = filled[lastIdx] }
        }
        for i in stride(from: filled.count - 1, through: 0, by: -1) where filled[i].isEmpty {
            var j = i + 1
            while j < filled.count && filled[j].isEmpty { j += 1 }
            if j < filled.count { filled[i] = filled[j] }
        }
        let smTrack = SwapVision.smoothTrack(filled)
        // 抖动本身要在机上量：Vision 的点位噪声与 PC 用的 SCRFD 不是一把尺，
        // 下面这两列就是这一趟的答卷（平滑前＝逐帧现算要吃下的抖动，平滑后＝这一版剩下的）。
        var hfRaw: [Double] = [], hfSm: [Double] = [], devSm: [Double] = []
        if filled.count > 2, filled.count == smTrack.count {
            for i in 1..<(filled.count - 1) {
                guard filled[i].count == 5 else { continue }
                var r = 0.0, s = 0.0, dv = 0.0
                for p in 0..<5 {
                    let a = filled[i - 1][p], b = filled[i][p], c = filled[i + 1][p], m = smTrack[i][p]
                    r += hypot(2 * Double(b.x) - Double(a.x) - Double(c.x), 2 * Double(b.y) - Double(a.y) - Double(c.y))
                    s += hypot(2 * Double(m.x) - Double(smTrack[i - 1][p].x) - Double(smTrack[i + 1][p].x),
                               2 * Double(m.y) - Double(smTrack[i - 1][p].y) - Double(smTrack[i + 1][p].y))
                    dv += hypot(Double(b.x - m.x), Double(b.y - m.y))
                }
                hfRaw.append(r / 5); hfSm.append(s / 5); devSm.append(dv / 5)
            }
        }
        if !trackPts.isEmpty {
            say("预检 \(trackPts.count) 帧（有脸 \(trackPts.filter { !$0.isEmpty }.count)）"
                + "｜墙钟 \(String(format: "%.1f", preWall)) s"
                + "｜解码 \(SwapUtil.stat(preDecodeMs))｜检测 \(SwapUtil.stat(preDetectMs)) ms/帧")
            if !hfRaw.isEmpty {
                say("      5 点抖动 平滑前 中位 \(String(format: "%.2f", median(hfRaw)))／p90 \(String(format: "%.2f", pct(hfRaw, 0.9))) px"
                    + "｜平滑后 中位 \(String(format: "%.2f", median(hfSm)))／p90 \(String(format: "%.2f", pct(hfSm, 0.9))) px"
                    + "｜落点偏离 中位 \(String(format: "%.2f", median(devSm)))／p90 \(String(format: "%.2f", pct(devSm, 0.9))) px（原图像素）"
                    + "｜PC 参照（SCRFD 点位、同一把尺）：慢段 7.23→1.42／偏离 4.13，快段 7.73→1.68／偏离 4.91")
            }
        } else {
            say("预检没跑成（reader 起不来或 0 帧）⇒ 这一退回逐帧现检、不平滑")
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
        var resids128: [Double] = [], facePx: [Double] = []
        var cosList: [String] = []
        var made = 0, swapped = 0, noFace = 0, smallFace = 0, fitFail = 0, mirror = 0, netFail = 0, poolMiss = 0
        var preHit = 0, liveDetect = 0, trackMiss = 0
        // preHit＝这帧的点取自预检轨迹｜liveDetect＝当场真跑了 Vision 检测的帧数｜trackMiss＝预检跑了但帧号越界
        let hasTrack = !trackPts.isEmpty       // 预检整个没跑成时出片这趟退回逐帧现检（不平滑）
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
        let side = FsxGeo.side128
        var att = [Float](repeating: 0, count: 3 * side * side)      // 目标这一帧的 128 裁片＝换脸网的入参
        var face = [Float](repeating: 0, count: 3 * side * side)     // 换出来的那张脸（已量化到 8 位）
        var f112 = [Float](repeating: 0, count: 3 * FsxGeo.side112 * FsxGeo.side112)   // 复测：128 缩到 112
        var c112 = [Float](repeating: 0, count: 3 * FsxGeo.side112 * FsxGeo.side112)   // 复测：从成片帧直接裁 112

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
                // 点位从预检那一趟的整片轨迹按同一帧号取（已平滑）。
                // 退回当场检测只留两种：预检整个没跑成（trackPts 空）、帧号越界（两趟读出来的长度不一致）。
                // 预检里这帧没脸＝这帧本来就不换，不重检：同一把尺重检也是 0 张，只多花钱。
                var ptsIn: [CGPoint] = [], srcIn = "—"
                var sideIn = 0.0
                var liveCount = -1          // ≥0 只在当场真检过时有效：给「没脸」那两行对照用
                if made < trackPts.count && !trackPts[made].isEmpty {
                    ptsIn = smTrack[made]; srcIn = trackName[made]; sideIn = trackSide[made]
                    preHit += 1
                } else if !hasTrack || made >= trackPts.count {
                    if hasTrack { trackMiss += 1 }
                    liveDetect += 1
                    let (obs, derr) = SwapVision.faces(dst, req)
                    if !derr.isEmpty { say("检测抛错：\(derr)") }
                    liveCount = obs.count
                    // y 口径没定过就当场判：这一路没有源脸照片时（预检也没跑成），
                    // 拿默认值当结论会把整片 5 点映成镜像（上机实测 397 帧全被挡、换上人 0 帧）。
                    if SwapVision.yTopLeftOrigin == nil {
                        for i in obs.indices {
                            if let line = SwapVision.settleOriginStrict(face: obs[i]) {
                                say("y 原点靠第 \(made) 帧这一帧判出来（这一趟没有源脸照片可判）：" + line)
                                break
                            }
                        }
                    }
                    if let l = SwapVision.largest(obs, w: w, h: h) {
                        let (p, n) = SwapVision.sendPoints(face: obs[l.index], w: w, h: h)
                        ptsIn = p; srcIn = n; sideIn = l.shortSide
                    }
                }
                detectMs.append(Double(DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000)

                var did = false
                if ptsIn.count == 5 {
                    if sideIn < args.minFacePx {
                        smallFace += 1
                    } else if let pl = FsxGeo.place(pts: ptsIn, src: srcIn, shortSide: sideIn) {
                        pointSrc = pl.src
                        if pl.mirrored {
                            // 5 点的手性与模板相反＝y 口径判反了，这张脸换出来是一张翻面的脸，宁可这帧不动
                            // （相似拟合表达不了镜像，det＝a²＋b² 恒正，只能这样判）
                            mirror += 1
                            if mirror <= 3 {
                                let ptTxt = pl.pts.map { String(format: "%.0f,%.0f", $0.x, $0.y) }.joined(separator: " ")
                                say("第 \(made) 帧 5 点手性与模板相反（y 口径判反）"
                                    + "｜叉 \(String(format: "%.0f", pl.chir.nose))／\(String(format: "%.0f", pl.chir.mouth))"
                                    + "｜点位 \(pl.src)｜短边 \(String(format: "%.0f", pl.shortSide)) px｜5 点 \(ptTxt)→这帧不换")
                            }
                        } else {
                            let t2 = DispatchTime.now().uptimeNanoseconds
                            resids.append(pl.residPx)
                            resids128.append(pl.resid128)
                            facePx.append(pl.shortSide)
                            alignMs.append(Double(DispatchTime.now().uptimeNanoseconds - t2) / 1_000_000)
                            let tw = DispatchTime.now().uptimeNanoseconds
                            let took = SwapTech.withPixels(dst) { base, bpr -> Bool in
                                FsxGeo.warpCrop(UnsafeRawPointer(base), bytesPerRow: bpr, w: w, h: h,
                                                fwd: pl.fwd128, size: side, out: &att)
                            }
                            warpMs.append(Double(DispatchTime.now().uptimeNanoseconds - tw) / 1_000_000)
                            var r: (face: [Float], ms: Double, note: String) =
                                (face: [], ms: 0.0, note: "裁不出 128")
                            let tf = DispatchTime.now().uptimeNanoseconds
                            if took == true { r = engine.swap(crop128_01: att) }
                            frameAllMs.append(Double(DispatchTime.now().uptimeNanoseconds - tf) / 1_000_000)
                            if r.face.count != 3 * side * side {
                                // 网没回话：这一帧原样交出去，绝不许丢帧（丢了成片就比素材短）
                                netFail += 1
                                if netFail <= 3 { say("第 \(made) 帧网没回话：\(r.note)→这帧原样交") }
                            } else {
                                netMs.append(r.ms)
                                face = r.face
                                let tm = DispatchTime.now().uptimeNanoseconds
                                let pasted = SwapTech.withPixels(dst) { base, bpr -> Bool in
                                    FsxGeo.pasteBack(base, bytesPerRow: bpr, w: w, h: h, face: face, fwd: pl.fwd128)
                                }
                                pasteMs.append(Double(DispatchTime.now().uptimeNanoseconds - tm) / 1_000_000)
                                did = pasted == true
                                if !did {
                                    netFail += 1
                                    if netFail <= 3 { say("第 \(made) 帧贴回没成（128 方块映不进这一帧）→这帧原样交") }
                                }

                                // 每 sampleEvery 帧复测一次"换完这张脸还剩多少源的身份"
                                if did, made % max(1, args.sampleEvery) == 0 {
                                    let t4 = DispatchTime.now().uptimeNanoseconds
                                    // 换后那一张直接从成片帧按同一组点位重裁 112：量的就是最终画面，不是网吐出来的那半张
                                    var after = (emb: [Float](), rawNorm: 0.0, ms: 0.0, note: "成片裁不出 112")
                                    let cut = SwapTech.withPixels(dst) { base, bpr -> Bool in
                                        FsxGeo.warpCrop(UnsafeRawPointer(base), bytesPerRow: bpr, w: w, h: h,
                                                        fwd: pl.fwd112, size: FsxGeo.side112, out: &c112)
                                    }
                                    if cut == true { after = engine.embedding(crop112_01: c112) }
                                    // 换前那一张＝目标本人这一帧的脸（同一帧的 128 裁片缩到 112）
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
                                    cosList.append("第 \(made) 帧 换后<->源 \(sSrc)｜换前<->源 \(sTgt)｜换后<->换前 \(sSelf)\(after.note.isEmpty ? "" : "｜" + after.note)")
                                    say("  身份 " + cosList.last!)
                                }
                            }
                        }
                    } else {
                        fitFail += 1
                    }
                } else {
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
                    let whyTxt = liveCount < 0 ? "预检这格没脸"
                        : "当场检到 \(liveCount) 张脸，最大短边 \(String(format: "%.0f", sideIn)) px"
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
                    let win = Double(DispatchTime.now().uptimeNanoseconds - lastMark) / 1_000_000_000 / 60.0
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
            + "｜这一条链路逐帧只有这三刀：裁 128→一次前向→按官方那三刀贴回（没有分割网、没有高频回填、没有美白）")
        say("      注：换脸网＝只有 predict 那一句；逐帧整次＝整趟调用（建输入数组＋装字典＋predict＋取输出摊平＋量化到 8 位），两栏之差＝搬运")
        say("      贴回底边：方块往下多贴 \(FsxGeo.extDown) 格、最下面 \(FsxGeo.fadeDown) 格把 alpha 收到 0"
            + "（官方四边同宽那一刀没动：遮罩底落在 128 框第 120 格，下巴在 134 格——差的是方块自己没装进下巴；"
            + "PC 上四臂并排量过、看过片定的这一档：第 20 帧中心列 alpha 过半到 y=1337，下巴实测 1338）")
        say("      \(engine.statsLine())｜几何自测 \(FsxGeo.selfTest())")
        say("总耗时 \(String(format: "%.1f", wall)) s（素材实到 \(String(format: "%.1f", madeSec)) s）"
            + "＝\(String(format: "%.2f", wall / max(madeSec, 0.01)))× 实时｜每帧合计 \(String(format: "%.1f", perFrame)) ms"
            + "｜身份复测每次 \(SwapUtil.stat(sampleMs))")
        say("      每帧合计把 裁脸＋逐帧整次 都计进来了；只算 predict 那一式的口径是 \(String(format: "%.1f", perFrameNet)) ms（跨版比速度用这一格）")
        say("预览试算 单趟不编码每帧 \(String(format: "%.1f", pvUnit)) ms＝解码＋检测＋裁脸＋逐帧整次＋贴回（提交那格去掉＝不进编码器；贴回借整片那一格的数＝上限）"
            + "｜16 帧/秒的格＝62.5 ms/帧，这一趟每播 1 s 要 \(String(format: "%.0f", pvUnit * 16)) ms（一秒 1000 ms）")
        say("换上人 \(swapped) 帧｜没脸 \(noFace)｜太小 \(smallFace)｜拟合没过 \(fitFail)｜镜像 \(mirror)｜网失败 \(netFail)｜点位 \(pointSrc)")
        var detSrcTxt = "全部当场真检 \(made)（预检没跑成）"
        if hasTrack {
            detSrcTxt = "取自预检 \(preHit)｜当场真检 \(liveDetect)｜"
                      + "预检判这格没脸 \(made - preHit - liveDetect)（帧号越界 \(trackMiss)）"
        }
        say("      点位来路 \(detSrcTxt)")
        if !resids.isEmpty {
            say("对齐残差 中位 \(String(format: "%.2f", median(resids)))／最大 \(String(format: "%.2f", resids.max() ?? 0)) px（原图像素口径）"
                + "｜折进 128 方块 中位 \(String(format: "%.2f", median(resids128)))／最大 \(String(format: "%.2f", resids128.max() ?? 0)) px")
            say("      注：原图像素那个数会随脸在片里的大小成比例放大，跨片子只能看 128 那一列；PC 那张 ±2~4 px 容忍表是在 141 px 的脸上量的")
            let fm = median(facePx), fmax = facePx.max() ?? 0
            say("      脸短边 中位 \(String(format: "%.0f", fm))／p90 \(String(format: "%.0f", pct(facePx, 0.9)))／最大 \(String(format: "%.0f", fmax)) px"
                + "｜128 补丁撑到最大脸＝\(String(format: "%.2f", fmax / 128.0))×（>1＝把 128 的结果放大贴，糊边成一层膜；官方链路本来就只给 128，这一档没法再往上提）")
        }
        say("足迹 \(mem0)→\(SwapFacts.footprintMB()) MB，本次峰值 \(memMax) MB")
        if !cosList.isEmpty {
            say("身份复测 \(cosList.count) 次（PC 参照：换后<->源 0.81~0.90，换前<->源 ≈0.1~0.3）")
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
