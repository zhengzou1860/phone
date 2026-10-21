import Foundation
import Vision
import CoreVideo
import UIKit
import CoreGraphics

/// 5 个对齐点怎么从 Vision 拿。整套换算从剪辑线 app/Sources/Cut.swift 的 Align 抄过来——
/// 那套在 iPhone 11 上机验死过两件事，这里一个字不改：
///   ① 五官的 normalizedPoints 是**脸框内的相对坐标**，原样乘整幅图的宽高＝绕质心的非等比拉伸，
///      PC 扫下来余弦从 0.86 掉到 0.635，和手机上量到的 0.627 是同一件事；
///   ② y 朝上还是朝下不许猜，靠「眼在鼻上、鼻在嘴上」这条几何在摆正的帧上判一次、全片共用。
/// 和剪辑线唯一不同的地方：这里不自己算朝向。整片走 AVAssetReaderVideoCompositionOutput，
/// 直出来的帧已经是摆正的（VR3D 那条线用它上机跑过一分钟素材），所以 k 恒为 0。
enum SwapVision {

    /// 一张脸里 5 个点的解剖学顺序，和 SwapGeo.template224 逐槽对应：
    /// 画面左眼、画面右眼、鼻尖、画面左嘴角、画面右嘴角。
    static func templateSlots() -> [CGPoint] { SwapGeo.template224() }

    /// Vision 归一化框（原点左下）→ 像素框（原点左上）
    static func pixelBox(_ rect: CGRect, _ w: Int, _ h: Int) -> CGRect {
        CGRect(x: rect.minX * CGFloat(w),
               y: (1 - rect.minY - rect.height) * CGFloat(h),
               width: rect.width * CGFloat(w),
               height: rect.height * CGFloat(h))
    }

    /// 只有框没有五官点时的 5 点近似（框内固定比例）。退回这一档时分数会掉，必须报出来。
    static func keypoints(from box: CGRect) -> [CGPoint] {
        let x = box.minX, y = box.minY, w = box.width, h = box.height
        return [
            CGPoint(x: x + 0.32 * w, y: y + 0.36 * h),
            CGPoint(x: x + 0.68 * w, y: y + 0.36 * h),
            CGPoint(x: x + 0.50 * w, y: y + 0.58 * h),
            CGPoint(x: x + 0.36 * w, y: y + 0.76 * h),
            CGPoint(x: x + 0.64 * w, y: y + 0.76 * h),
        ]
    }

    private static func regionPoints(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint]? {
        guard let r = r, r.pointCount > 0 else { return nil }
        let p = r.normalizedPoints
        return p.isEmpty ? nil : p
    }

    private static func centroid(_ r: VNFaceLandmarkRegion2D?) -> CGPoint? {
        guard let p = regionPoints(r) else { return nil }
        var x = 0.0, y = 0.0
        for v in p { x += Double(v.x); y += Double(v.y) }
        return CGPoint(x: x / Double(p.count), y: y / Double(p.count))
    }

    /// 一张脸的零件（**原始归一化坐标**，还没换像素、没排左右）：两眼中心、鼻尖、整圈外唇。
    /// 鼻尖＝鼻梁这条线上离嘴最近的那个点——不认数组顺序（顺序从没验过，上机看着像取了眉尖那头），
    /// 离嘴最近必然是鼻尖，且和坐标口径无关。
    static func parts(_ f: VNFaceObservation) -> (eyes: [CGPoint], nose: CGPoint, lips: [CGPoint])? {
        guard let lm = f.landmarks,
              let e1 = centroid(lm.leftEye), let e2 = centroid(lm.rightEye),
              let crest = regionPoints(lm.noseCrest), !crest.isEmpty,
              let lips = regionPoints(lm.outerLips), lips.count >= 3,
              let mouth = centroid(lm.outerLips)
        else { return nil }
        let d2 = { (p: CGPoint) -> CGFloat in
            let dx = p.x - mouth.x, dy = p.y - mouth.y
            return dx * dx + dy * dy
        }
        let nose = crest.min(by: { d2($0) < d2($1) }) ?? crest[0]
        return (eyes: [e1, e2], nose: nose, lips: lips)
    }

    /// 五官点的 y 口径：判出来就缓存，整片共用一个答案。
    static var yTopLeftOrigin: Bool? = nil
    static var topLeft: Bool { yTopLeftOrigin ?? true }

    /// 脸框内相对点 → 整幅图的归一化点（原点左下，和 boundingBox 同一套）
    static func toImageNorm(_ q: CGPoint, _ b: CGRect) -> CGPoint {
        CGPoint(x: b.minX + q.x * b.width,
                y: b.minY + (topLeft ? 1 - q.y : q.y) * b.height)
    }

    /// 五官点 → 像素点（原点左上、y 向下）
    static func toPixels(_ q: CGPoint, box b: CGRect, _ w: Int, _ h: Int) -> CGPoint {
        let n = toImageNorm(q, b)
        return CGPoint(x: n.x * CGFloat(w), y: (1 - n.y) * CGFloat(h))
    }

    /// 两种口径各摆一遍看谁满足「眼在鼻上、鼻在嘴上」；两边同判时返回的 ok 两位相等＝这一帧定不了论。
    private static func originVerdict(_ f: VNFaceObservation)
        -> (ok: [Bool], desc: [String], raw: String, box: String)? {
        guard let p = parts(f),
              let ml = p.lips.min(by: { $0.x < $1.x }), let mr = p.lips.max(by: { $0.x < $1.x })
        else { return nil }
        let set = p.eyes + [p.nose, ml, mr]
        var ok: [Bool] = []
        var desc: [String] = []
        for tl in [true, false] {
            let y = set.map { tl ? $0.y : 1 - $0.y }
            let good = max(y[0], y[1]) < y[2] && y[2] < min(y[3], y[4])
            ok.append(good)
            desc.append("y\(tl ? "不翻" : "翻")\(good ? "√" : "×")")
        }
        let raw = set.map { String(format: "%.2f/%.2f", $0.x, $0.y) }.joined(separator: " ")
        let b = f.boundingBox
        let box = String(format: "框 %.2f/%.2f %.2fx%.2f", b.minX, b.minY, b.width, b.height)
        return (ok, desc, raw, box)
    }

    /// 把 y 原点自己判出来并缓存。判据不需要任何 API 假设：喂进来的帧是摆正的，
    /// 所以眼睛必须在鼻尖上面、鼻尖必须在嘴角上面（y 向下＝数值更小）。
    /// 两种口径各摆一遍，谁满足这条谁赢；两边同判时才退回文档口径（左上原点）。
    @discardableResult
    static func settleOrigin(face f: VNFaceObservation) -> String {
        guard let v = originVerdict(f) else { return "y 原点没判（五官点缺失）" }
        let how: String
        if v.ok[0] != v.ok[1] { yTopLeftOrigin = v.ok[0]; how = "判出" }
        else if yTopLeftOrigin == nil { yTopLeftOrigin = true; how = "两边同判→按文档(左上)" }
        else { how = "两边同判→沿用" }
        return "y 原点 \(v.desc.joined(separator: "｜"))→「\(topLeft ? "不翻" : "翻")」(\(how))｜\(v.box)｜5点 \(v.raw)"
    }

    /// 只认「两种口径只有一个满足」这一种定论，定不了返回 nil 让下一帧再判。
    /// 出片循环里补判用的就是这一把：那条路上没有源脸照片，默认值当结论就会整片映成镜像。
    static func settleOriginStrict(face f: VNFaceObservation) -> String? {
        guard let v = originVerdict(f), v.ok[0] != v.ok[1] else { return nil }
        yTopLeftOrigin = v.ok[0]
        return "y 原点 \(v.desc.joined(separator: "｜"))→「\(topLeft ? "不翻" : "翻")」(判出)｜\(v.box)｜5点 \(v.raw)"
    }

    /// 一张脸要送进对齐的那 5 个像素点。左右槽位按 x 排在摆正后的空间里挑，
    /// 所以 Vision 的 leftEye/rightEye 到底指被拍者哪一侧这个从没验过的口径问题不参与结果。
    static func sendPoints(face f: VNFaceObservation, w: Int, h: Int) -> (pts: [CGPoint], src: String) {
        let b = f.boundingBox
        if let p = parts(f) {
            let U = { (q: CGPoint) -> CGPoint in SwapVision.toPixels(q, box: b, w, h) }
            let e = p.eyes.map(U), lp = p.lips.map(U), n = U(p.nose)
            let eyes = e[0].x <= e[1].x ? [e[0], e[1]] : [e[1], e[0]]
            let corners = [lp.min(by: { $0.x < $1.x })!, lp.max(by: { $0.x < $1.x })!]
            return ([eyes[0], eyes[1], n, corners[0], corners[1]], "真点位")
        }
        return (keypoints(from: pixelBox(b, w, h)), "框猜")
    }

    // MARK: - 检测

    /// 检一张缓冲里的脸。抛错就把错误文本带回来（不许静默变成「0 张脸」）。
    static func faces(_ buffer: CVPixelBuffer, _ request: VNDetectFaceLandmarksRequest) -> ([VNFaceObservation], String) {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            return (request.results ?? [], "")
        } catch {
            return ([], "Vision 抛错: \(error)")
        }
    }

    static func faces(_ image: CGImage, _ request: VNDetectFaceLandmarksRequest) -> ([VNFaceObservation], String) {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            return (request.results ?? [], "")
        } catch {
            return ([], "Vision 抛错: \(error)")
        }
    }

    /// 一帧里挑哪张脸换：摆正后的框、短边最大的那张（PC 原型 detect_largest 同口径）。
    /// 返回的 index 用于回原数组取点，短边同时带回来当"这张脸够不够大"的依据。
    static func largest(_ obs: [VNFaceObservation], w: Int, h: Int) -> (index: Int, shortSide: Double, box: CGRect)? {
        var best = -1.0, bi = -1, bb = CGRect.zero
        for (i, f) in obs.enumerated() {
            let px = pixelBox(f.boundingBox, w, h)
            let s = Double(min(px.width, px.height))
            if s > best { best = s; bi = i; bb = px }
        }
        guard bi >= 0 else { return nil }
        return (bi, best, bb)
    }

    /// 一次对齐的全部产物：正向矩阵（整幅→224）、它的逆（224→整幅，回贴要用的 back）、
    /// 用的点位是哪一档（真点位／框猜）、点位多边形是不是被排成了镜像、以及拟合质量。
    struct Alignment {
        let fwd: SwapGeo.Affine
        let back: SwapGeo.Affine
        let mirrored: Bool        // 5 点的手性与模板相反＝y 口径判错，贴回去是一张翻面的人脸，这帧不许换
        let chir: (nose: Double, mouth: Double)   // 判镜像那两把叉的原值：被挡的帧要靠它当场复盘点位
        let resid224: Double      // 5 个点到模板的平均距离，单位＝224 方块里的像素
        let residPx: Double       // 同一件事折回原图像素（除以缩放），和 PC 那张 ±2/4/8 px 容忍表直接对账
        let det: Double           // 相似拟合下＝缩放平方，恒正（镜像改由 mirrored 判）
        let ratio: Double         // 两个奇异值之比；4 参相似恒为 1，留着当「这版没走 6 参」的自证
        let pts: [CGPoint]
        let src: String
        let shortSide: Double
    }

    /// 整片 5 点轨迹对完称高斯（σ＝2 帧＝13 抽头、半径 6），一次走完⇒返回一整条。
    /// 为什么对称而不是「上一帧加权平均」：因果滤波有滞后，本机在同一格上量到每帧甩开 16.6 px、p95 36 px
    /// ＝快动段补丁落在头后面，看着是重影；对称核零滞后，代价只在加减速的那几帧（σ2 量到 2.9 px、p95 6.5 px，
    /// 而这一片每帧真的挪 3.4~7.2 px，所以滞后比运动本身还小）。
    /// 越界那一侧按「重复边缘」取（与 numpy 的 pad(mode='edge') 同口径），首末帧不会被稀释成 0。
    /// 一次走完而不是逐帧调：逐帧调每次都要重读整条轨迹，9 分钟那片就是 O(N²)。
    static func smoothTrack(_ track: [[CGPoint]], sigma: Double = 2.0) -> [[CGPoint]] {
        let n = track.count
        guard n > 0 else { return [] }
        let w = Int(2 * (3 * sigma).rounded() + 1)          // σ＝2 → 13
        let r = w / 2
        var k = [Double](repeating: 0, count: w)
        var tot = 0.0
        for j in 0..<w {
            let z = Double(j - r) / sigma
            k[j] = exp(-0.5 * z * z)
            tot += k[j]
        }
        for j in 0..<w { k[j] /= tot }
        var out: [[CGPoint]] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard track[i].count == 5 else { out.append(track[i]); continue }
            var sx = [Double](repeating: 0, count: 5), sy = [Double](repeating: 0, count: 5)
            for j in 0..<w {
                let t = min(max(i + j - r, 0), n - 1)
                for p in 0..<5 {
                    sx[p] += k[j] * Double(track[t][p].x)
                    sy[p] += k[j] * Double(track[t][p].y)
                }
            }
            out.append((0..<5).map { CGPoint(x: sx[$0], y: sy[$0]) })
        }
        return out
    }

    /// 一张脸（或预检存下来的 5 个点）→ 对齐产物。拟合口径＝4 参相似，见 SwapGeo.fitSimilarity。
    static func align(face f: VNFaceObservation, w: Int, h: Int) -> Alignment? {
        let (pts, src) = sendPoints(face: f, w: w, h: h)
        let box = pixelBox(f.boundingBox, w, h)
        return align(pts: pts, src: src, shortSide: Double(min(box.width, box.height)))
    }

    /// 同上，但点位已经在手上（预检趟那一格：整片的点先存下来，出片这趟只取平滑后的）。
    static func align(pts: [CGPoint], src: String, shortSide: Double) -> Alignment? {
        let tpl = SwapGeo.template224()
        guard pts.count == tpl.count,
              let fwd = SwapGeo.fitSimilarity(pts, tpl),
              let back = SwapGeo.inverse(fwd) else { return nil }
        let det = fwd.a * fwd.e - fwd.b * fwd.d          // 相似拟合下恒正＝a²＋b²
        guard det > 1e-9 else { return nil }
        // 镜像只能这样判：相似拟合不会把点位映反（它只会给一个转正的最优解），
        // 而 y 口径搞错时 5 个点是真被翻了面的，只有手性认得出来。翻面＝这帧不换。
        // 判据是眼轴×鼻位、眼轴×嘴角中点这两把叉各自与模板比号（0.25 起）：
        // 旧的那式＝5 点围成多边形的有向面积，它是两大块相消，合成几何算到俯仰 30° 只剩模板的 8%、
        // 45° 直接翻号＝抬头低头被当成镜像挡掉（tools/_swap_yaw.py，两把叉在这些姿态下符号都不动）。
        let chir = SwapGeo.chirality(pts)
        let chirTpl = SwapGeo.chirality(tpl)
        let mirrored = chir.nose * chirTpl.nose < 0 || chir.mouth * chirTpl.mouth < 0
        var sum = 0.0
        for i in 0..<pts.count {
            let px = Double(pts[i].x), py = Double(pts[i].y)
            let qx = fwd.a * px + fwd.b * py + fwd.c, qy = fwd.d * px + fwd.e * py + fwd.f
            let dx = qx - Double(tpl[i].x), dy = qy - Double(tpl[i].y)
            sum += (dx * dx + dy * dy).squareRoot()
        }
        let resid = sum / Double(pts.count)
        // J = [a b; d e]，JJᵀ 的两个特征值开方＝两个奇异值。相似拟合下这一对比值恒为 1，
        // 留在日志里当「这一版真的没走 6 参那一式」的自证。
        let t11 = fwd.a * fwd.a + fwd.b * fwd.b
        let t22 = fwd.d * fwd.d + fwd.e * fwd.e
        let t12 = fwd.a * fwd.d + fwd.b * fwd.e
        let tr = t11 + t22, dg = t11 * t22 - t12 * t12
        let disc = (max(0.0, tr * tr / 4.0 - dg)).squareRoot()
        let lmax = tr / 2.0 + disc, lmin = max(0.0, tr / 2.0 - disc)
        let sMax = lmax.squareRoot(), sMin = lmin.squareRoot()
        let ratio = sMin > 1e-9 ? sMax / sMin : 999.0
        let scale = det.squareRoot()
        return Alignment(fwd: fwd, back: back, mirrored: mirrored, chir: chir,
                         resid224: resid, residPx: scale > 1e-9 ? resid / scale : 999.0,
                         det: det, ratio: ratio, pts: pts, src: src, shortSide: shortSide)
    }

    /// 静帧（相册里那张源脸）→ 摆正的 CGImage。走 UIKit 重画一遍，
    /// EXIF 朝向、宽高等于像素尺寸这两件事一起解决，之后 k 恒为 0。
    static func uprightImage(_ image: UIImage) -> (cg: CGImage?, note: String) {
        guard let raw = image.cgImage else { return (nil, "这张图取不出 cgImage") }
        let size = image.size
        let scale = image.scale
        let w = max(1, Int((size.width * scale).rounded()))
        let h = max(1, Int((size.height * scale).rounded()))
        let cs = raw.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return (nil, "建不出重画用的上下文（\(w)x\(h)）")
        }
        ctx.interpolationQuality = .high
        ctx.draw(raw, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return (nil, "makeImage 失败") }
        return (out, "源静帧 \(w)x\(h)（重画摆正）")
    }
}
