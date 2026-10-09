import Foundation
import AVFoundation
import CoreMedia
import Vision
import CoreML
import UIKit
import Photos
import SwiftUI

// MARK: - 对齐裁脸（把框里的脸转正成 112x112，喂尺子）

enum Align {

    static let side = 112

    /// arcface 标准 5 点模板（112x112，y 向下）。PC 原型 insightface norm_crop 用的同一套。
    static let template: [CGPoint] = [
        CGPoint(x: 30.2946, y: 51.6963),
        CGPoint(x: 65.5318, y: 51.5018),
        CGPoint(x: 48.0252, y: 71.7366),
        CGPoint(x: 33.5493, y: 92.3655),
        CGPoint(x: 62.7262, y: 92.2072),
    ]

    /// Vision 归一化框（原点左下）→ 像素框（原点左上）
    static func pixelBox(_ rect: CGRect, _ w: Int, _ h: Int) -> CGRect {
        CGRect(x: rect.minX * CGFloat(w),
               y: (1 - rect.minY - rect.height) * CGFloat(h),
               width: rect.width * CGFloat(w),
               height: rect.height * CGFloat(h))
    }

    /// 只有框没有五官点时的 5 点近似（框内固定比例）
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

    // MARK: 朝向
    // 竖屏片走 AVAssetReader 直出来是**躺着**的（这条路上没有 preferredTransform 可套），
    // 而锚点那条路（AVAssetImageGenerator appliesPreferredTrackTransform=true）是正着的。
    // PC 实测：拿框猜点位时，只要朝向不对，同一张脸的余弦一律塌到 0.11~0.17（闸门 0.30）
    // ⇒ 整片 0 命中就是这么来的。这里不"把整张图转正"（太贵），而是把点换算到转正坐标系，
    // 再映回 raw 像素——相似变换会把旋转一起吸收掉，裁出的 112×112 自然是正着的。

    /// raw 像素点 → 转正后的像素点。k = 直出的图是正片逆时针转了 k×90°。
    static func toUpright(_ p: CGPoint, k: Int, w: Int, h: Int) -> CGPoint {
        switch k {
        case 1: return CGPoint(x: p.y, y: CGFloat(w - 1) - p.x)
        case 2: return CGPoint(x: CGFloat(w - 1) - p.x, y: CGFloat(h - 1) - p.y)
        case 3: return CGPoint(x: CGFloat(h - 1) - p.y, y: p.x)
        default: return p
        }
    }

    /// toUpright 的逆：转正后的像素点 → raw 像素点
    static func toRaw(_ p: CGPoint, k: Int, w: Int, h: Int) -> CGPoint {
        switch k {
        case 1: return CGPoint(x: CGFloat(w - 1) - p.y, y: p.x)
        case 2: return CGPoint(x: CGFloat(w - 1) - p.x, y: CGFloat(h - 1) - p.y)
        case 3: return CGPoint(x: p.y, y: CGFloat(h - 1) - p.x)
        default: return p
        }
    }

    /// raw 像素框 → 转正后的外接框（k=0 时就是它自己）
    static func uprightBox(_ b: CGRect, k: Int, w: Int, h: Int) -> CGRect {
        let c = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                 CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY)]
            .map { Align.toUpright($0, k: k, w: w, h: h) }
        let x0 = c.map { $0.x }.min() ?? 0, x1 = c.map { $0.x }.max() ?? 0
        let y0 = c.map { $0.y }.min() ?? 0, y1 = c.map { $0.y }.max() ?? 0
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private static func regionPoints(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint]? {
        guard let r = r, r.pointCount > 0 else { return nil }
        // Swift 侧 normalizedPoints 是非可选的 [CGPoint]（Apple 文档声明 var normalizedPoints: [CGPoint]）
        let p = r.normalizedPoints
        return p.isEmpty ? nil : p
    }

    private static func centroid(_ r: VNFaceLandmarkRegion2D?) -> CGPoint? {
        guard let p = regionPoints(r) else { return nil }
        var x = 0.0, y = 0.0
        for v in p { x += Double(v.x); y += Double(v.y) }
        return CGPoint(x: x / Double(p.count), y: y / Double(p.count))
    }

    /// 一张脸的零件（**原始归一化坐标**，没换像素、没排左右）：两眼中心、鼻尖、整圈外唇。
    /// 左右必须等"转正后的空间"里再排：k=1/3 那块缓冲里脸是躺着的，x 极值的两个唇点是
    /// 上唇缘和下唇缘，不是嘴角——在原始空间里挑嘴角等于喂错点给尺子。
    static func parts(_ f: VNFaceObservation) -> (eyes: [CGPoint], nose: CGPoint, lips: [CGPoint])? {
        guard let lm = f.landmarks,
              let e1 = centroid(lm.leftEye), let e2 = centroid(lm.rightEye),
              let nose = regionPoints(lm.noseCrest)?.last,
              let lips = regionPoints(lm.outerLips), lips.count >= 3
        else { return nil }
        return (eyes: [e1, e2], nose: nose, lips: lips)
    }

    /// 五官点的 y 原点。上机实测黄点上下反了（鼻尖差不多、眼和嘴互换）⇒ 点的口径和
    /// boundingBox（左下原点，那个是我逐帧核过的）不是同一套。到底哪个对不猜，见 settleOrigin。
    /// nil = 还没在摆正的帧上判过；判过之前先按 Apple 文档口径（左上原点、不翻）。
    static var yTopLeftOrigin: Bool? = nil
    static var topLeft: Bool { yTopLeftOrigin ?? true }

    /// 归一化五官点 → 像素点（原点左上、y 向下）。用 settleOrigin 判出来的那套 y 口径。
    static func toPixels(_ p: CGPoint, _ w: Int, _ h: Int) -> CGPoint {
        CGPoint(x: p.x * CGFloat(w), y: (topLeft ? p.y : 1 - p.y) * CGFloat(h))
    }

    /// 把 y 原点自己判出来并缓存（全片共用一个答案）。判据不需要任何 API 假设：
    /// 喂进来的这一帧是摆正的（frameImage 套了 preferredTransform，检测用 .up），
    /// 所以**眼睛必须在鼻尖上面、鼻尖必须在嘴角上面**（y 向下＝数值更小）。
    /// 两种口径各摆一遍，谁满足这条谁赢；只有两边同判时才退回文档口径（左上原点）。
    /// 只读 y，且嘴角按 x 挑（x 不参与翻转），所以这一层不需要转正也成立。
    static func settleOrigin(face f: VNFaceObservation) -> String {
        guard let p = parts(f),
              let ml = p.lips.min(by: { $0.x < $1.x }), let mr = p.lips.max(by: { $0.x < $1.x })
        else { return "y 原点没判（五官点缺失）" }
        let set = p.eyes + [p.nose, ml, mr]
        var ok: [Bool] = []
        var desc: [String] = []
        for tl in [true, false] {
            let y = set.map { tl ? $0.y : 1 - $0.y }
            let good = max(y[0], y[1]) < y[2] && y[2] < min(y[3], y[4])
            ok.append(good)
            desc.append("y\(tl ? "不翻" : "翻")\(good ? "√" : "×")")
        }
        let how: String
        if ok[0] != ok[1] { yTopLeftOrigin = ok[0]; how = "判出" }
        else if yTopLeftOrigin == nil { yTopLeftOrigin = true; how = "两边同判→按文档(左上)" }
        else { how = "两边同判→沿用" }
        let raw = set.map { String(format: "%.2f/%.2f", $0.x, $0.y) }.joined(separator: " ")
        return "y 原点 \(desc.joined(separator: "｜"))→「\(topLeft ? "不翻" : "翻")」(\(how))｜5点 \(raw)"
    }

    /// 一张脸送进尺子要的那 5 个点（模板口径：左眼、右眼、鼻尖、左嘴角、右嘴角，
    /// "左"指**转正后的画面左侧**）。有真五官点就用真的；缺任一 region 就整张退回按框猜，
    /// 并把用的哪一种报回来——退回"框猜"时分数会掉，屏幕上必须看得见。
    /// 左右槽位全部在转正后的空间里按 x 排，所以 Vision 的 left/right 到底指被拍者哪一侧
    /// 这个我从没验过的口径问题，根本不参与结果。
    static func sendPoints(face f: VNFaceObservation, k: Int, w: Int, h: Int) -> (pts: [CGPoint], src: String) {
        var up: [CGPoint]? = nil
        var src = "框猜"
        if let p = parts(f) {
            let U = { (q: CGPoint) -> CGPoint in Align.toUpright(Align.toPixels(q, w, h), k: k, w: w, h: h) }
            let e = p.eyes.map(U), lp = p.lips.map(U), n = U(p.nose)
            let eyes = e[0].x <= e[1].x ? [e[0], e[1]] : [e[1], e[0]]
            let corners = [lp.min(by: { $0.x < $1.x })!, lp.max(by: { $0.x < $1.x })!]
            up = [eyes[0], eyes[1], n, corners[0], corners[1]]
            src = "真点位"
        }
        let pts = up ?? keypoints(from: uprightBox(pixelBox(f.boundingBox, w, h), k: k, w: w, h: h))
        return (pts.map { Align.toRaw($0, k: k, w: w, h: h) }, src)
    }

    /// 屏幕上画黄点用的 5 个点，给成**显示口径的归一化点**（原点左上、y 向下，和绿框那套换算同向）。
    /// 画点不再自己决定翻不翻：它跟着 settleOrigin 判出来的口径，所以点准不准＝那个口径对不对。
    static func markerPoints(_ f: VNFaceObservation) -> [CGPoint]? {
        guard let p = parts(f) else { return nil }
        let D = { (q: CGPoint) -> CGPoint in CGPoint(x: q.x, y: Align.topLeft ? q.y : 1 - q.y) }
        let lp = p.lips.map(D)
        return p.eyes.map(D) + [D(p.nose)] + [lp.min(by: { $0.x < $1.x })!, lp.max(by: { $0.x < $1.x })!]
    }

    /// 相似变换（旋转+等比缩放+平移）最小二乘：dst = [[a,-b],[b,a]]·src + t
    static func fit(src: [CGPoint], dst: [CGPoint]) -> (a: Double, b: Double, tx: Double, ty: Double)? {
        guard src.count == dst.count, src.count >= 3 else { return nil }
        let n = Double(src.count)
        var msx = 0.0, msy = 0.0, mdx = 0.0, mdy = 0.0
        for i in 0..<src.count {
            msx += Double(src[i].x); msy += Double(src[i].y)
            mdx += Double(dst[i].x); mdy += Double(dst[i].y)
        }
        msx /= n; msy /= n; mdx /= n; mdy /= n
        var ar = 0.0, ai = 0.0, nn = 0.0
        for i in 0..<src.count {
            let sx = Double(src[i].x) - msx, sy = Double(src[i].y) - msy
            let dx = Double(dst[i].x) - mdx, dy = Double(dst[i].y) - mdy
            ar += dx * sx + dy * sy
            ai += dy * sx - dx * sy
            nn += sx * sx + sy * sy
        }
        guard nn > 1e-9 else { return nil }
        let a = ar / nn, b = ai / nn
        return (a, b, mdx - (a * msx - b * msy), mdy - (b * msx + a * msy))
    }

    /// BGRA 像素 → 3*112*112 的 RGB 归一化张量。(v-127.5)/127.5 是 insightface
    /// arcface_onnx.get_feat 里 blobFromImages(mean=127.5, scale=1/127.5, swapRB=True) 的口径，逐字抄它。
    static func cropBGRA(_ base: UnsafeRawPointer, bytesPerRow: Int,
                         w: Int, h: Int, keypoints kp: [CGPoint]) -> [Float]? {
        guard kp.count == 5, let t = fit(src: kp, dst: template),
              w > 0, h > 0, bytesPerRow >= w * 4 else { return nil }
        let s2 = t.a * t.a + t.b * t.b
        guard s2 > 1e-9 else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let rowPix = bytesPerRow / 4
        var out = [Float](repeating: 0, count: 3 * side * side)
        let plane = side * side
        for oy in 0..<side {
            for ox in 0..<side {
                let u = Double(ox) - t.tx, v = Double(oy) - t.ty
                let fx = (t.a * u + t.b * v) / s2
                let fy = (-t.b * u + t.a * v) / s2
                let r = bilinear(p, rowPix, w, h, fx, fy)
                let k = oy * side + ox
                out[k] = r.0
                out[plane + k] = r.1
                out[2 * plane + k] = r.2
            }
        }
        return out
    }

    /// 越界补 0：cv2 warpAffine 的 borderValue 就是 0，改成边缘复制就和 PC 标定不同口径
    private static func bilinear(_ p: UnsafePointer<UInt8>, _ rowPix: Int, _ w: Int, _ h: Int,
                                 _ fx: Double, _ fy: Double) -> (Float, Float, Float) {
        guard fx >= 0, fy >= 0, fx <= Double(w - 1), fy <= Double(h - 1) else { return (0, 0, 0) }
        let x0 = Int(fx), y0 = Int(fy)
        let dx = Float(fx - Double(x0)), dy = Float(fy - Double(y0))
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        func ch(_ c: Int, _ xx: Int, _ yy: Int) -> Float { Float(p[yy * rowPix * 4 + xx * 4 + c]) }
        var res: [Float] = []
        for c in [2, 1, 0] {   // BGRA 内存序里的 R G B
            let v = (ch(c, x0, y0) + (ch(c, x1, y0) - ch(c, x0, y0)) * dx)
                + ((ch(c, x0, y1) + (ch(c, x1, y1) - ch(c, x0, y1)) * dx)
                   - (ch(c, x0, y0) + (ch(c, x1, y0) - ch(c, x0, y0)) * dx)) * dy
            res.append((v - 127.5) / 127.5)
        }
        return (res[0], res[1], res[2])
    }
}

/// 向量的体检项。喂错口径（通道序/归一化/内存布局）时模型照样回一个合法形状的向量，
/// 屏幕上看不出任何毛病——唯一露馅的地方是它的模长和逐维量级。
/// PC 上同一把尺子（w600k_mbf）的真实锚点模长实测 10.9~24.9，对不上就是前处理错了。
func vecFingerprint(_ v: [Float]) -> String {
    let n = v.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
    let head = v.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: " ")
    return "模长 \(String(format: "%.1f", n))｜维数 \(v.count)｜前 3 维 [\(head)]"
}

func cosine(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return -9 }
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<a.count {
        let x = Double(a[i]), y = Double(b[i])
        dot += x * y; na += x * x; nb += y * y
    }
    guard na > 1e-12, nb > 1e-12 else { return -9 }
    return dot / (na.squareRoot() * nb.squareRoot())
}

// MARK: - 尺子（包里的 mbf，一个实例常驻）

final class Ruler {

    static let shared = Ruler()

    private var model: MLModel?
    private var inputName = ""
    private var outputName = ""
    private var inputDims: [NSNumber] = []
    private var inputIsImage = false
    var failures = 0
    var lastError = ""
    var note = "还没加载"

    func load() -> Bool {
        if model != nil { return true }
        let loc = ModelBench.locate()
        guard let url = loc.url else {
            note = "包里没有尺子: \(loc.note)"
            return false
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine
        do {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let m = try MLModel(contentsOf: url, configuration: cfg)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            let md = m.modelDescription
            guard let name = md.inputDescriptionsByName.keys.first,
                  let desc = md.inputDescriptionsByName[name],
                  let out = md.outputDescriptionsByName.keys.first else {
                note = "模型没有输入/输出描述"
                return false
            }
            inputIsImage = (desc.type == .image)
            if let c = desc.multiArrayConstraint {
                inputDims = c.shape.map { NSNumber(value: max(1, $0.intValue)) }
            }
            model = m
            inputName = name
            outputName = out
            let dims = inputDims.map { $0.intValue }
            note = "加载 \(String(format: "%.0f", ms)) ms（\(loc.note)）"
                + "\n输入 \(name) \(inputIsImage ? "图像" : "多数组") dims=\(dims)｜输出 \(out)"
            Journal.line("尺子 \(note)")
            return true
        } catch {
            note = "加载失败: \(error)"
            Journal.line("尺子 \(note)")
            return false
        }
    }

    /// 用完即死：整趟跑完把模型断掉，足迹才真回得来（只断 pipeline 那条引用实测一点没回）
    func release() {
        model = nil
        inputName = ""
        outputName = ""
        inputDims = []
        Journal.line("尺子 已释放 足迹\(Facts.footprintMB())MB")
    }

    /// 3*112*112 归一化张量 → 向量。任何一次失败都记进 failures + lastError，
    /// 因为"尺子根本没跑起来"在报告里长得和"这片子里没有那个人"一模一样。
    func embed(_ rgb: [Float]) -> [Float]? {
        func bail(_ why: String) -> [Float]? {
            failures += 1
            lastError = why
            return nil
        }
        guard load() else { return bail(note) }
        guard let model = model else { return bail("模型句柄没了") }
        guard !inputIsImage else { return bail("这个 CoreML 模型要的是图像输入，不是多数组") }
        let need = 3 * Align.side * Align.side
        guard rgb.count == need else { return bail("送进来的张量 \(rgb.count) 个数，应为 \(need)") }
        let dims = inputDims.isEmpty ? ([1, 3, Align.side, Align.side] as [Int]) : inputDims.map { $0.intValue }
        guard dims.reduce(1, *) == need else {
            return bail("模型声明的输入形状 \(dims) 乘出来是 \(dims.reduce(1, *))，和 \(need) 不等")
        }
        let arr: MLMultiArray
        do {
            arr = try MLMultiArray(shape: dims.map { NSNumber(value: $0) }, dataType: .float32)
        } catch { return bail("造 MLMultiArray \(dims) 失败: \(error)") }
        let p = arr.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in 0..<need { p[i] = rgb[i] }
        let provider: MLFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: arr)])
        } catch { return bail("装输入字典失败: \(error)") }
        do {
            let res = try model.prediction(from: provider)
            guard let v = res.featureValue(for: outputName), let out = v.multiArrayValue, out.count > 0 else {
                return bail("输出里没有多数数组（\(outputName)）")
            }
            // 按模型自己声明的元素类型读：输出是 float16 时拿 Float32 指针读会静默得到一堆垃圾，
            // 而"垃圾向量"在报告里和"这片子里没有那个人"长得一模一样。
            // 这三条指针写法就是 0.6 那版在真机上跑通的 ModelBench.makeInputs 里的同一套。
            var vec = [Float](repeating: 0, count: out.count)
            switch out.dataType {
            case .float32:
                let q = out.dataPointer.assumingMemoryBound(to: Float32.self)
                for i in 0..<out.count { vec[i] = q[i] }
            case .float16:
                let q = out.dataPointer.assumingMemoryBound(to: Float16.self)
                for i in 0..<out.count { vec[i] = Float(q[i]) }
            case .double:
                let q = out.dataPointer.assumingMemoryBound(to: Double.self)
                for i in 0..<out.count { vec[i] = Float(q[i]) }
            default:
                return bail("输出元素类型 \(out.dataType.rawValue) 我还不会读（维数 \(out.count)）")
            }
            return vec
        } catch { return bail("predict 失败: \(error)") }
    }
}

// MARK: - 时间段

struct Segment {
    let startSample: Int
    let endSample: Int

    func seconds(fps: Double, step: Int) -> (start: Double, end: Double, length: Double) {
        let a = Double(startSample * step) / fps
        let b = Double((endSample + 1) * step) / fps
        return (a, b, b - a)
    }
}

/// 连续 kIn 帧命中才开段；连续 kOut 帧丢失才收尾；缺口 <kOut 的相邻段合并（与 PC 原型同一套）
func segmentsFromKeep(_ keep: [Bool], kIn: Int = 2, kOut: Int = 3) -> [Segment] {
    var segs: [Segment] = []
    let n = keep.count
    var i = 0
    while i < n {
        while i < n, !keep[i] { i += 1 }
        if i >= n { break }
        var j = i
        while j + 1 < n, keep[j + 1] { j += 1 }
        var start: Int? = nil
        var end = i
        var run = 0
        for k in i...j {
            run += 1
            if run >= kIn && start == nil { start = k - run + 1 }
            end = k
        }
        if let s = start {
            if let last = segs.last, (s - last.endSample - 1) < kOut {
                segs.removeLast()
                segs.append(Segment(startSample: last.startSample, endSample: end))
            } else {
                segs.append(Segment(startSample: s, endSample: end))
            }
        }
        i = j + 1
    }
    return segs
}

final class StopFlag {
    var on = false
}

// MARK: - 扫描引擎（后台线程）

struct ScanOutcome {
    var text = ""
    var keep: [Bool] = []
    var segments: [Segment] = []
    var samples = 0
    var framesWithFace = 0
    var gated = 0
    var hits = 0
    var bigSims: [Double] = []
    var detectMs = 0.0
    var embedMs = 0.0
    var memMax = 0
}

enum CutEngine {

    /// 像素只在锁着的那一会儿有效，所以一律用闭包递出去，别把指针带出锁外
    static func withPixels(_ image: CGImage, _ body: (UnsafeRawPointer, Int) -> Bool) -> Bool {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: info) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return false }
        return body(UnsafeRawPointer(data), ctx.bytesPerRow)
    }

    static func withPixels(_ buffer: CVPixelBuffer, _ body: (UnsafeRawPointer, Int) -> Bool) -> Bool {
        guard CVPixelBufferLockBaseAddress(buffer, []) == noErr,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let ok = body(UnsafeRawPointer(base), CVPixelBufferGetBytesPerRow(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return ok
    }

    /// 停在某秒取一帧。appliesPreferredTrackTransform=true ⇒ 竖屏片拿回来就是 1080x1920，
    /// 不必自己转——这是"旋转过的脸喂进尺子会掉成陌生人"那个坑的正解。
    static func frameImage(asset: AVURLAsset, at seconds: Double) -> (CGImage?, String) {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        do {
            let img = try gen.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                          actualTime: nil)
            return (img, "\(img.width)x\(img.height) @ \(String(format: "%.2f", seconds))s")
        } catch {
            return (nil, "取帧失败: \(error)")
        }
    }

    /// 静帧检脸。用 landmarks 版而不是只检框：锚点也要拿真五官点，
    /// 和扫描那侧同口径（否则一边"框猜"一边"真点位"，PC 实测同一张脸就掉到 0.19~0.89）。
    static func faces(in image: CGImage) -> [VNFaceObservation] {
        let req = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([req])
            return req.results ?? []
        } catch {
            Journal.line("静帧检测抛错 \(error)")
            return []
        }
    }

    /// 静帧里第 index 张脸 → 锚点向量。返回向量＋这张脸在源片坐标下的短边 px＋失败原因＋点位来源。
    /// k=0：frameImage 走的是 appliesPreferredTrackTransform=true，拿回来就是正着的。
    static func anchorFrom(image: CGImage, face: VNFaceObservation,
                           sideScale: Double) -> ([Float]?, Double, String, String) {
        let shortSide = min(face.boundingBox.width * CGFloat(image.width),
                            face.boundingBox.height * CGFloat(image.height)) * sideScale
        // 这一帧是摆正的 ⇒ 只有在这里才有资格判 y 原点；判完 sendPoints 才用得上
        let origin = Align.settleOrigin(face: face)
        let (kp, src) = Align.sendPoints(face: face, k: 0, w: image.width, h: image.height)
        let box = Align.pixelBox(face.boundingBox, image.width, image.height)
        var vec: [Float]? = nil
        var why = "这张静帧的像素锁不上"
        _ = withPixels(image) { base, bpr in
            guard let crop = Align.cropBGRA(base, bytesPerRow: bpr, w: image.width,
                                            h: image.height, keypoints: kp) else {
                why = "裁不出 112×112（脸框 \(Int(box.width))x\(Int(box.height)) px 出界或变换退化）"
                return false
            }
            why = ""
            vec = Ruler.shared.embed(crop)
            return true
        }
        if vec == nil && why.isEmpty { why = Ruler.shared.lastError }
        return (vec, shortSide, why, "\(src)｜\(origin)")
    }

    /// 整片扫描：每帧检测一次，只有脸短边（折算回源像素）达标的才裁脸跑尺子。
    static func scan(url: URL, anchor: [Float], cosTh: Double, sideTh: Double, step: Int,
                     stop: StopFlag, progress: @escaping (String) -> Void) -> ScanOutcome {
        var o = ScanOutcome()
        let asset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { sem.signal() }
        sem.wait()
        guard let track = asset.tracks(withMediaType: .video).first else {
            o.text = "没有视频轨"
            return o
        }
        let natural = track.naturalSize
        let fps = Double(max(track.nominalFrameRate, 1))
        let duration = CMTimeGetSeconds(asset.duration)
        let totalFrames = max(1, Int((duration * fps).rounded()))
        let longNatural = max(Int(natural.width), Int(natural.height))

        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        var decodedLong = max(longNatural, 2)
        if longNatural > 1920 {
            let s = Runner.fitSize(longNatural, min(Int(natural.width), Int(natural.height)), longEdge: 1920)
            settings[kCVPixelBufferWidthKey as String] = s.w
            settings[kCVPixelBufferHeightKey as String] = s.h
            decodedLong = max(s.w, s.h)
        }
        let sideScale = Double(longNatural) / Double(max(decodedLong, 2))

        guard let reader = try? AVAssetReader(asset: asset) else { o.text = "AVAssetReader 建不起来"; return o }
        guard let output = try? AVAssetReaderTrackOutput(track: track, outputSettings: settings) else {
            o.text = "TrackOutput 建不起来"
            return o
        }
        reader.add(output)
        guard reader.startReading() else {
            o.text = "startReading 失败: \(reader.error?.localizedDescription ?? "-")"
            return o
        }
        guard Ruler.shared.load() else {
            o.text = "尺子起不来：\(Ruler.shared.note)"
            reader.cancelReading()
            return o
        }

        let request = VNDetectFaceLandmarksRequest()
        let nSamples = (totalFrames + step - 1) / step
        o.keep = Array(repeating: false, count: nSamples)
        var frameIndex = 0
        var sample = 0
        var detectSum = 0.0, embedSum = 0.0, embedRuns = 0, cropFails = 0
        var pointSrc = "—"
        // 朝向自动定：rot<0 表示还在试。直出来的像素可能是正的、躺着的、倒着的，
        // 我不在这信 preferredTransform（容器里读到过不靠谱的），而是拿这片子自己的前
        // probeN 张过脸量出来——4 个朝向的中位数全部印进报告，所以就算朝向不是病因，
        // 这张表自己会把我的理论否掉。
        let probeN = 8
        var rot = -1
        var probeCols: [[Double]] = Array(repeating: [], count: 4)
        var probeRows: [(sample: Int, sims: [Double])] = []
        func lockRotation() {
            var bestK = 0, bestMed = -99.0
            for k in 0..<4 {
                guard !probeCols[k].isEmpty, let m = CutEngine.median(probeCols[k]), m > bestMed else { continue }
                bestMed = m; bestK = k
            }
            rot = bestK
            for row in probeRows where row.sims[bestK] >= cosTh && row.sample < o.keep.count {
                o.keep[row.sample] = true
            }
            Journal.line("扫描 朝向定 k=\(bestK) 中位=\(String(format: "%.3f", bestMed)) 试探 \(probeRows.count) 张")
        }
        let mem0 = Facts.footprintMB()
        o.memMax = mem0
        var stopNote = ""
        let wall0 = DispatchTime.now().uptimeNanoseconds

        outer: while sample < nSamples {
            var ended = ""
            autoreleasepool {
                guard let sb = output.copyNextSampleBuffer() else { ended = "片源到末尾"; return }
                defer { CMSampleBufferInvalidate(sb) }
                guard let buffer = CMSampleBufferGetImageBuffer(sb) else { ended = "sample 里没有像素缓冲"; return }
                let taken = frameIndex % step == 0
                let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
                let d0 = DispatchTime.now().uptimeNanoseconds
                let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
                var obs: [VNFaceObservation] = []
                do {
                    try handler.perform([request])
                    obs = request.results ?? []
                } catch {
                    ended = "第 \(frameIndex) 源帧 Vision 抛错: \(error)"
                }
                if !ended.isEmpty { return }
                if taken {
                    detectSum += Double(DispatchTime.now().uptimeNanoseconds - d0) / 1_000_000
                    o.samples += 1
                    if !obs.isEmpty { o.framesWithFace += 1 }
                    _ = withPixels(buffer) { base, bpr -> Bool in
                        var best = -9.0
                        for f in obs {
                            let pw = Double(f.boundingBox.width) * Double(w) * sideScale
                            let ph = Double(f.boundingBox.height) * Double(h) * sideScale
                            if min(pw, ph) < sideTh { continue }
                            o.gated += 1
                            let ks = rot < 0 ? [0, 1, 2, 3] : [rot]
                            var sims = [-9.0, -9.0, -9.0, -9.0]
                            for k in ks {
                                let (kp, src) = Align.sendPoints(face: f, k: k, w: w, h: h)
                                pointSrc = src
                                guard let crop = Align.cropBGRA(base, bytesPerRow: bpr, w: w, h: h,
                                                                keypoints: kp) else { cropFails += 1; continue }
                                let e0 = DispatchTime.now().uptimeNanoseconds
                                guard let v = Ruler.shared.embed(crop) else { continue }
                                embedSum += Double(DispatchTime.now().uptimeNanoseconds - e0) / 1_000_000
                                embedRuns += 1
                                sims[k] = cosine(anchor, v)
                            }
                            if rot < 0 {
                                probeRows.append((sample: sample, sims: sims))
                                for k in 0..<4 where sims[k] > -8 { probeCols[k].append(sims[k]) }
                                if let m = sims.max(), m > best { best = m }
                                if probeRows.count >= probeN { lockRotation() }
                            } else {
                                let c = sims[rot]
                                if c > best { best = c }
                                if c >= cosTh && sample < o.keep.count { o.keep[sample] = true }
                            }
                        }
                        if best > -8 { o.bigSims.append(best) }
                        return true
                    }
                    sample += 1
                    let now = Facts.footprintMB()
                    if now > o.memMax { o.memMax = now }
                    if stop.on { ended = "你按了停止" }
                    else if PressureWatch.sawPressure { ended = "系统已喊内存压力，足迹 \(now) MB" }
                    else if now > Runner.footprintStopMB { ended = "足迹 \(now) MB 超收兵线 \(Runner.footprintStopMB) MB" }
                    if !ended.isEmpty { stopNote = ended; return }
                    if sample % 60 == 0 {
                        progress("扫到第 \(sample)/\(nSamples) 取样帧（源帧 \(frameIndex)）足迹 \(Facts.footprintMB()) MB")
                    }
                }
                frameIndex += 1
            }
            if !ended.isEmpty { break outer }
        }
        reader.cancelReading()
        if rot < 0 && !probeRows.isEmpty { lockRotation() }
        if sample < nSamples && stopNote.isEmpty { stopNote = endedNote(reader) }

        o.detectMs = o.samples > 0 ? detectSum / Double(o.samples) : 0
        o.embedMs = embedRuns > 0 ? embedSum / Double(embedRuns) : 0
        o.segments = segmentsFromKeep(o.keep)
        o.hits = o.keep.filter { $0 }.count

        var total = 0.0
        for s in o.segments { total += s.seconds(fps: fps, step: step).length }
        let wall = Double(DispatchTime.now().uptimeNanoseconds - wall0) / 1_000_000_000
        let pct = o.samples > 0 ? Double(o.hits) / Double(o.samples) * 100 : 0
        var line = "扫 \(o.samples) 取样帧（step=\(step)，源 \(totalFrames) 帧 / \(String(format: "%.1f", duration)) s，直出长边 \(decodedLong)→源折算 ×\(String(format: "%.2f", sideScale))）"
        line += "\n有脸的帧 \(o.framesWithFace)/\(o.samples)；≥\(String(format: "%.0f", sideTh)) px 的脸 \(o.gated) 张；裁脸失败 \(cropFails) 张"
        if rot >= 0 {
            let meds = (0..<4).map { k -> String in
                guard let m = CutEngine.median(probeCols[k]) else { return "转\(k * 90)° —" }
                return "转\(k * 90)° \(String(format: "%.3f", m))"
            }
            line += "\n朝向试探（\(probeRows.count) 张脸各裁 4 个朝向跑尺子）：" + meds.joined(separator: "｜")
            line += "\n  → 用 **转\(rot * 90)°**；点位 \(pointSrc)"
        }
        line += "\n**命中 \(o.hits)/\(o.samples) 帧（\(String(format: "%.0f", pct))%）→ \(o.segments.count) 段，合计 \(String(format: "%.1f", total)) s**"
        if let med = median(o.bigSims), let mx = o.bigSims.max() {
            line += "\n  过闸脸对锚点的余弦 中位 \(String(format: "%.3f", med)) 最高 \(String(format: "%.3f", mx))（闸门 \(String(format: "%.2f", cosTh))）"
        } else {
            line += "\n  没有任何 ≥\(String(format: "%.0f", sideTh)) px 的脸可判——锚点这闸一张都没过"
        }
        line += "\n单价：检测 \(String(format: "%.1f", o.detectMs)) ms/帧 + 尺子 \(String(format: "%.1f", o.embedMs)) ms/次；本次实耗 \(String(format: "%.1f", wall)) s"
        if Ruler.shared.failures > 0 {
            line += "\n**尺子失败 \(Ruler.shared.failures) 次**，最后一次：\(Ruler.shared.lastError)\n  \(Ruler.shared.note)"
        }
        line += "\n足迹 \(mem0)→\(Facts.footprintMB()) MB，峰值 \(o.memMax) MB"
        if !stopNote.isEmpty { line += "\n半趟收兵：\(stopNote)（只扫到第 \(sample) 帧）" }
        o.text = line
        Journal.line("扫描 完 取样=\(o.samples) 命中=\(o.hits) 段=\(o.segments.count) 峰值足迹=\(o.memMax)MB \(stopNote)")
        return o
    }

    private static func endedNote(_ reader: AVAssetReader) -> String {
        if let e = reader.error { return "reader 报错: \(e.localizedDescription)" }
        return "样本取完"
    }

    private static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        return v.sorted()[v.count / 2]
    }
}

// MARK: - 导出（把所有命中段拼成一条）

enum CutExport {

    static func compose(url: URL, segments: [Segment], step: Int, preset: String) -> (URL?, String) {
        let source = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        source.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { sem.signal() }
        sem.wait()
        guard let srcVideo = source.tracks(withMediaType: .video).first else {
            return (nil, "没有视频轨可拼")
        }
        let comp = AVMutableComposition()
        guard let dstVideo = comp.addMutableTrack(withMediaType: .video,
                                                  preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return (nil, "建不出合成轨")
        }
        let srcAudio = source.tracks(withMediaType: .audio).first
        var dstAudio: AVMutableCompositionTrack?
        if srcAudio != nil {
            dstAudio = comp.addMutableTrack(withMediaType: .audio,
                                            preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        // 秒只从 Segment.seconds 这一处出：它才是"取样号→源秒"的唯一定义（号 × step / fps）。
        // 之前这里自己按号/fps 算了一遍，step=1 时恰好对，隔帧扫就会把段插到错位置。
        let fps = Double(max(srcVideo.nominalFrameRate, 1))
        func t(_ seconds: Double) -> CMTime {
            CMTime(value: CMTimeValue((seconds * 1000).rounded()), timescale: 1000)
        }
        var cursor = CMTime.zero
        var appended = 0
        var failed = ""
        for s in segments {
            let sec = s.seconds(fps: fps, step: step)
            let rng = CMTimeRange(start: t(sec.start), duration: t(sec.length))
            do {
                try dstVideo.insertTimeRange(rng, of: srcVideo, at: cursor)
                if let dstAudio = dstAudio, let srcAudio = srcAudio {
                    try? dstAudio.insertTimeRange(rng, of: srcAudio, at: cursor)
                }
                cursor = CMTimeAdd(cursor, t(sec.length))
                appended += 1
            } catch {
                failed = "第 \(appended + 1) 段（\(String(format: "%.1f", sec.start))~\(String(format: "%.1f", sec.end)) s）插入失败: \(error)"
                break
            }
        }
        if !failed.isEmpty { return (nil, failed) }
        guard appended > 0 else { return (nil, "一段都没插进去（没命中就别导）") }
        Journal.line("导出 拼 \(appended) 段 合成时长 \(String(format: "%.1f", CMTimeGetSeconds(comp.duration))) s")

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let out = dir.appendingPathComponent("cut_\(f.string(from: Date())).mov")
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: comp, presetName: preset) else {
            return (nil, "这个 preset 手机不支持: \(preset)")
        }
        session.outputURL = out
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = true
        let t0 = DispatchTime.now().uptimeNanoseconds
        let esem = DispatchSemaphore(value: 0)
        session.exportAsynchronously { esem.signal() }
        esem.wait()
        let cost = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000
        guard session.status == .completed else {
            return (nil, "导出失败 status=\(session.status.rawValue): \(session.error?.localizedDescription ?? "-")")
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path)[.size]) as? Int) ?? 0
        return (out, "拼 \(appended) 段 → \(out.lastPathComponent)｜成片 \(String(format: "%.1f", CMTimeGetSeconds(comp.duration))) s，\(String(format: "%.1f", Double(size) / 1048576)) MB，导出耗时 \(String(format: "%.1f", cost)) s")
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
}

// MARK: - 界面

final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerShell: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}

@MainActor
final class Cutter: ObservableObject {

    @Published var videoURL: URL?
    @Published var player = AVPlayer()
    @Published var status = ""
    @Published var busy = false
    @Published var seconds = 0.0
    @Published var duration = 0.0
    @Published var fps = 30.0
    @Published var natural = CGSize.zero
    @Published var faces: [VNFaceObservation] = []
    @Published var anchor: [Float]?
    @Published var anchorNote = ""
    @Published var report = ""
    @Published var segments: [Segment] = []
    @Published var exportNote = ""
    @Published var showPicker = false
    @Published var step = 1
    @Published var sideTh = 96.0
    /// 已选为锚点的是这一帧里的第几张脸（-1＝还没选）；绿框会把它描成橙色，让"选上了"这件事看得见
    @Published var chosen = -1

    var asset: AVURLAsset?
    let stop = StopFlag()
    /// 上一次扫描用的取样步进：导出必须照它切，不能用现在 Picker 上的值（扫完人可能顺手改了步进）
    var scannedStep = 1

    /// 选完那一刻就收 cover：拷文件还在后台跑，主界面显示进度比停在相册里强
    func pickStarted() {
        showPicker = false
        if videoURL == nil { status = "取文件中…" } else { status = "换片中…" }
    }

    func picked(url: URL?, failMessage: String?) {
        showPicker = false          // 必须自己收场：cover 不会因 PHPicker 选完而消失，不关就整屏卡在选择页
        guard let url = url else {
            status = failMessage ?? "没选到视频"
            return
        }
        videoURL = url
        anchor = nil
        anchorNote = ""
        report = ""
        segments = []
        faces = []
        exportNote = ""
        status = ""
        let a = AVURLAsset(url: url)
        asset = a
        busy = true
        status = "读片头…"
        Task.detached { [weak self] in
            let s = DispatchSemaphore(value: 0)
            a.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { s.signal() }
            s.wait()
            var text = "这条没有视频轨"
            var f = 30.0, d = 0.0, shown = CGSize(width: 9, height: 16)
            if let t = a.tracks(withMediaType: .video).first {
                let nat = t.naturalSize
                let r = t.preferredTransform
                let rotated = abs(r.b) > 0.1 || abs(r.c) > 0.1
                shown = rotated ? CGSize(width: nat.height, height: nat.width) : nat
                f = Double(max(t.nominalFrameRate, 1))
                d = CMTimeGetSeconds(a.duration)
                text = "显示 \(Int(shown.width))x\(Int(shown.height))｜\(String(format: "%.1f", d)) s @ \(String(format: "%.1f", f)) fps｜源 \(Int(nat.width))x\(Int(nat.height)) 旋转\(rotated ? "有" : "无")"
            }
            Task { @MainActor in
                guard let self = self else { return }
                self.fps = f
                self.duration = d
                self.seconds = 0
                self.natural = shown
                self.player.replaceCurrentItem(with: AVPlayerItem(asset: a))
                self.busy = false
                self.status = text
                Journal.line("剪辑 选片 \(url.lastPathComponent) \(text) 足迹\(Facts.footprintMB())MB")
            }
        }
    }

    func stepFrame(_ dir: Int) {
        guard asset != nil else { return }
        let one = 1.0 / max(fps, 1)
        seconds = max(0, min(max(duration - one * 0.5, 0.1), seconds + Double(dir) * one))
        seek()
    }

    func seek() {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func detect() {
        guard let a = asset else { status = "还没选视频"; return }
        busy = true
        status = "取这一帧…"
        faces = []
        chosen = -1
        anchor = nil
        anchorNote = ""
        let at = seconds
        Task.detached { [weak self] in
            let (img, note) = CutEngine.frameImage(asset: a, at: at)
            let obs = img == nil ? [] : CutEngine.faces(in: img!)
            // 这一帧摆正 ⇒ 先在第 1 张脸上把 y 原点判了：黄点是给人眼验收用的，画反了就没得验
            let origin = obs.first.map { Align.settleOrigin(face: $0) } ?? "y 原点没判（没检到脸）"
            Task { @MainActor in
                guard let self = self else { return }
                self.busy = false
                self.faces = obs
                self.anchorNote = ""
                self.status = "\(note)｜检到 \(obs.count) 张脸——点一个绿框当要保留的人\n\(origin)"
                Journal.line("剪辑 静帧 \(note) 脸 \(obs.count)")
            }
        }
    }

    /// 第 i 张检出的脸在源片里的短边 px（Vision 的框是归一化的，要乘回显示尺寸）
    func faceLabel(_ i: Int) -> String {
        guard i < faces.count else { return "第 \(i + 1) 张" }
        let r = faces[i].boundingBox
        let px = min(r.width * natural.width, r.height * natural.height)
        return "第 \(i + 1) 张 \(Int(px)) px"
    }

    func choose(_ index: Int) {
        guard index < faces.count, let a = asset else { return }
        busy = true
        status = "裁这一张脸…"
        let face = faces[index]
        let at = seconds
        let th = sideTh
        Task.detached { [weak self] in
            let (img, _) = CutEngine.frameImage(asset: a, at: at)
            var text = "取不到这一帧"
            var vec: [Float]? = nil
            if let img = img {
                // frameImage 是直出全分辨率（不像扫描那趟会被压到 1920），所以换算系数是 1
                let (v, side, why, src) = CutEngine.anchorFrom(image: img, face: face, sideScale: 1)
                vec = v
                text = v == nil ? "这张脸算不出向量：\(why)"
                    : "锚点存下（这张脸源片短边 \(String(format: "%.0f", side)) px，点位 \(src)）｜\(vecFingerprint(v!))"
                if v != nil && src.hasPrefix("框猜") {
                    text += "\n⚠️ 这张脸没给到五官点，退回按框猜——同一个人也会掉分，扫出来的命中率会偏低。"
                }
                if v != nil && side < th {
                    text += "\n⚠️ 这张脸比下限 \(String(format: "%.0f", th)) px 还小：拿它当锚点，整片很可能一帧都判不过（＝输出 0 段）。停到脸大一点的帧再点。"
                }
            }
            Task { @MainActor in
                guard let self = self else { return }
                self.busy = false
                self.anchor = vec
                self.chosen = vec == nil ? -1 : index
                self.anchorNote = text
                self.status = text + (vec == nil ? "" : "｜可以「整片扫描」了")
                Journal.line("剪辑 锚点 \(text)")
            }
        }
    }

    func scan() {
        guard let url = videoURL, let anchor = anchor else {
            status = "先点一个框当锚点"
            return
        }
        busy = true
        stop.on = false
        report = ""
        segments = []
        exportNote = ""
        PressureWatch.reset()
        let st = step, scth = sideTh
        scannedStep = st
        status = "整片扫描中…（step=\(st)）"
        Journal.line("剪辑 扫描 开始 \(url.lastPathComponent) step=\(st) 闸0.30/\(scth) 足迹\(Facts.footprintMB())MB")
        let flag = stop
        Task.detached { [weak self] in
            let o = CutEngine.scan(url: url, anchor: anchor, cosTh: 0.30, sideTh: scth,
                                   step: st, stop: flag) { line in
                Task { @MainActor in self?.status = line }
            }
            Ruler.shared.release()
            Task { @MainActor in
                guard let self = self else { return }
                self.busy = false
                self.report = o.text
                self.segments = o.segments
                self.status = "扫完：\(o.hits)/\(o.samples) 帧命中，\(o.segments.count) 段"
            }
        }
    }

    func stopScan() {
        stop.on = true
        status = "已请求停止（跑完这一帧就收）"
    }

    func export() {
        guard let url = videoURL, !segments.isEmpty else {
            exportNote = "没有段可导（先扫，命中 ≥1 段）"
            return
        }
        busy = true
        exportNote = "拼接导出中…"
        let segs = segments
        let st = scannedStep
        Task.detached { [weak self] in
            let (file, text) = CutExport.compose(url: url, segments: segs, step: st,
                                                 preset: AVAssetExportPresetHighestQuality)
            let photo = file == nil ? "" : CutExport.toPhotos(file!)
            Task { @MainActor in
                guard let self = self else { return }
                self.busy = false
                self.exportNote = text + "\n" + photo
                Journal.line("剪辑 导出 \(text)｜\(photo)")
            }
        }
    }

    func sendReport() {
        var text = "—— 剪辑 ——\n\(videoURL?.lastPathComponent ?? "没选视频")\n\(status)\n"
        text += "锚点：\(anchorNote)（有向量=\(anchor != nil)）\n"
        text += report.isEmpty ? "还没扫\n" : report + "\n"
        if !exportNote.isEmpty { text += "导出：\(exportNote)\n" }
        text += "尺子：\(Ruler.shared.note)\n\n—— 自检 ——\n"
        text += Facts.lines().joined(separator: "\n")
        text += "\n\n—— 磁盘日志尾 ——\n" + Journal.tail(150)
        busy = true
        status = "发到电脑中…"
        let to = Uploader.endpoint
        Task.detached { [weak self] in
            let r = Uploader.send(text)
            Task { @MainActor in
                self?.busy = false
                let needAddr = r.hasPrefix("发到电脑：") && !r.contains("HTTP")
                self?.status = needAddr ? "\(r)｜地址 \(to)" : r
            }
        }
    }
}

struct CutView: View {
    @ObservedObject var cut: Cutter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button("选视频") { cut.showPicker = true }
                    Button("整片扫描") { cut.scan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(cut.busy || cut.anchor == nil)
                    if cut.busy { Button("停止") { cut.stopScan() } }
                    Button("发到电脑") { cut.sendReport() }
                }
                .font(.footnote)

                Text(cut.status.isEmpty ? "先「选视频」" : cut.status)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if cut.videoURL != nil {
                    GeometryReader { geo in
                        ZStack {
                            PlayerShell(player: cut.player)
                            faceBoxes(in: geo.size)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { p in tap(p, in: geo.size) }
                    }
                    .frame(height: 280)
                    .background(Color.black)

                    Slider(value: $cut.seconds, in: 0...max(cut.duration, 0.1)) { editing in
                        if !editing { cut.seek() }
                    }
                    HStack(spacing: 8) {
                        Button("◀一帧") { cut.stepFrame(-1) }
                        Button("一帧▶") { cut.stepFrame(1) }
                        Button("停帧检脸") { cut.detect() }
                            .buttonStyle(.borderedProminent)
                        Text(String(format: "%.2f/%.1fs", cut.seconds, cut.duration))
                            .font(.footnote)
                    }
                    .font(.footnote)
                    if !cut.faces.isEmpty {
                        Text("点绿框或点下面按钮都行——选中的就是「要保留的人」")
                            .font(.footnote)
                        HStack(spacing: 6) {
                            ForEach(Array(cut.faces.enumerated()), id: \.offset) { i, _ in
                                Button(cut.chosen == i ? "✓ " + cut.faceLabel(i) : cut.faceLabel(i)) { cut.choose(i) }
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.footnote)
                    }
                    if !cut.anchorNote.isEmpty {
                        Text(cut.anchorNote)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Picker("取样步进", selection: $cut.step) {
                        Text("每帧").tag(1)
                        Text("隔 1 帧").tag(2)
                        Text("隔 2 帧").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .font(.footnote)
                    Stepper(value: $cut.sideTh, in: 64...256, step: 16) {
                        Text("脸短边下限 \(Int(cut.sideTh)) px（按源片尺寸）")
                            .font(.footnote)
                    }
                }

                if !cut.report.isEmpty {
                    Text(cut.report)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("段表（导出按这个拼）").font(.footnote)
                        ForEach(Array(cut.segments.enumerated()), id: \.offset) { _, s in
                            let t = s.seconds(fps: cut.fps, step: cut.scannedStep)
                            Text(String(format: "  %.2f - %.2f s（%.2f s）", t.start, t.end, t.length))
                                .font(.system(size: 10, design: .monospaced))
                        }
                    }
                    Button("导出成片（拼成一条＋存相册）") { cut.export() }
                        .buttonStyle(.borderedProminent)
                        .disabled(cut.busy || cut.segments.isEmpty)
                    if !cut.exportNote.isEmpty {
                        Text(cut.exportNote)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
        .fullScreenCover(isPresented: $cut.showPicker) {
            PickerHost(target: .video, onPicked: { cut.pickStarted() }) { url, msg in
                cut.picked(url: url, failMessage: msg)
            }
        }
    }

    func contentRect(in size: CGSize) -> CGRect {
        let vw = cut.natural.width > 0 ? cut.natural.width : 9
        let vh = cut.natural.height > 0 ? cut.natural.height : 16
        let s = min(size.width / vw, size.height / vh)
        let w = vw * s, h = vh * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    func faceBoxes(in size: CGSize) -> some View {
        let box = contentRect(in: size)
        return AnyView(ForEach(Array(cut.faces.enumerated()), id: \.offset) { _, f in
            let r = f.boundingBox
            // 用 Group 不用 ZStack：ZStack 自己有尺寸，成员全靠 .position 摆时会塌成一点
            Group {
                Rectangle()
                    .stroke(Color.green, lineWidth: 2)
                    .frame(width: r.width * box.width, height: r.height * box.height)
                    .position(x: box.minX + (r.minX + r.width / 2) * box.width,
                              y: box.minY + (1 - (r.minY + r.height / 2)) * box.height)
                // 5 个黄点 = 真五官点落位了；一个都没有 = 这张脸退回了按框猜
                ForEach(Array((Align.markerPoints(f) ?? []).enumerated()), id: \.offset) { _, p in
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 4, height: 4)
                        .position(x: box.minX + p.x * box.width,
                                  y: box.minY + p.y * box.height)
                }
            }
        })
    }

    func tap(_ p: CGPoint, in size: CGSize) {
        guard !cut.faces.isEmpty, !cut.busy else { return }
        let box = contentRect(in: size)
        for (i, f) in cut.faces.enumerated() {
            let r = f.boundingBox
            let x = box.minX + r.minX * box.width
            let y = box.minY + (1 - (r.minY + r.height)) * box.height
            if p.x >= x && p.x <= x + r.width * box.width
                && p.y >= y && p.y <= y + r.height * box.height {
                cut.choose(i)
                return
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var bench = Bench()
    @StateObject private var cut = Cutter()
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("剪辑").tag(0)
                Text("自检/基准").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 6)

            if tab == 0 {
                CutView(cut: cut)
            } else {
                BenchView(bench: bench)
            }
        }
    }
}
