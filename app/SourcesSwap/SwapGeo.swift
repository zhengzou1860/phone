import Foundation
import CoreGraphics

/// 对齐 / 回贴的数学，逐式对照 PC 那份跑通的实现：
///   官方 align_face.align_with_five_points（5 点 → 6 参数最小二乘仿射，不是相似变换）
///   官方 dealign + tools/mfs_dealign.py 的"只贴脸框"版（PC 上 217 帧对拍过：与整幅版差 ≤2 灰阶、17 个像素）
/// 换脸的几何全靠这 5 个点，所以这里必须和 PC 同式，不能自己换个"更简单"的解。
enum SwapGeo {
    static let size = 224

    /// arcface 标准 5 点模板（112 空间）＋ x 方向 +8 再放大 size/112 —— 官方 REFERENCE_FACIAL_POINTS 的算法
    static func template224() -> [CGPoint] {
        let base: [(Double, Double)] = [(30.29459953, 51.69630051), (65.53179932, 51.50139999),
                                         (48.02519989, 71.73660278), (33.54930115, 92.3655014),
                                         (62.72990036, 92.20410156)]
        let s = Double(size) / 112.0
        return base.map { CGPoint(x: ($0.0 + 8.0) * s, y: $0.1 * s) }
    }

    /// 2×3 仿射：dst = [a b c; d e f] · (x, y, 1)
    struct Affine { var a, b, c, d, e, f: Double }

    /// 6 参数最小二乘（官方 np.linalg.lstsq 的正规方程版）：
    /// x' 与 y' 各解一个三元一次，设计矩阵同一份 [x y 1]。5 点 10 方程 6 未知，rank 必为 3。
    static func fitAffine(src: [CGPoint], dst: [CGPoint]) -> Affine? {
        guard src.count == dst.count, src.count >= 3 else { return nil }
        let n = src.count
        // XtX 是 3×3，Xt·dst_x 与 Xt·dst_y 两个右端项
        var s00 = 0.0, s01 = 0.0, s02 = 0.0, s11 = 0.0, s12 = 0.0, s22 = 0.0
        var bx = 0.0, by = 0.0, b1 = 0.0
        for i in 0..<n {
            let x = Double(src[i].x), y = Double(src[i].y)
            s00 += x * x; s01 += x * y; s02 += x
            s11 += y * y; s12 += y
            s22 += 1
            bx += x * Double(dst[i].x)
            by += y * Double(dst[i].x)
            b1 += Double(dst[i].x)
        }
        let m00 = s00, m01 = s01, m02 = s02
        let m10 = s01, m11 = s11, m12 = s12
        let m20 = s02, m21 = s12, m22 = s22
        var cx = 0.0, cy = 0.0, c1 = 0.0
        for i in 0..<n {
            let x = Double(src[i].x), y = Double(src[i].y)
            cx += x * Double(dst[i].y)
            cy += y * Double(dst[i].y)
            c1 += Double(dst[i].y)
        }
        guard let r1 = solve3(m00, m01, m02, m10, m11, m12, m20, m21, m22, bx, by, b1),
              let r2 = solve3(m00, m01, m02, m10, m11, m12, m20, m21, m22, cx, cy, c1)
        else { return nil }
        // r1 = dst_x 的三个系数 (α,β,γ)，r2 = dst_y 的三个系数 ⇒ tfm = [αx βx γx; αy βy γy]
        return Affine(a: r1[0], b: r1[1], c: r1[2], d: r2[0], e: r2[1], f: r2[2])
    }

    private static func solve3(_ m00: Double, _ m01: Double, _ m02: Double,
                               _ m10: Double, _ m11: Double, _ m12: Double,
                               _ m20: Double, _ m21: Double, _ m22: Double,
                               _ b0: Double, _ b1: Double, _ b2: Double) -> [Double]? {
        let det = m00 * (m11 * m22 - m12 * m21) - m01 * (m10 * m22 - m12 * m20) + m02 * (m10 * m21 - m11 * m20)
        guard abs(det) > 1e-12 else { return nil }
        // Cramer：第 j 列换成 b 后的行列式 / det
        let d0 = b0 * (m11 * m22 - m12 * m21) - m01 * (b1 * m22 - m12 * b2) + m02 * (b1 * m21 - m11 * b2)
        let d1 = m00 * (b1 * m22 - m12 * b2) - b0 * (m10 * m22 - m12 * m20) + m02 * (m10 * b2 - b1 * m20)
        let d2 = m00 * (m11 * b2 - b1 * m21) - m01 * (m10 * b2 - b1 * m20) + b0 * (m10 * m21 - m11 * m20)
        return [d0 / det, d1 / det, d2 / det]
    }

    /// 3×3 齐次求逆后取前两行 = 官方 back_matrix（np.linalg.pinv，非奇异时同 inv）
    /// M = [a b c; d e f; 0 0 1]，det = a·e - b·d
    static func inverse(_ m: Affine) -> Affine? {
        let det = m.a * m.e - m.b * m.d
        guard abs(det) > 1e-12 else { return nil }
        return Affine(a: m.e / det, b: -m.b / det, c: (m.b * m.f - m.e * m.c) / det,
                      d: -m.d / det, e: m.a / det, f: (m.d * m.c - m.a * m.f) / det)
    }

    // MARK: - 正向：整幅 BGRA → size×size 的 planar RGB [0,1]

    /// cv2.warpAffine(img, M, (size,size), INTER_LINEAR)：它的取样是 dst(x,y)=src(M⁻¹·(x,y))，
    /// 所以这里收的是"整幅→模板"的正向 M，取样前自己求逆。越界补 0（cv2 的 borderValue 就是 0）。
    static func warpToCrop(_ base: UnsafeRawPointer, bytesPerRow: Int, w: Int, h: Int,
                           fwd: Affine, side: Int, out: inout [Float]) {
        guard let inv = inverse(fwd) else { return }
        let plane = side * side
        for i in 0..<(3 * plane) { out[i] = 0 }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let rowPix = bytesPerRow / 4
        for oy in 0..<side {
            for ox in 0..<side {
                let u = Double(ox), v = Double(oy)
                let fx = inv.a * u + inv.b * v + inv.c
                let fy = inv.d * u + inv.e * v + inv.f
                let r = bilinear255(p, rowPix, w, h, fx, fy)
                let k = oy * side + ox
                out[k] = r.0
                out[plane + k] = r.1
                out[2 * plane + k] = r.2
            }
        }
    }

    /// 双线性取样，返回 0~1 的 R G B（BGRA 内存序里倒着读）。越界返回 0 —— 与 cv2 borderValue=0 同口径。
    private static func bilinear255(_ p: UnsafePointer<UInt8>, _ rowPix: Int, _ w: Int, _ h: Int,
                                    _ fx: Double, _ fy: Double) -> (Float, Float, Float) {
        guard fx >= 0, fy >= 0, fx <= Double(w - 1), fy <= Double(h - 1) else { return (0, 0, 0) }
        let x0 = Int(fx), y0 = Int(fy)
        let dx = Float(fx - Double(x0)), dy = Float(fy - Double(y0))
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        func ch(_ c: Int, _ xx: Int, _ yy: Int) -> Float { Float(p[yy * rowPix * 4 + xx * 4 + c]) }
        var res: [Float] = []
        for c in [2, 1, 0] {
            let v = (ch(c, x0, y0) + (ch(c, x1, y0) - ch(c, x0, y0)) * dx)
                + ((ch(c, x0, y1) + (ch(c, x1, y1) - ch(c, x0, y1)) * dx)
                   - (ch(c, x0, y0) + (ch(c, x1, y0) - ch(c, x0, y0)) * dx)) * dy
            res.append(v / 255.0)
        }
        return (res[0], res[1], res[2])
    }

    /// 224 → 112 的双线性缩小：PC 是 cv2.resize(aligned224,(112,112))，默认 INTER_LINEAR，同式
    static func resizePlanar(_ src: [Float], from: Int, to: Int, into dst: inout [Float]) {
        let sp = from * from, dp = to * to
        let sx = Double(from) / Double(to), sy = Double(from) / Double(to)
        for plane in 0..<3 {
            for oy in 0..<to {
                let fy = (Double(oy) + 0.5) * sy - 0.5
                let y0 = max(0, min(from - 1, Int(floor(fy))))
                let y1 = max(0, min(from - 1, y0 + 1))
                let wy = Float(max(0, min(1, fy - Double(y0))))
                for ox in 0..<to {
                    let fx = (Double(ox) + 0.5) * sx - 0.5
                    let x0 = max(0, min(from - 1, Int(floor(fx))))
                    let x1 = max(0, min(from - 1, x0 + 1))
                    let wx = Float(max(0, min(1, fx - Double(x0))))
                    let a = src[plane * sp + y0 * from + x0]
                    let b = src[plane * sp + y0 * from + x1]
                    let c = src[plane * sp + y1 * from + x0]
                    let d = src[plane * sp + y1 * from + x1]
                    dst[plane * dp + oy * to + ox] = (a + (b - a) * wx) + ((c + (d - c) * wx) - (a + (b - a) * wx)) * wy
                }
            }
        }
    }

    // MARK: - 反向：size×size 的结果 + mask 贴回整幅（只在脸的外接框里做）

    /// 官方 preprocess_mask：>0.001 归 1 → 11×11 膨胀 → 11×11 腐蚀×2 → 7×7 模糊 → 乘 10 px 内收衰减
    static func preprocessMask(_ inMask: [Float], _ m2: inout [Float]) {
        let s = size
        var m = inMask
        for i in 0..<m.count { m[i] = m[i] > 0.001 ? 1.0 : m[i] }
        m = boxMax(m, s, 11)
        m = boxMin(m, s, 11); m = boxMin(m, s, 11)   // iterations=2
        m = boxBlur(m, s, 7)
        var m1 = [Float](repeating: 0, count: s * s)
        for y in 10..<(s - 10) { for x in 10..<(s - 10) { m1[y * s + x] = 1.0 } }
        m1 = boxBlur(m1, s, 11)
        for i in 0..<m.count { m2[i] = m[i] * m1[i] }
    }

    /// 矩形核膨胀：可分离（先行后列）；越界按 OpenCV 形态学默认边界＝不参与（比 -inf/ +inf 弱）
    private static func boxMax(_ a: [Float], _ s: Int, _ k: Int) -> [Float] {
        let r = k / 2
        var t = [Float](repeating: 0, count: a.count)
        for y in 0..<s {
            for x in 0..<s {
                var v = a[y * s + x]
                let x0 = max(0, x - r), x1 = min(s - 1, x + r)
                for xx in x0...x1 { v = max(v, a[y * s + xx]) }
                t[y * s + x] = v
            }
        }
        var o = t
        for x in 0..<s {
            for y in 0..<s {
                var v = t[y * s + x]
                let y0 = max(0, y - r), y1 = min(s - 1, y + r)
                for yy in y0...y1 { v = max(v, t[yy * s + x]) }
                o[y * s + x] = v
            }
        }
        return o
    }

    private static func boxMin(_ a: [Float], _ s: Int, _ k: Int) -> [Float] {
        let r = k / 2
        var t = [Float](repeating: 0, count: a.count)
        for y in 0..<s {
            for x in 0..<s {
                var v = a[y * s + x]
                let x0 = max(0, x - r), x1 = min(s - 1, x + r)
                for xx in x0...x1 { v = min(v, a[y * s + xx]) }
                t[y * s + x] = v
            }
        }
        var o = t
        for x in 0..<s {
            for y in 0..<s {
                var v = t[y * s + x]
                let y0 = max(0, y - r), y1 = min(s - 1, y + r)
                for yy in y0...y1 { v = min(v, t[yy * s + x]) }
                o[y * s + x] = v
            }
        }
        return o
    }

    /// cv2.blur(k×k) ＝ 均值滤波，边界 BORDER_REFLECT_101（不复制边缘、不补 0）
    private static func boxBlur(_ a: [Float], _ s: Int, _ k: Int) -> [Float] {
        let r = k / 2
        func refl(_ i: Int, _ n: Int) -> Int {
            if i >= 0 && i < n { return i }
            if i < 0 { return -i }              // REFLECT_101: -1 → 1
            if i >= n { return 2 * n - 2 - i }
            return i
        }
        var t = [Float](repeating: 0, count: a.count)
        let inv = 1.0 / Float(k)
        for y in 0..<s {
            for x in 0..<s {
                var v: Float = 0
                for d in (-r)...r { v += a[y * s + refl(x + d, s)] }
                t[y * s + x] = v * inv
            }
        }
        var o = [Float](repeating: 0, count: a.count)
        for x in 0..<s {
            for y in 0..<s {
                var v: Float = 0
                for d in (-r)...r { v += t[refl(y + d, s) * s + x] }
                o[y * s + x] = v * inv
            }
        }
        return o
    }

    /// 224 方块（含中心）按 back = M⁻¹（模板→整幅）映回原图后的外接矩形 ＝ mfs_dealign.py 的 face_roi
    static func faceRoi(back: Affine) -> (x0: Double, y0: Double, x1: Double, y1: Double) {
        let s = Double(size)
        let pts = [(0.0, 0.0), (s - 1, 0.0), (0.0, s - 1), (s - 1, s - 1), (s / 2, s / 2)]
        var xs: [Double] = [], ys: [Double] = []
        for (u, v) in pts {
            xs.append(back.a * u + back.b * v + back.c)
            ys.append(back.d * u + back.e * v + back.f)
        }
        return (xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0)
    }

    /// 官方 dealign 的框内版：整幅像素 (gx,gy) 用正向 M（整幅→模板）去 224 结果和 mask 里取样，
    /// 再按 mask 就地混进 BGRA。clip 到 0~255 同 cv2 存盘那一步。
    static func pasteBack(_ base: UnsafeMutableRawPointer, bytesPerRow: Int, w: Int, h: Int,
                          gen: [Float], mask: [Float], fwd: Affine, back: Affine,
                          padRatio: Double = 0.06) {
        let roi = faceRoi(back: back)
        let rw = roi.x1 - roi.x0, rh = roi.y1 - roi.y0
        let xi0 = max(0, Int(floor(roi.x0 - rw * padRatio)))
        let yi0 = max(0, Int(floor(roi.y0 - rh * padRatio)))
        let xi1 = min(w, Int(ceil(roi.x1 + rw * padRatio)))
        let yi1 = min(h, Int(ceil(roi.y1 + rh * padRatio)))
        if xi1 <= xi0 || yi1 <= yi0 { return }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let rowPix = bytesPerRow / 4
        let plane = size * size
        for gy in yi0..<yi1 {
            for gx in xi0..<xi1 {
                let u = Double(gx), v = Double(gy)
                let fx = fwd.a * u + fwd.b * v + fwd.c
                let fy = fwd.d * u + fwd.e * v + fwd.f
                guard fx >= 0, fy >= 0, fx <= Double(size - 1), fy <= Double(size - 1) else { continue }
                let mk = bilinearFloat(mask, size, size, fx, fy)
                if mk <= 0 { continue }
                let x0 = Int(fx), y0 = Int(fy)
                let dx = Float(fx - Double(x0)), dy = Float(fy - Double(y0))
                let x1 = min(x0 + 1, size - 1), y1 = min(y0 + 1, size - 1)
                let o = gy * rowPix * 4 + gx * 4
                for (ci, planeIdx) in [(2, 0), (1, 1), (0, 2)] {   // BGRA 内存序：B←planar R 反着写
                    let a00 = gen[planeIdx * plane + y0 * size + x0]
                    let a10 = gen[planeIdx * plane + y0 * size + x1]
                    let a01 = gen[planeIdx * plane + y1 * size + x0]
                    let a11 = gen[planeIdx * plane + y1 * size + x1]
                    let g = (a00 + (a10 - a00) * dx) + ((a01 + (a11 - a01) * dx) - (a00 + (a10 - a00) * dx)) * dy
                    let orig = Float(p[o + ci])
                    let v2 = g * 255.0 * mk + orig * (1 - mk)
                    p[o + ci] = UInt8(max(0, min(255, v2 + 0.5)))
                }
            }
        }
    }

    private static func bilinearFloat(_ a: [Float], _ w: Int, _ h: Int, _ fx: Double, _ fy: Double) -> Float {
        let x0 = min(max(0, Int(fx)), w - 1), y0 = min(max(0, Int(fy)), h - 1)
        let dx = Float(fx - Double(x0)), dy = Float(fy - Double(y0))
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let a00 = a[y0 * w + x0], a10 = a[y0 * w + x1], a01 = a[y1 * w + x0], a11 = a[y1 * w + x1]
        return (a00 + (a10 - a00) * dx) + ((a01 + (a11 - a01) * dx) - (a00 + (a10 - a00) * dx)) * dy
    }
}
