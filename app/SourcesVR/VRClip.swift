import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreML
import Metal
import Photos
import UIKit
import CoreText

/// 验证件的心脏：抽 N 帧 → 深度 → 整片归一化 → 三个零视差面各出一段 → 拼成一条等幅 SBS 试片存相册。
/// 一次上机要同时拿回四件事：CI 编出来的模型认不认、深度单价、Metal 形变单价与补洞率、能不能戴出立体感。
enum VRPilot {

    struct Sample {
        var pb: CVPixelBuffer
        var raw: [Float]
        var plane: VRPlane.Out
        var decode = 0.0
        var prep = 0.0
        var predict = 0.0
    }

    static func run(url: URL, frames: Int, bpct: Float, eyeLong: Int,
                    zps: [Float], outFps: Double, units: MLComputeUnits, rot: Bool) -> String {
        var rep: [String] = []
        let mem0 = VRFacts.footprintMB()
        var memMax = mem0
        let rotName = rot ? "转90°" : "摆正"
        VRJournal.line("试片 开始 \(url.lastPathComponent) 抽\(frames)帧 视差\(bpct)% 眼长边\(eyeLong)"
            + " 送检朝向\(rotName)")
        guard VRTech.boot() else { return "Metal 起不来：\(VRTech.initNote)" }

        guard let src = VRSource(url: url, eyeLong: eyeLong) else {
            return "读不出这条片子（见 vr_log）"
        }
        rep.append("几何 源 \(src.upW)x\(src.upH)｜摆正 \(src.deg)°｜每眼 \(src.eyeW)x\(src.eyeH)｜成片 \(src.eyeW * 2)x\(src.eyeH)"
            + "｜\(String(format: "%.1f", src.duration)) s @ \(String(format: "%.1f", src.fps)) fps")

        let found = VRDepth.locate()
        guard let modelURL = found.url else { return "包里没有深度模型：\(found.note)" }
        let got = VRDepth.load(units)
        guard let model = got.model else {
            return "\(unitsName(units)) 加载失败（\(VRUtil.ms(got.ms))）: \(got.note)"
        }
        rep.append("模型 \(unitsName(units)) 加载 \(VRUtil.ms(got.ms))｜\(modelURL.lastPathComponent)")
        rep.append(VRDepth.describe(model))
        let tgt = VRDepth.inputTarget(model, eyeW: src.eyeW, eyeH: src.eyeH)
        var feedNote = ""
        guard let feed = VRDepthFeed(model: model, eyeW: src.eyeW, eyeH: src.eyeH,
                                     mw: tgt.w, mh: tgt.h, rot: rot, note: &feedNote) else {
            return "送检通道建不起来：\(feedNote)"
        }
        let other = VRDepthFeed(model: model, eyeW: src.eyeW, eyeH: src.eyeH,
                                mw: tgt.w, mh: tgt.h, rot: !rot, note: &feedNote)
        var otherPx = "另一朝向没建成"
        if let o = other { otherPx = "另一朝向实占 \(o.usedPx) px" }
        rep.append("送检口径 \(tgt.note)｜朝向 \(rotName)｜信箱 scale \(String(format: "%.3f", feed.scale))"
            + " 偏移 (\(String(format: "%.0f", feed.ox)),\(String(format: "%.0f", feed.oy)))"
            + "｜框 \(tgt.w)x\(tgt.h)｜本次实占 \(feed.usedPx) px｜\(otherPx)")

        // —— 1. 抽帧 + 深度 ——
        var samples: [Sample] = []
        var decodeMs: [Double] = []
        var prepMs: [Double] = []
        var predMs: [Double] = []
        var stop = ""
        for i in 0..<frames {
            let t = (Double(i) + 0.5) * src.duration / Double(frames)
            let f = src.framePB(at: t)
            guard let pb = f.pb else { stop = "第 \(i + 1) 帧取不到：\(f.note)"; break }
            let r = feed.infer(srcPB: pb)
            guard !r.raw.isEmpty else { stop = "第 \(i + 1) 帧深度是空的：\(r.err ?? "-")"; break }
            var s = Sample(pb: pb, raw: r.raw, plane: r.plane)
            s.decode = f.ms
            s.prep = r.ms.prep
            s.predict = r.ms.predict
            if i > 1 { decodeMs.append(f.ms); prepMs.append(r.ms.prep); predMs.append(r.ms.predict) }
            samples.append(s)
            let now = VRFacts.footprintMB()
            if now > memMax { memMax = now }
            if i % 3 == 0 { VRJournal.line("试片 抽帧 \(i + 1)/\(frames) 深度 \(String(format: "%.1f", r.ms.predict)) ms 足迹\(now)MB") }
            if let e = r.err { VRJournal.line("试片 第\(i + 1)帧深度注 \(e)") }
            if VRPressure.sawPressure { stop = "系统喊内存压力，第 \(i + 1) 帧收兵"; break }
        }
        guard samples.count >= 2 else {
            return "深度一帧都没跑通：\(stop.isEmpty ? "抽到的帧不足 2" : stop)"
        }

        let first = samples[0].plane
        rep.append("深度输出 第0帧 \(first.w)x\(first.h) 格式 \(first.fourcc) 每像素 \(first.bpp) 字节"
            + (first.note.isEmpty ? "" : "｜\(first.note)"))

        // —— 2. 整片归一化（PC 的 m6 口径）——
        var los: [Float] = []
        var his: [Float] = []
        for s in samples { let pp = VRPlane.percentile(s.raw); los.append(pp.lo); his.append(pp.hi) }
        let lo = los.reduce(0, +) / Float(los.count)
        let hi = his.reduce(0, +) / Float(his.count)
        var mn = Float.greatestFiniteMagnitude
        var mx = -Float.greatestFiniteMagnitude
        for s in samples { mn = min(mn, s.plane.min); mx = max(mx, s.plane.max) }
        let normVerdict: String
        if first.bpp == 1 && samples.allSatisfy({ $0.plane.min <= 1 && $0.plane.max >= 250 }) {
            normVerdict = "警 每帧自己就铺满 0~255 ⇒ 这个包在内部已经逐帧归一化，"
                + "PC 的「整片归一化」在这里等于白乘，逐帧漂移会直接变成呼吸感"
        } else {
            normVerdict = "每帧 \(String(format: "%.3f~%.3f", mn, mx)) 铺不满 ⇒ 原始量纲还在，"
                + "抽片 p1/p99 均值 \(String(format: "%.3f~%.3f", lo, hi)) 可当真归一化用（整片口径要正式管线里全片扫）"
        }
        rep.append("归一化 \(normVerdict)")

        var dns: [[Float]] = []
        let span = max(hi - lo, 1e-6)
        for s in samples {
            var d = [Float](repeating: 0, count: s.raw.count)
            for i in 0..<d.count { d[i] = min(1.0, max(0.0, (s.raw[i] - lo) / span)) }
            dns.append(d)
        }
        // 上/中/下三条带的均值：深度图要是上下翻了，这条就会反过来
        func band(_ d: [Float], _ a: Int, _ b: Int) -> Float {
            var sum: Float = 0
            var n = 0
            for y in a..<b {
                for x in stride(from: 0, to: src.eyeW, by: 4) { sum += d[y * src.eyeW + x]; n += 1 }
            }
            return n > 0 ? sum / Float(n) : 0
        }
        var bands: [String] = []
        for (i, d) in dns.prefix(4).enumerated() {
            let h = src.eyeH
            bands.append("第\(i + 1)帧 上\(String(format: "%.2f", band(d, 0, h / 5)))"
                + " 中\(String(format: "%.2f", band(d, h * 2 / 5, h * 3 / 5)))"
                + " 下\(String(format: "%.2f", band(d, h * 4 / 5, h)))")
        }
        rep.append("深度分带（中位应当最靠前，反了就是翻了）\(bands.joined(separator: "｜"))")

        // 朝向自证：正变换在 kScale 里、逆变换在 VRDepthFeed.buildMap 里，两处不同步的话
        // 深度会和它的彩色帧错着 90°——画面只显得"有点怪"，补洞率、单价、分带一条都不会报。
        // 比的是形状不是数值：模型每一趟自带一个仿射量纲，两种朝向的画面占比又不同，
        // 绝对值本来就不该相等，所以这里看 r，并拿「故意不做旋转修正」的那张表当地板一起报。
        // 不进单价数组：这趟是额外重跑，混进去会把 avg 污染成两个朝向的混合。
        if let o = other {
            let a = feed.infer(srcPB: samples[0].pb)
            let b = o.infer(srcPB: samples[0].pb)
            let up = rot ? b.raw : a.raw
            let ro = rot ? a.raw : b.raw
            let rotFeed = rot ? feed : o
            let rotPlane = rot ? a.plane : b.plane
            let mis = rotFeed.resampleMis(rotPlane)
            let good = pearson(up, ro)
            let bad = pearson(up, mis)
            if good.r <= -8 || bad.r <= -8 {
                rep.append("朝向自证 r 无从谈起：某一趟的深度几乎是常数（这条太干净或深度没跑出来），换一条素材再判")
            } else {
                rep.append("朝向自证 第1帧 摆正↔转90° 摊回眼格后 r=\(String(format: "%.4f", good.r))"
                    + "（斜率 \(String(format: "%.2f", good.slope))）｜地板 r=\(String(format: "%.4f", bad.r))"
                    + "（逆映射故意不转回来）｜判法：r 贴着 1 就是正逆对上，落到地板那一档就是错 90°"
                    + "｜斜率是两种朝向各自量纲的比，不是对错")
            }
        } else {
            rep.append("朝向自证 没做成：另一朝向的送检通道建不起来 \(feedNote)")
        }

        // —— 3. 形变 + 编码 ——
        var wnote = ""
        guard let warp = VRWarp(eyeW: src.eyeW, eyeH: src.eyeH, bpct: bpct, note: &wnote) else {
            return "形变通道建不起来：\(wnote)"
        }
        rep.append("视差上限 \(String(format: "%.1f", warp.budget)) px（每眼宽的 \(String(format: "%.1f", bpct))%）"
            + "｜PC 的 m6 在每眼 1024 宽时是 79.9 px")

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let out = dir.appendingPathComponent("vr3d_\(f.string(from: Date())).mp4")
        try? FileManager.default.removeItem(at: out)

        let sbsW = src.eyeW * 2
        let h = src.eyeH
        var werr = ""
        guard let writer = try? AVAssetWriter(outputURL: out, fileType: .mp4) else {
            return "AVAssetWriter 建不起来"
        }
        let bitrate = max(4_000_000, Int(Double(sbsW * h * 6) * 1.2))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: sbsW,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: 12,
                AVVideoExpectedSourceFrameRateKey: Int(outFps.rounded()),
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
        guard writer.canAdd(input) else { return "canAdd(input) 为假：这套 outputSettings 本机不支持" }
        writer.add(input)
        let tStart0 = DispatchTime.now().uptimeNanoseconds
        do {
            try writer.startWriting()
        } catch {
            return "startWriting 抛错: \(error)"
        }
        writer.startSession(atSourceTime: .zero)
        let startMs = Double(DispatchTime.now().uptimeNanoseconds - tStart0) / 1_000_000

        // 每帧新造一块输出缓冲：adaptor 只保证"写进去的块在编码器用完前不死"，
        // isReadyForMoreMediaData 不代表上一帧已经消费完 ⇒ 复用同一块会把还在编的帧改花。
        let probe = VRTech.pixelBuffer(width: sbsW, height: h)
        guard probe.pb != nil else { return "成片帧造不出来: \(probe.note)" }

        var allocMs: [Double] = []
        var uploadMs: [Double] = []
        var gpuMs: [Double] = []
        var holePct: [Double] = []
        // 编码是异步的：帧交出去就返回，真正的编算发生在后台，只有两处看得见它——
        // 队列满时的背压（waitMs）和收尾排空（tailMs）。不单独掐这两段，"编码成本"就永远混在总单价里。
        var appendMs: [Double] = []
        var waitMs: [Double] = []
        var blocked = 0
        var tailMs = 0.0
        var k = 0
        var encoded = 0
        for (zi, zp) in zps.enumerated() {
            let head = zi == 0 ? "①" : (zi == 1 ? "②" : "③")
            let title = "\(head) zp \(String(format: "%.2f", zp))｜每眼 \(src.eyeW)x\(h)｜视差 \(String(format: "%.0f", warp.budget)) px｜送检 \(rotName)"
            let tip = zi == 0 ? "主体浮出屏幕" : (zi == 1 ? "中间调" : "背景往后退")
            let ta0 = DispatchTime.now().uptimeNanoseconds
            guard let headPB = VRTech.pixelBuffer(width: sbsW, height: h).pb else { werr = "标题帧分配失败"; break }
            allocMs.append(Double(DispatchTime.now().uptimeNanoseconds - ta0) / 1_000_000)
            drawTitle(headPB, [title, tip, "字是正的 ⇒ 链路没翻"])
            let tAp0 = DispatchTime.now().uptimeNanoseconds
            let headOk = append(adaptor, input, writer, headPB, at: Double(k) / outFps)
            appendMs.append(Double(DispatchTime.now().uptimeNanoseconds - tAp0) / 1_000_000)
            if !headOk { werr = "标题帧写不进去"; break }
            k += 1
            encoded += 1
            var holesHere: [Double] = []
            for i in 0..<samples.count {
                let tw0 = DispatchTime.now().uptimeNanoseconds
                var spins = 0
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.005)
                    spins += 1
                }
                let waitOne = Double(DispatchTime.now().uptimeNanoseconds - tw0) / 1_000_000
                waitMs.append(waitOne)
                if spins > 0 { blocked += 1 }
                let tb0 = DispatchTime.now().uptimeNanoseconds
                guard let framePB = VRTech.pixelBuffer(width: sbsW, height: h).pb else {
                    werr = "第 \(zi + 1) 段第 \(i + 1) 帧输出缓冲分配失败"
                    break
                }
                allocMs.append(Double(DispatchTime.now().uptimeNanoseconds - tb0) / 1_000_000)
                let r = warp.render(srcPB: samples[i].pb, dn: dns[i], zp: Float(zp), outPB: framePB)
                guard r.err == nil else { werr = "第 \(zi + 1) 段第 \(i + 1) 帧形变失败: \(r.err ?? "")"; break }
                if zi == 0 && i > 0 { uploadMs.append(r.upload); gpuMs.append(r.gpu) }
                holesHere.append(r.holes)
                let tAp1 = DispatchTime.now().uptimeNanoseconds
                let frameOk = append(adaptor, input, writer, framePB, at: Double(k) / outFps)
                appendMs.append(Double(DispatchTime.now().uptimeNanoseconds - tAp1) / 1_000_000)
                if !frameOk { werr = "内容帧写不进去"; break }
                k += 1
                encoded += 1
                let now = VRFacts.footprintMB()
                if now > memMax { memMax = now }
            }
            if !werr.isEmpty { break }
            holePct.append(holesHere.reduce(0, +) / Double(max(1, holesHere.count)))
            VRJournal.line("试片 zp\(String(format: "%.2f", zp)) 洞 \(String(format: "%.2f", holePct.last ?? 0))%"
                + " 形变 \(String(format: "%.1f", gpuMs.last ?? 0)) ms 足迹\(memMax)MB")
        }
        let tTail0 = DispatchTime.now().uptimeNanoseconds
        input.markAsFinished()
        let esem = DispatchSemaphore(value: 0)
        writer.finishWriting { esem.signal() }
        esem.wait()
        tailMs = Double(DispatchTime.now().uptimeNanoseconds - tTail0) / 1_000_000
        if writer.status != .completed {
            werr = werr.isEmpty ? "finishWriting 后 status=\(writer.status.rawValue): \(writer.error?.localizedDescription ?? "-")" : werr
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path)[.size]) as? Int) ?? 0

        rep.append("分段补洞 " + holePct.enumerated().map {
            "zp\(String(format: "%.2f", zps[$0.offset])) \(String(format: "%.2f", $0.element))%"
        }.joined(separator: "｜") + "（PC 的 m6 是 6.74%）")
        rep.append("单价 解码 \(VRUtil.stat(decodeMs))｜信箱 \(VRUtil.stat(prepMs))"
            + "｜深度 \(VRUtil.stat(predMs))｜dn 上传 \(VRUtil.stat(uploadMs))｜形变 \(VRUtil.stat(gpuMs))"
            + "｜成片帧分配 \(VRUtil.stat(allocMs))")
        rep.append("编码 头(startWriting+startSession 建编码器) \(VRUtil.ms(startMs))"
            + "｜提交 \(VRUtil.stat(appendMs))｜背压 \(VRUtil.stat(waitMs))（\(blocked)/\(encoded) 帧等到过队列满）"
            + "｜尾(markAsFinished+finishWriting 排空) \(String(format: "%.1f ms", tailMs))"
            + "＝摊 \(String(format: "%.2f", tailMs / Double(max(1, encoded)))) ms/帧"
            + "（背压按 5 ms 一轮睡，只能量化到 5 ms 一档：等到过最短也报 5，没等到报近 0）")
        let perFrame = (avg(decodeMs) + avg(prepMs) + avg(predMs) + avg(uploadMs) + avg(gpuMs) + avg(allocMs)
            + avg(appendMs) + avg(waitMs))
        if perFrame > 0 {
            let total = src.duration * src.fps * perFrame / 1000.0
            rep.append("整片预估 \(String(format: "%.1f", src.duration)) s 素材共 \(Int(src.duration * src.fps)) 帧"
                + "×\(String(format: "%.1f", perFrame)) ms = \(String(format: "%.0f", total)) s"
                + "＝\(String(format: "%.2f", total / max(src.duration, 0.01))) s/s（PC 的 m6 是 21.32 s/s）")
            rep.append("整片另加两头一次性成本：头 \(String(format: "%.1f", startMs)) ms、尾按这条 33 帧排到 \(String(format: "%.1f", tailMs)) ms"
                + "（尾是编码器把队列里剩下的编完，条越长摊到每帧越薄，全片只能当上限，不许乘帧数）")
        }
        rep.append("足迹 \(mem0)→\(VRFacts.footprintMB()) MB，本次峰值 \(memMax) MB")
        if encoded > 1 && writer.status == .completed {
            rep.append("成片 \(out.lastPathComponent) \(String(format: "%.2f", Double(size) / 1048576)) MB"
                + "，\(encoded) 帧 @ \(String(format: "%.1f", outFps)) fps ≈ \(String(format: "%.1f", Double(encoded) / outFps)) s")
            rep.append("存相册 " + VRPilot.toPhotos(out))
        }
        if !werr.isEmpty { rep.append("中止原因 \(werr)") }
        if !stop.isEmpty { rep.append("抽帧侧 \(stop)") }
        VRJournal.line("试片 结束 帧=\(samples.count) 编=\(encoded) 峰值\(memMax)MB \(werr)")
        return rep.joined(separator: "\n")
    }

    static func append(_ adaptor: AVAssetWriterInputPixelBufferAdaptor, _ input: AVAssetWriterInput,
                       _ writer: AVAssetWriter,
                       _ pb: CVPixelBuffer, at seconds: Double) -> Bool {
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        var tries = 0
        while !adaptor.append(pb, withPresentationTime: t) {
            tries += 1
            // AVAssetWriterInput 这边没有 status/error（编译器不认），失败只有 writer 那侧看得见
            if writer.status == .failed {
                VRJournal.line("append 失败 writer.status failed \(writer.error?.localizedDescription ?? "-")")
                return false
            }
            if tries > 400 { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }

    /// 标题帧：直接画进成片那张缓冲。字正着读就说明「像素缓冲 → 编码器 → 播放器」这条没有翻。
    static func drawTitle(_ pb: CVPixelBuffer, _ lines: [String]) {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        var y = CGFloat(h) - 90
        let font = UIFont.boldSystemFont(ofSize: CGFloat(min(60, max(26, w / 16))))
        for s in lines {
            // 键名 kCT* 与 NS* 本来就是同一串，塞两份只是自己覆盖自己。真正要紧的是值的类型：
            // UIFont 和 CTFont 是 toll-free 桥，UIColor 却桥不成 CGColor，而 CTLineDraw 按 CGColorRef 读它。
            let ctFont = font as CTFont
            let attr: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): UIColor.white.cgColor,
            ]
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: 40, y: y)
            let line: CTLine? = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attr))
            if let line = line { CTLineDraw(line, ctx) }
            y -= 78
        }
    }

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

    static func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }

    /// 相关系数 + 最小二乘斜率。某一侧几乎是常数时返回 -9（r 的定义本身失效），
    /// 用它和"真的没关系（r≈0）"区分开——混成一个数就会把"这条素材太干净"误报成"映射错了"。
    static func pearson(_ x: [Float], _ y: [Float]) -> (r: Double, slope: Double) {
        guard x.count == y.count, x.count > 1 else { return (-9, -9) }
        var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in 0..<x.count {
            let u = Double(x[i]), v = Double(y[i])
            sx += u; sy += v; sxx += u * u; syy += v * v; sxy += u * v
        }
        let n = Double(x.count)
        let vx = n * sxx - sx * sx
        let vy = n * syy - sy * sy
        guard vx > 1e-6, vy > 1e-6 else { return (-9, -9) }
        let cov = n * sxy - sx * sy
        return (cov / (vx * vy).squareRoot(), cov / vx)
    }

    static func unitsName(_ u: MLComputeUnits) -> String {
        switch u {
        case .cpuAndGPU: return "cpuAndGPU"
        case .cpuAndNeuralEngine: return "cpuAndNeuralEngine"
        case .all: return "all"
        case .cpuOnly: return "cpuOnly"
        @unknown default: return "未知(\(u.rawValue))"
        }
    }
}

/// 一条片子按"摆正 + 收进每眼尺寸"的口径出来，后面所有坐标都在左上角像素系里，不再套变换。
final class VRSource {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let vc: AVMutableVideoComposition
    let upW: Int
    let upH: Int
    let eyeW: Int
    let eyeH: Int
    let deg: Int
    let duration: Double
    let fps: Double

    init?(url: URL, eyeLong: Int) {
        asset = AVURLAsset(url: url)
        guard let t = asset.tracks(withMediaType: .video).first else {
            VRJournal.line("源 没有视频轨 \(url.lastPathComponent)")
            return nil
        }
        track = t
        let tf = t.preferredTransform
        let nat = t.naturalSize
        let cs = [CGPoint(x: 0, y: 0), CGPoint(x: nat.width, y: 0),
                  CGPoint(x: 0, y: nat.height), CGPoint(x: nat.width, y: nat.height)]
            .map { $0.applying(tf) }
        deg = VRUtil.deg(tf)
        upW = max(2, Int((cs.map { $0.x }.max()! - cs.map { $0.x }.min()!).rounded()))
        upH = max(2, Int((cs.map { $0.y }.max()! - cs.map { $0.y }.min()!).rounded()))
        let fit = VRUtil.fitEven(upW, upH, longEdge: eyeLong)
        eyeW = fit.w
        eyeH = fit.h
        duration = CMTimeGetSeconds(asset.duration)
        fps = Double(t.nominalFrameRate)
        let vc = AVMutableVideoComposition()
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: t)
        // 源的摆正变换之后再接一层缩放，直出「摆正且已经是每眼尺寸」的帧
        let sc = CGAffineTransform(scaleX: CGFloat(eyeW) / CGFloat(upW), y: CGFloat(eyeH) / CGFloat(upH))
        li.setTransform(tf.concatenating(sc), at: .zero)
        let ti = AVMutableVideoCompositionInstruction()
        ti.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        ti.layerInstructions = [li]
        vc.instructions = [ti]
        vc.renderSize = CGSize(width: eyeW, height: eyeH)
        vc.frameDuration = CMTime(value: 1, timescale: 600)
        self.vc = vc
        VRJournal.line("源 \(url.lastPathComponent) \(upW)x\(upH) 转\(deg)° → 每眼 \(eyeW)x\(eyeH)"
            + "｜\(String(format: "%.1f", duration)) s @ \(String(format: "%.1f", fps)) fps")
        if !(duration > 0.1) {
            VRJournal.line("源 时长读不出来 \(duration)")
            return nil
        }
    }

    /// 到点上取一帧，并把它拷进自己的缓冲（reader 给的那张会被回收，留住它等于留了个悬空引用）
    func framePB(at seconds: Double) -> (pb: CVPixelBuffer?, ms: Double, note: String) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let made = VRTech.pixelBuffer(width: eyeW, height: eyeH)
        guard let mine = made.pb else { return (nil, 0, made.note) }
        do {
            let reader = try AVAssetReader(asset: asset)
            // 这个 init 不返回 Optional（第 16 轮 CI 拿 guard let 绑它，报 conditional binding must have
            // Optional type）。下面赋给一个 Optional 变量只是隐式提升，别把它当成可失败 init；
            // videoComposition 是建好之后再挂的属性，真正的失败要到 startReading 才看得见。
            let madeOut: AVAssetReaderVideoCompositionOutput? = AVAssetReaderVideoCompositionOutput(
                videoTracks: [track],
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            guard let out = madeOut else {
                return (nil, 0, "VideoCompositionOutput 建不出来（这套 videoSettings 不被支持）")
            }
            out.videoComposition = vc
            reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600),
                                           duration: CMTime(seconds: 0.3, preferredTimescale: 600))
            reader.add(out)
            guard reader.startReading() else {
                return (nil, 0, "startReading 失败: \(reader.error?.localizedDescription ?? "-")")
            }
            var got: CVPixelBuffer?
            var tries = 0
            while got == nil && tries < 12 {
                guard let s = out.copyNextSampleBuffer() else { break }
                tries += 1
                if let b = CMSampleBufferGetImageBuffer(s) {
                    let w = CVPixelBufferGetWidth(b)
                    let h = CVPixelBufferGetHeight(b)
                    if w == eyeW && h == eyeH { got = b } else {
                        reader.cancelReading()
                        return (nil, 0, "每眼 \(eyeW)x\(eyeH) 但直出 \(w)x\(h)：composition 没生效")
                    }
                }
            }
            reader.cancelReading()
            guard let src = got else {
                return (nil, 0, "这个时间点 \(String(format: "%.2f", seconds)) s 直出为空帧")
            }
            VRUtil.copyRows(from: src, to: mine)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            return (mine, ms, "-")
        } catch {
            return (nil, 0, "reader/output 抛错: \(error)")
        }
    }
}

extension VRUtil {
    /// 逐行拷像素（两张都是 BGRA，行宽可能不同）
    static func copyRows(from src: CVPixelBuffer, to dst: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }
        guard let a = CVPixelBufferGetBaseAddress(src), let b = CVPixelBufferGetBaseAddress(dst) else { return }
        let w = min(CVPixelBufferGetWidth(src), CVPixelBufferGetWidth(dst))
        let h = min(CVPixelBufferGetHeight(src), CVPixelBufferGetHeight(dst))
        let sa = CVPixelBufferGetBytesPerRow(src)
        let sb = CVPixelBufferGetBytesPerRow(dst)
        let bytes = w * 4
        for y in 0..<h {
            memcpy(b + y * sb, a + y * sa, bytes)
        }
    }
}
