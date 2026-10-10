import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreML
import Metal
import Photos
import UIKit

/// 全片模式：把「只出 6.6 秒样片」那层闸门拆掉。
///
///  Pilot 之所以短：它把每帧的三路数据（帧 2.07 MB + 深度平面 0.81 MB + 摊回眼格 2.07 MB）全留在内存里
/// 好让三个零视差面复用 ⇒ 5400 帧就是 26 GB，A13 只有 3.9 GB 物理内存。
/// 这里改成 PC m6 的两趟口径，中间结果落盘：
///   趟 1（扫）顺序解码一遍，每帧出深度，把 518x392 那张平面按 Float32 原样写进缓存文件
///     （811 KB/帧＝23.2 MB/秒素材），同时把每帧抽出的若干深度值累进一个定长样本池 ⇒ 出整片 p1/p99。
///   趟 2..N（每档 zp 一条成片）再顺序解码一遍，深度从缓存顺序读回，归一化 → 时域 EMA 0.4 → 形变 → 编码。
/// PC 那条 m6 也是这个结构（先预扫定 lo/hi，再 cap.set(POS_FRAMES,0) 从头逐帧写 ffmpeg），
/// 差别只在 PC 预扫不存深度、正式趟重跑一遍：手机上深度是 166 ms/帧的大头，重跑三趟不划算，
/// 所以这里用落盘换掉重跑。
enum VRFull {
    /// 界面读这两个当实时进度（跑的人在 detached 线程里写，主线程每 2 s 读一次）
    static var progress = ""
    static var doneFrames = 0
    static var totalFrames = 0
    static var cancelRequested = false

    static func requestCancel() {
        cancelRequested = true
        VRJournal.line("全片 收到停止请求：把手上这条收兵，已写好的部分照样出片")
    }

    /// 一帧深度平面的字节数：模型固定 518x392 ⇒ 这个数也就是缓存体积的唯一变量
    static func planeBytes(_ w: Int, _ h: Int) -> Int { w * h * MemoryLayout<Float>.size }

    /// 整片分位数用的样本池上限：1.2 MB，与素材长度无关
    static let poolCap = 300_000

    static func run(url: URL, bpct: Float, eyeLong: Int, zps: [Float], smooth: Float,
                    units: MLComputeUnits, rot: Bool) -> String {
        var rep: [String] = []
        let wall0 = DispatchTime.now().uptimeNanoseconds
        let mem0 = VRFacts.footprintMB()
        var memMax = mem0
        var maxPlaneW = 0
        var maxPlaneH = 0
        cancelRequested = false
        doneFrames = 0
        totalFrames = 0
        progress = "全片 起手（读几何、载模型）"
        let rotName = rot ? "转90°" : "摆正"
        VRJournal.line("全片 开始 \(url.lastPathComponent) 视差\(bpct)% 眼长边\(eyeLong) zp\(zps.count)档"
            + " 平滑\(smooth) 送检朝向\(rotName)")
        defer { progress = "" }

        guard VRTech.boot() else { return "Metal 起不来：\(VRTech.initNote)" }
        guard let src = VRSource(url: url, eyeLong: eyeLong) else {
            return "读不出这条片子（见 vr_log）"
        }
        let fps = src.fps > 1 ? src.fps : 30.0
        let estFrames = max(1, Int((src.duration * fps).rounded()))
        totalFrames = estFrames
        rep.append("几何 源 \(src.upW)x\(src.upH)｜摆正 \(src.deg)°｜每眼 \(src.eyeW)x\(src.eyeH)"
            + "｜成片 \(src.eyeW * 2)x\(src.eyeH)｜\(String(format: "%.1f", src.duration)) s"
            + " @ \(String(format: "%.1f", fps)) fps ≈ \(estFrames) 帧")

        let found = VRDepth.locate()
        guard let modelURL = found.url else { return "包里没有深度模型：\(found.note)" }
        let got = VRDepth.load(units)
        guard let model = got.model else {
            return "\(VRPilot.unitsName(units)) 加载失败（\(VRUtil.ms(got.ms))）: \(got.note)"
        }
        let tgt = VRDepth.inputTarget(model, eyeW: src.eyeW, eyeH: src.eyeH)
        var feedNote = ""
        guard let feed = VRDepthFeed(model: model, eyeW: src.eyeW, eyeH: src.eyeH,
                                     mw: tgt.w, mh: tgt.h, rot: rot, note: &feedNote) else {
            return "送检通道建不起来：\(feedNote)"
        }
        rep.append("模型 \(VRPilot.unitsName(units)) 加载 \(VRUtil.ms(got.ms))｜送检 \(tgt.w)x\(tgt.h)"
            + " 朝向\(rotName) 实占 \(feed.usedPx) px｜\(modelURL.lastPathComponent)")

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let tag = stamp.string(from: Date())
        let cache = dir.appendingPathComponent("vr3d_depth_\(tag).bin")
        // 上一轮没收干净的话这里就欠着几个 GB：先清掉再算这次要占多少，不然闸门会被自己骗过去
        var reclaimed = 0
        for one in (try? FileManager.default.contentsOfDirectory(at: dir,
                                    includingPropertiesForKeys: [.fileSizeKey], options: [])) ?? []
            where one.lastPathComponent.hasPrefix("vr3d_depth_") && one.path != cache.path {
            let sz = ((try? one.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if (try? FileManager.default.removeItem(at: one)) != nil { reclaimed += sz }
        }
        defer { try? FileManager.default.removeItem(at: cache) }

        // —— 磁盘闸门：深度缓存 23.2 MB/秒素材 ＋ 每条成片约 1 MB/秒，再留 3 GB 余量 ——
        let planePerFrame = Double(planeBytes(tgt.w, tgt.h))
        let clipPerSec = 1_000_000.0
        let perSec = planePerFrame * fps + clipPerSec * Double(max(1, zps.count))
        let need = perSec * src.duration * 1.15
        let free = freeBytes(dir)
        rep.append("磁盘 需要 \(String(format: "%.2f", need / 1_073_741_824)) GB"
            + "（深度缓存 \(planeBytes(tgt.w, tgt.h)) 字节/帧＝\(String(format: "%.1f", planePerFrame / 1_048_576)) MB/帧"
            + "×\(estFrames) 帧，再加 \(zps.count) 条成片）｜可用 \(String(format: "%.1f", free / 1_073_741_824)) GB"
            + (reclaimed > 0 ? "｜本轮先清掉上轮残留的缓存 \(String(format: "%.2f", Double(reclaimed) / 1_048_576)) MB" : ""))
        if need > free - 3_000_000_000.0 {
            let capSec = max(0.0, (free - 3_000_000_000.0) / perSec)
            return "这条 \(String(format: "%.0f", src.duration)) s 装不下：按 \(String(format: "%.1f", fps)) fps、"
                + "\(zps.count) 档 zp，每 1 秒素材要占 \(String(format: "%.1f", perSec / 1_048_576)) MB（深度缓存是大头，与每眼档无关，只与帧数有关）。"
                + "剩下的 \(String(format: "%.1f", free / 1_073_741_824)) GB 扣掉 3 GB 余量只够约 \(String(format: "%.0f", capSec)) s。"
                + "要么减 zp 档数，要么先裁短素材。"
        }

        // —— 趟 1：顺序解码 → 深度 → 平面落盘 ＋ 整片样本池 ——
        var pool: [Float] = []
        pool.reserveCapacity(poolCap)
        let take = max(8, poolCap / estFrames)
        var scanMs: [Double] = []
        var decodeMs: [Double] = []
        var depthMs: [Double] = []
        var writeMs: [Double] = []
        var n1 = 0
        var stop1 = ""
        var perFrameLo: [Float] = []
        var perFrameHi: [Float] = []
        FileManager.default.createFile(atPath: cache.path, contents: nil)
        guard let sink = try? FileHandle(forWritingTo: cache) else {
            return "深度缓存文件写不开：\(cache.path)"
        }
        defer { try? sink.close() }
        let made = VRTech.pixelBuffer(width: src.eyeW, height: src.eyeH)
        guard let framePB = made.pb else { return "帧缓冲造不出来：\(made.note)" }
        guard let stream = VRFrameStream(src: src) else { return "顺序解码起不来（见 vr_log）" }
        defer { stream.close() }
        while true {
            let t0 = DispatchTime.now().uptimeNanoseconds
            guard stream.next(into: framePB) else { break }
            let dMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            let r = feed.infer(srcPB: framePB)
            guard !r.raw.isEmpty else { stop1 = "第 \(n1 + 1) 帧深度是空的：\(r.err ?? "-")"; break }
            if maxPlaneW == 0 { maxPlaneW = r.plane.w; maxPlaneH = r.plane.h }
            guard r.plane.w == maxPlaneW, r.plane.h == maxPlaneH else {
                stop1 = "第 \(n1 + 1) 帧深度平面变成 \(r.plane.w)x\(r.plane.h)，本轮已按 \(maxPlaneW)x\(maxPlaneH) 落盘"
                break
            }
            let vals = r.plane.vals
            guard vals.count == maxPlaneW * maxPlaneH else {
                stop1 = "第 \(n1 + 1) 帧平面有 \(vals.count) 个浮点，\(maxPlaneW)x\(maxPlaneH) 的格子要 \(maxPlaneW * maxPlaneH) 个"
                break
            }
            let t1 = DispatchTime.now().uptimeNanoseconds
            let data = vals.withUnsafeBufferPointer { Data(buffer: $0) }
            do { try sink.write(contentsOf: data) } catch {
                stop1 = "第 \(n1 + 1) 帧落盘失败：\(error)（磁盘满了？缓存写到这儿为止）"
                break
            }
            writeMs.append(Double(DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000)
            // 整片分布不能靠逐帧分位数取均值（那是 PC 试片那档口径），也不能把每帧 20 万个值全攒着
            // （5400 帧 = 2.7 GB）⇒ 定长样本池：每帧均匀抽 take 个，起点按帧号错开。
            // 不错开就永远落在同一批像素上，抽出来的不是「整片的分布」而是「这几个点位的分布」。
            if pool.count + take <= poolCap {
                let step = max(1, r.raw.count / take)
                var got = 0
                var i = (n1 * 7919) % step
                while i < r.raw.count && got < take {
                    pool.append(r.raw[i])
                    i += step
                    got += 1
                }
            }
            if n1 % 20 == 0 {
                let pp = VRPlane.percentile(r.raw)
                perFrameLo.append(pp.lo); perFrameHi.append(pp.hi)
            }
            n1 += 1
            doneFrames = n1
            decodeMs.append(dMs); depthMs.append(r.ms.predict)
            if n1 > 8 { scanMs.append(writeMs.last ?? 0) }
            if n1 % 60 == 0 {
                let el = Double(DispatchTime.now().uptimeNanoseconds - wall0) / 1_000_000_000
                let per = el / Double(n1)
                progress = "全片 扫 \(n1)/\(estFrames) 帧｜已用 \(fmt(el))｜约还需 \(fmt(per * Double(estFrames - n1)))"
                VRJournal.line("全片 扫 \(n1)/\(estFrames) 解码 \(String(format: "%.0f", dMs)) ms"
                    + " 深度 \(String(format: "%.0f", r.ms.predict)) ms 落盘 \(String(format: "%.1f", writeMs.last ?? 0)) ms"
                    + " 足迹\(VRFacts.footprintMB())MB 预计总 \(fmt(per * Double(estFrames)))")
            }
            let now = VRFacts.footprintMB()
            if now > memMax { memMax = now }
            // composition 每源帧只出一帧这件事，试片那趟验不了（它一次只取一帧）。万一 frameDuration
            // 让输出按 600 fps 铺开，缓存就会以预估 20 倍的速率把磁盘填满 ⇒ 超 1.5 倍立刻收兵。
            if n1 > Int(estFrames * 3 / 2) + 8 {
                stop1 = "解出 \(n1) 帧，超过预估 \(estFrames)（\(String(format: "%.1f", src.duration)) s × \(String(format: "%.1f", fps)) fps）的 1.5 倍"
                    + "⇒ 帧数口径对不上，这条不能这么跑，已收兵"
                break
            }
            if cancelRequested { stop1 = "按了停止，第 \(n1 + 1) 帧收兵"; break }
            if VRPressure.sawPressure { stop1 = "系统喊内存压力，第 \(n1 + 1) 帧收兵"; break }
        }
        stream.close()
        try? sink.close()
        guard n1 >= 2, maxPlaneW > 0 else {
            return "深度一帧都没跑通：\(stop1.isEmpty ? "解出来的帧不足 2" : stop1)"
        }
        let sorted = pool.sorted()
        func pAt(_ q: Float) -> Float {
            guard !sorted.isEmpty else { return 0 }
            let i = min(sorted.count - 1, max(0, Int(q * Float(sorted.count))))
            return sorted[i]
        }
        let lo = pAt(0.01)
        let hi = pAt(0.99)
        let span = max(hi - lo, 1e-6)
        let fLo = perFrameLo.reduce(0, +) / Float(perFrameLo.count)
        let fHi = perFrameHi.reduce(0, +) / Float(perFrameHi.count)
        rep.append("趟1 扫成 \(n1) 帧（预估 \(estFrames)）｜深度平面 \(maxPlaneW)x\(maxPlaneH) 每帧落盘 \(planeBytes(maxPlaneW, maxPlaneH)) 字节"
            + "｜缓存 \(String(format: "%.2f", Double(n1 * planeBytes(maxPlaneW, maxPlaneH)) / 1_073_741_824)) GB")
        rep.append("归一化 整片 p1/p99 = \(String(format: "%.3f~%.3f", lo, hi))"
            + "（\(sorted.count) 个样本，每帧抽 \(take) 个）"
            + "｜对照 试片那档口径「逐帧 p1/p99 再取均值」= \(String(format: "%.3f~%.3f", fLo, fHi))"
            + "｜全片值域 \(String(format: "%.3f", sorted.first ?? 0))~\(String(format: "%.3f", sorted.last ?? 0))")
        rep.append("趟1 单价 解码 \(VRUtil.stat(decodeMs))｜深度 \(VRUtil.stat(depthMs))｜落盘 \(VRUtil.stat(scanMs))")
        let scanPer = avg(decodeMs) + avg(depthMs) + avg(scanMs)
        rep.append("趟1 合计 \(fmt(Double(n1) * scanPer / 1000.0))（\(String(format: "%.1f", scanPer)) ms/帧）")
        if !stop1.isEmpty { rep.append("趟1 收兵原因 \(stop1)") }

        // —— 趟 2..N：每档 zp 出一条全片 ——
        var wnote = ""
        guard let warp = VRWarp(eyeW: src.eyeW, eyeH: src.eyeH, bpct: bpct, note: &wnote) else {
            return "形变通道建不起来：\(wnote)"
        }
        rep.append("视差上限 \(String(format: "%.1f", warp.budget)) px（每眼宽的 \(String(format: "%.1f", bpct))%）"
            + "｜时域 EMA \(smooth)｜PC 的 m6 在每眼 1024 宽时是 79.9 px")

        var outs: [String] = []
        var holeAll: [String] = []
        var d2: [Double] = []
        var normMs: [Double] = []
        var gpuMs: [Double] = []
        var allocMs: [Double] = []
        var appendMs: [Double] = []
        var waitMs: [Double] = []
        var readMs: [Double] = []
        let sbsW = src.eyeW * 2
        let h = src.eyeH
        let px = src.eyeW * src.eyeH
        let chunkBytes = planeBytes(maxPlaneW, maxPlaneH)
        var planeVals = [Float](repeating: 0, count: maxPlaneW * maxPlaneH)
        var dn = [Float](repeating: 0, count: px)
        var prev = [Float](repeating: 0, count: px)
        let bitrate = max(4_000_000, Int(Double(sbsW * h * 6) * 1.2))
        var encStart = 0.0
        var encTail = 0.0

        for (zi, zp) in zps.enumerated() {
            if cancelRequested { rep.append("已按停止，后面 \(zps.count - zi) 档没出"); break }
            progress = "全片 第 \(zi + 1)/\(zps.count) 档 zp\(String(format: "%.2f", zp)) 出片中"
            doneFrames = 0
            totalFrames = n1
            // 缓存句柄和解码器都在这条的最开头开：任一开不起来就还没起 writer，break 不会留下半成品
            guard let src2 = try? FileHandle(forReadingFrom: cache) else {
                outs.append("zp\(String(format: "%.2f", zp)): 缓存读不开"); break
            }
            guard let str2 = VRFrameStream(src: src) else {
                try? src2.close()
                outs.append("zp\(String(format: "%.2f", zp)): 第二趟顺序解码起不来"); break
            }
            let out = dir.appendingPathComponent("vr3d_\(tag)_zp\(String(format: "%.2f", zp)).mp4")
            try? FileManager.default.removeItem(at: out)
            guard let writer = try? AVAssetWriter(outputURL: out, fileType: .mp4) else {
                try? src2.close(); str2.close()
                outs.append("zp\(String(format: "%.2f", zp)): AVAssetWriter 建不起来"); break
            }
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: sbsW,
                AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoMaxKeyFrameIntervalKey: Int(fps * 2),
                    AVVideoExpectedSourceFrameRateKey: Int(fps),
                ],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: sbsW,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                              sourcePixelBufferAttributes: attrs)
            guard writer.canAdd(input) else {
                try? src2.close(); str2.close()
                outs.append("zp\(String(format: "%.2f", zp)): canAdd 为假，这套 outputSettings 本机不支持"); break
            }
            writer.add(input)
            let tHead0 = DispatchTime.now().uptimeNanoseconds
            do { try writer.startWriting() } catch {
                try? src2.close(); str2.close()
                outs.append("zp\(String(format: "%.2f", zp)): startWriting 抛错 \(error)"); break
            }
            writer.startSession(atSourceTime: .zero)
            encStart += Double(DispatchTime.now().uptimeNanoseconds - tHead0) / 1_000_000

            var k = 0
            var holes = 0.0
            var why = ""
            while true {
                let t0 = DispatchTime.now().uptimeNanoseconds
                guard str2.next(into: framePB) else { break }
                let dMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                let tR = DispatchTime.now().uptimeNanoseconds
                guard let blob = try? src2.read(upToCount: chunkBytes) else {
                    why = "第 \(k + 1) 帧读缓存抛错"; break
                }
                readMs.append(Double(DispatchTime.now().uptimeNanoseconds - tR) / 1_000_000)
                guard blob.count == chunkBytes else { why = "第 \(k + 1) 帧只读到 \(blob.count) 字节，每帧要 \(chunkBytes)"; break }
                blob.withUnsafeBytes { raw in
                    if let b = raw.baseAddress {
                        planeVals.withUnsafeMutableBytes { d in memcpy(d.baseAddress!, b, chunkBytes) }
                    }
                }
                let tN = DispatchTime.now().uptimeNanoseconds
                let e = feed.reshaped(planeVals, w: maxPlaneW, h: maxPlaneH)
                guard e.count == px else { why = "第 \(k + 1) 帧摊回眼格得到 \(e.count) 个，应为 \(px)"; break }
                for i in 0..<px { dn[i] = min(1.0, max(0.0, (e[i] - lo) / span)) }
                if k > 0 && smooth > 0 {
                    for i in 0..<px { dn[i] = (1 - smooth) * dn[i] + smooth * prev[i] }
                }
                prev = dn
                normMs.append(Double(DispatchTime.now().uptimeNanoseconds - tN) / 1_000_000)
                d2.append(dMs)
                let tb = DispatchTime.now().uptimeNanoseconds
                // 每帧新造一块输出缓冲：adaptor 只保证「交出去的那块在编码器用完前不死」，
                // isReadyForMoreMediaData 不代表上一帧已经吃进硬件 ⇒ 复用会把还在编的帧改花。
                guard let outPB = VRTech.pixelBuffer(width: sbsW, height: h).pb else {
                    why = "成片缓冲分配失败"; break
                }
                allocMs.append(Double(DispatchTime.now().uptimeNanoseconds - tb) / 1_000_000)
                let rr = warp.render(srcPB: framePB, dn: dn, zp: Float(zp), outPB: outPB)
                guard rr.err == nil else { why = "第 \(k + 1) 帧形变失败: \(rr.err ?? "")"; break }
                gpuMs.append(rr.gpu)
                holes += rr.holes
                let tw = DispatchTime.now().uptimeNanoseconds
                var spins = 0
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.005)
                    spins += 1
                }
                waitMs.append(Double(DispatchTime.now().uptimeNanoseconds - tw) / 1_000_000)
                if spins > 0 && k % 60 == 0 {
                    VRJournal.line("全片 zp\(String(format: "%.2f", zp)) 第 \(k) 帧等到过队列满 \(spins) 轮")
                }
                let ta = DispatchTime.now().uptimeNanoseconds
                guard VRPilot.append(adaptor, input, writer, outPB, at: Double(k) / fps) else {
                    why = "第 \(k + 1) 帧写不进去"; break
                }
                appendMs.append(Double(DispatchTime.now().uptimeNanoseconds - ta) / 1_000_000)
                k += 1
                doneFrames = k
                if k % 60 == 0 {
                    let el = Double(DispatchTime.now().uptimeNanoseconds - wall0) / 1_000_000_000
                    progress = "全片 第 \(zi + 1)/\(zps.count) 档 zp\(String(format: "%.2f", zp))"
                        + " 写到 \(k)/\(n1) 帧｜整轮已用 \(fmt(el))"
                    VRJournal.line("全片 zp\(String(format: "%.2f", zp)) \(k)/\(n1) 帧 解码 \(String(format: "%.0f", dMs)) ms"
                        + " 读 \(String(format: "%.1f", readMs.last ?? 0)) ms 摊平+平滑 \(String(format: "%.1f", normMs.last ?? 0)) ms"
                        + " 形变 \(String(format: "%.1f", rr.gpu)) ms 足迹\(VRFacts.footprintMB())MB")
                }
                let now = VRFacts.footprintMB()
                if now > memMax { memMax = now }
                if cancelRequested { why = "按了停止，这条就此收兵"; break }
                if VRPressure.sawPressure { why = "系统喊内存压力，这条就此收兵"; break }
            }
            try? src2.close()
            str2.close()
            input.markAsFinished()
            let tTail0 = DispatchTime.now().uptimeNanoseconds
            let esem = DispatchSemaphore(value: 0)
            writer.finishWriting { esem.signal() }
            esem.wait()
            encTail += Double(DispatchTime.now().uptimeNanoseconds - tTail0) / 1_000_000
            if writer.status != .completed {
                why = (why.isEmpty ? "" : why + "｜") + "finishWriting status=\(writer.status.rawValue)"
                    + " \(writer.error?.localizedDescription ?? "-")"
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: out.path)[.size]) as? Int) ?? 0
            let rate = k > 0 ? holes / Double(k) : 0
            holeAll.append("zp\(String(format: "%.2f", zp)) \(String(format: "%.2f", rate))%")
            let secs = Double(k) / max(fps, 1)
            outs.append("\(out.lastPathComponent) \(k) 帧≈\(String(format: "%.1f", secs)) s"
                + " \(String(format: "%.1f", Double(size) / 1048576)) MB｜补洞 \(String(format: "%.2f", rate))%"
                + (why.isEmpty ? "" : "｜\(why)"))
            VRJournal.line("全片 zp\(String(format: "%.2f", zp)) 出完 \(k) 帧 \(String(format: "%.1f", Double(size) / 1048576)) MB")
            let saved = VRPilot.toPhotos(out)
            outs.append("  存相册 " + saved)
            if saved.hasPrefix("已存") {
                try? FileManager.default.removeItem(at: out)
            } else {
                // 全片一条可能几百 MB：存相册没成，这条就留在 documents 里，删了他就真没了
                outs.append("  本地还留着 \(out.path)")
            }
        }

        let perFrame2 = avg(d2) + avg(readMs) + avg(normMs) + avg(gpuMs) + avg(allocMs)
            + avg(appendMs) + avg(waitMs)
        rep.append("趟2 单价 解码 \(VRUtil.stat(d2))｜读缓存 \(VRUtil.stat(readMs))"
            + "｜摊平+归一化+EMA \(VRUtil.stat(normMs))｜形变 \(VRUtil.stat(gpuMs))"
            + "｜成片帧分配 \(VRUtil.stat(allocMs))｜提交 \(VRUtil.stat(appendMs))"
            + "｜背压 \(VRUtil.stat(waitMs))（按 5 ms 一轮睡，量化到 5 ms 一档）")
        rep.append("折算 出片每帧 \(String(format: "%.1f", perFrame2)) ms ⇒ 每条 zp \(fmt(Double(n1) * perFrame2 / 1000.0))"
            + "｜编码器头 \(VRUtil.ms(encStart))、尾排空 \(VRUtil.ms(encTail))（这 \(zps.count) 条加起来的一次性成本，不是每帧）")
        rep.append("分段补洞 " + holeAll.joined(separator: "｜") + "（PC 的 m6 是 6.74%）")
        let wall = Double(DispatchTime.now().uptimeNanoseconds - wall0) / 1_000_000_000
        let madeSec = Double(n1) / max(fps, 1)
        rep.append("总耗时 \(fmt(wall))（素材实到 \(fmt(madeSec)) s）＝\(String(format: "%.2f", wall / max(madeSec, 0.01)))× 实时"
            + "（一趟扫＋\(zps.count) 条成片；扫 1 帧要 \(String(format: "%.0f", scanPer)) ms，出片 1 帧要 \(String(format: "%.0f", perFrame2)) ms）")
        rep.append("足迹 \(mem0)→\(VRFacts.footprintMB()) MB，本次峰值 \(memMax) MB")
        rep.append("成片 " + (outs.isEmpty ? "一条都没出成" : outs.joined(separator: "\n")))
        VRJournal.line("全片 结束 扫\(n1)帧 墙钟\(fmt(wall)) 峰值\(memMax)MB")
        return rep.joined(separator: "\n")
    }

    static func freeBytes(_ at: URL) -> Double {
        guard let a = try? FileManager.default.attributesOfFileSystem(forPath: at.path),
              let n = a[.systemFreeSize] as? NSNumber else { return 0 }
        return n.doubleValue
    }

    static func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }

    static func fmt(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) 分 \(s % 60) 秒" }
        return "\(s / 3600) 时 \((s % 3600) / 60) 分"
    }
}

/// 顺序解码一整条片子：一个 AVAssetReader 从头吃到尾，帧拷进调用方给的复用缓冲。
/// Pilot 那种「每帧重建一个 reader 去 seek」不能这么用：那一次要付 54 ms 的起手开销，
/// 它只有在「只取十帧」时才划算——全片 5400 帧要一次次重开解码器，光起手就比解码本身贵。
final class VRFrameStream {
    let reader: AVAssetReader
    let out: AVAssetReaderVideoCompositionOutput
    let eyeW: Int
    let eyeH: Int
    private var open = false

    init?(src: VRSource) {
        guard let r = try? AVAssetReader(asset: src.asset) else {
            VRJournal.line("流 reader 建不出来")
            return nil
        }
        guard let o = AVAssetReaderVideoCompositionOutput(
            videoTracks: [src.track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]) else {
            VRJournal.line("流 VideoCompositionOutput 建不出来")
            return nil
        }
        o.videoComposition = src.vc
        r.add(o)
        guard r.startReading() else {
            VRJournal.line("流 startReading 失败 \(r.error?.localizedDescription ?? "-")")
            return nil
        }
        reader = r; out = o; eyeW = src.eyeW; eyeH = src.eyeH
        open = true
    }

    /// 下一帧：到头、形状不对就返回 false
    func next(into dst: CVPixelBuffer) -> Bool {
        guard open, let s = out.copyNextSampleBuffer() else { return false }
        guard reader.status == .reading else { return false }
        guard let b = CMSampleBufferGetImageBuffer(s) else { return false }
        guard CVPixelBufferGetWidth(b) == eyeW, CVPixelBufferGetHeight(b) == eyeH else {
            VRJournal.line("流 直出 \(CVPixelBufferGetWidth(b))x\(CVPixelBufferGetHeight(b))，每眼 \(eyeW)x\(eyeH) 对不上")
            return false
        }
        VRUtil.copyRows(from: b, to: dst)
        return true
    }

    func close() {
        guard open else { return }
        open = false
        if reader.status == .reading { reader.cancelReading() }
    }
}
