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
    /// 只这一处偏离官方：下边不再内收（下巴下半截就是被那一刀切掉的），左右和上边照旧。
    /// 下边缘的剖面不在这里乘，由 featherMask 折进 236 行那张再整张糊一次（伸出补丁那几行只有现算才有）。
    static func preprocessMask(_ inMask: [Float], _ m2: inout [Float]) {
        let s = size
        var m = inMask
        for i in 0..<m.count { m[i] = m[i] > 0.001 ? 1.0 : m[i] }
        m = boxMax(m, s, 11)
        m = boxMin(m, s, 11); m = boxMin(m, s, 11)   // iterations=2
        m = boxBlur(m, s, 7)
        var m1 = [Float](repeating: 0, count: s * s)
        for y in 10..<s { for x in 10..<(s - 10) { m1[y * s + x] = 1.0 } }
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
    private static func refl101(_ i: Int, _ n: Int) -> Int {
        if i >= 0 && i < n { return i }
        if i < 0 { return -i }              // REFLECT_101: -1 → 1
        return 2 * n - 2 - i
    }

    private static func boxBlur(_ a: [Float], _ s: Int, _ k: Int) -> [Float] {
        let r = k / 2
        var t = [Float](repeating: 0, count: a.count)
        let inv = 1.0 / Float(k)
        for y in 0..<s {
            for x in 0..<s {
                var v: Float = 0
                for d in (-r)...r { v += a[y * s + refl101(x + d, s)] }
                t[y * s + x] = v * inv
            }
        }
        var o = [Float](repeating: 0, count: a.count)
        for x in 0..<s {
            for y in 0..<s {
                var v: Float = 0
                for d in (-r)...r { v += t[refl101(y + d, s) * s + x] }
                o[y * s + x] = v * inv
            }
        }
        return o
    }

    /// 224 方块（含中心）按 back = M⁻¹（模板→整幅）映回原图后的外接矩形 ＝ mfs_dealign.py 的 face_roi
    /// yMax 可以超过 223：下巴剖面伸出补丁那几行也得落在框里，否则循环根本走不到那儿。
    static func faceRoi(back: Affine, yMax: Double) -> (x0: Double, y0: Double, x1: Double, y1: Double) {
        let s = Double(size)
        let pts = [(0.0, 0.0), (s - 1, 0.0), (0.0, yMax), (s - 1, yMax), (s / 2, s / 2)]
        var xs: [Double] = [], ys: [Double] = []
        for (u, v) in pts {
            xs.append(back.a * u + back.b * v + back.c)
            ys.append(back.d * u + back.e * v + back.f)
        }
        return (xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0)
    }

    // 下巴往下：补丁只有 0~223 行，而本机量下来下巴尖（检测框下沿）映到第 233 行（P10 230／P90 242）
    // ——巴尖压根不在补丁里，光挪遮罩内收量最多盖到 218 行。
    // 所以剖面伸出补丁 chinExt 行，伸出那几行接的是「这一帧对齐后的原片末行」（tail），不是补丁末行。
    // 试过镜像接（把倒数几行翻下来）：脖子上会多出一道弧形的下巴鬼影，比复制更难看，已弃。
    // 也试过拿补丁末行接（0.17 及以前）：那一行是网画的下颌暗面，平铺在脖子上＝一道横着的黑缝。
    // 本机 4 帧对拍（tools/ring_chin.py）：巴尖那道带暗弧 223→0 px，暗像素 4418→1322 px²，
    // ↔源 0.775、能量比 0.240 一个没动（那 12 行本来就不带身份信息）。
    static let chinRamp0 = 214.0                    // 这一行以上 alpha 照旧满
    static let chinExt = 12.0                       // 伸出补丁几行
    // 0.14 这里是 24 行（肉眼边界到 230 行），他装上后判「现在的都有点过了，可以收点了」⇒ 收成 12：
    // 边界回到 224 行，尾巴正好在巴尖（233）那一格收住。
    static var chinRamp1: Double { Double(size - 1) + chinExt }   // 到这一行掉到 0

    /// smoothstep 1→0：补丁边框那一行（223）上还有 0.61，内外连续，所以边框不露直线
    private static func chinProfile(_ fy: Double) -> Float {
        if fy <= chinRamp0 { return 1 }
        let t = (fy - chinRamp0) / (chinRamp1 - chinRamp0)
        if t >= 1 { return 0 }
        return Float(1 - t * t * (3 - 2 * t))
    }

    // MARK: - 遮罩在 224 这一层糊一次（他 10-13 点名的那一格：八臂里的 G「G更自然」）
    //
    // 本机八臂的数：遮罩边上的亮度台阶 7.81→6.02、轮廓粗糙 4.3→4.0 px、↔源 0.794→0.784、能量比 0.226→0.240。
    // 同一档羽化若在整幅那一层糊（B 臂），台阶只到 6.79 而本机合成段要 2.3 倍的钱 ⇒ 糊在 224 里，
    // 两条路的 alpha 逐像素差 均值 2.43／最大 26.59（0~255 刻度）。
    static let featherSigma = 4.0
    static var maskRows: Int { Int(chinRamp1) + 1 }        // 236 行＝补丁 224 行＋伸出那 12 行

    /// 224 那张遮罩 → 236×224 的成品 alpha：下巴剖面先折进来（伸出那几行拿末行接下去），
    /// 再整张高斯摊开一次。贴回时取样就直接落在这张上，不再按行现算剖面。
    /// out 的长度必须是 maskRows*size，调用方按帧复用这一格缓冲。
    static func featherMask(_ m2: [Float], _ out: inout [Float]) {
        let s = size
        var m = [Float](repeating: 0, count: maskRows * s)
        for y in 0..<maskRows {
            let sy = min(y, s - 1)
            let pf = chinProfile(Double(y))
            for x in 0..<s { m[y * s + x] = m2[sy * s + x] * pf }
        }
        out = gaussBlur(m, s, maskRows, featherSigma)
    }

    /// cv2 由 σ 现算核长：float 输入取 round(σ·4·2+1) 再凑奇数（σ=4 ⇒ 33 抽），归一化到和为 1
    private static func gaussKernel(_ sigma: Double) -> [Float] {
        var n = Int((sigma * 8.0 + 1.0).rounded())
        if n % 2 == 0 { n += 1 }
        let r = n / 2
        var w = [Double](repeating: 0, count: n)
        for i in 0..<n { let x = Double(i - r); w[i] = exp(-0.5 * (x / sigma) * (x / sigma)) }
        let sum = w.reduce(0, +)
        return w.map { Float($0 / sum) }
    }

    /// 可分离高斯，边界 BORDER_REFLECT_101；核对称 ⇒ 两半合成一次加法一次乘法
    private static func gaussBlur(_ a: [Float], _ w: Int, _ h: Int, _ sigma: Double) -> [Float] {
        let k = gaussKernel(sigma), r = k.count / 2
        var t = [Float](repeating: 0, count: a.count)
        for y in 0..<h {
            for x in 0..<w {
                var v = a[y * w + x] * k[r]
                for i in 1...r { v += (a[y * w + refl101(x - i, w)] + a[y * w + refl101(x + i, w)]) * k[r + i] }
                t[y * w + x] = v
            }
        }
        var o = [Float](repeating: 0, count: a.count)
        for x in 0..<w {
            for y in 0..<h {
                var v = t[y * w + x] * k[r]
                for i in 1...r { v += (t[refl101(y - i, h) * w + x] + t[refl101(y + i, h) * w + x]) * k[r + i] }
                o[y * w + x] = v
            }
        }
        return o
    }

    /// 官方 dealign 的框内版：整幅像素 (gx,gy) 用正向 M（整幅→模板）去 224 结果和 mask 里取样，
    /// 再按 mask 就地混进 BGRA。clip 到 0~255 同 cv2 存盘那一步。
    /// tail ＝ 这一帧对齐后原片的末行（planar，长 3*size）：补丁底下伸出去的那 chinExt 行由它接手。
    static func pasteBack(_ base: UnsafeMutableRawPointer, bytesPerRow: Int, w: Int, h: Int,
                          gen: [Float], tail: [Float], mask: [Float], fwd: Affine, back: Affine,
                          padRatio: Double = 0.06) {
        let roi = faceRoi(back: back, yMax: chinRamp1)
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
                guard fx >= 0, fy >= 0, fx <= Double(size - 1), fy <= chinRamp1 else { continue }
                // alpha 落在 featherMask 那张 236×224 上（剖面和羽化都在里面了），不再按行现算
                let mk = bilinearFloat(mask, size, mask.count / size, fx, fy)
                if mk <= 0 { continue }
                let x0 = Int(fx), y0 = Int(fy)
                let dx = Float(fx - Double(x0)), dy = Float(fy - Double(y0))
                let x1 = min(x0 + 1, size - 1), y1 = min(y0 + 1, maskRows - 1)
                let o = gy * rowPix * 4 + gx * 4
                for (ci, planeIdx) in [(2, 0), (1, 1), (0, 2)] {   // BGRA 内存序：B←planar R 反着写
                    let g = planeIdx * plane, t = planeIdx * size
                    // 补丁只到 223 行；224 往上（含 223↔224 那一格插值）落进 tail
                    let a00 = y0 < size ? gen[g + y0 * size + x0] : tail[t + x0]
                    let a10 = y0 < size ? gen[g + y0 * size + x1] : tail[t + x1]
                    let a01 = y1 < size ? gen[g + y1 * size + x0] : tail[t + x0]
                    let a11 = y1 < size ? gen[g + y1 * size + x1] : tail[t + x1]
                    let v0 = a00 + (a10 - a00) * dx
                    let v1 = a01 + (a11 - a01) * dx
                    let g2 = v0 + (v1 - v0) * dy
                    let orig = Float(p[o + ci])
                    let v2 = g2 * 255.0 * mk + orig * (1 - mk)
                    p[o + ci] = UInt8(max(0, min(255, v2 + 0.5)))
                }
            }
        }
    }

    /// 把这一帧对齐原片自己的高频（σ=0.8 高通＝毛孔/胡茬那一档颗粒）按 lam 倍搬回补丁。
    /// 为什么非做不可：他这条片脸 738 px，224 要撑 3.29×，「不进网只走 224 重采样」那格的高频能量比也只有
    /// 0.410（本机 6 帧，tools/quality_ab.py）＝这颗网的分辨率天花板，贴法／遮罩／羽化都翻不过去；
    /// 回填 λ=1.0 到 0.501（比那块天花板还高，因为它绕开了 224 那道采样）、λ=0.5 到 0.392（正好贴到天花板），
    /// 身份 ↔源 0.784→0.768／0.778，缝 L 2.33→2.22。σ 不能再宽：0.6 那版试过 σ=2，连着额头褶/法令纹一起搬＝他一眼判「完全没遮住」。
    /// 高斯核宽按 cv2 的口径由 σ 现算（2·round(3σ)+1），边界 BORDER_REFLECT_101，末尾 clip 0~1 同 cv2 存 8 位。
    static func restoreDetail(_ gen: inout [Float], _ att: [Float], lam: Float, sigma: Double = 0.8) {
        let s = size, plane = s * s
        let kr = Int((sigma * 3).rounded())
        let k = 2 * kr + 1
        var kw = [Float](repeating: 0, count: k)
        var sum: Float = 0
        for i in 0..<k {
            let x = Double(i - kr) / sigma
            kw[i] = Float(exp(-0.5 * x * x)); sum += kw[i]
        }
        for i in 0..<k { kw[i] /= sum }
        func refl(_ i: Int) -> Int { i < 0 ? -i : (i >= s ? 2 * s - 2 - i : i) }
        var tmp = [Float](repeating: 0, count: plane)
        var blr = [Float](repeating: 0, count: plane)
        for p in 0..<3 {
            let o = p * plane
            for y in 0..<s {
                for x in 0..<s {
                    var v: Float = 0
                    for i in 0..<k { v += kw[i] * att[o + refl(y - kr + i) * s + x] }
                    tmp[y * s + x] = v
                }
            }
            for y in 0..<s {
                for x in 0..<s {
                    var v: Float = 0
                    for i in 0..<k { v += kw[i] * tmp[y * s + refl(x - kr + i)] }
                    blr[y * s + x] = v
                }
            }
            for i in 0..<plane {
                let v = gen[o + i] + lam * (att[o + i] - blr[i])
                gen[o + i] = v < 0 ? 0 : (v > 1 ? 1 : v)
            }
        }
    }

    /// 他点名要的那一格＝tools/beauty_ab.py 第 1 列「美白」：只动补丁的明度与偏色，几何、遮罩、贴法一概不碰。
    /// 本机没有 8 位 LAB 可走（补丁在手里是 planar RGB 0~1 float），所以 sRGB↔Lab(D65) 自己换算。
    /// 加数 100*11/255 ＝ PC 那句「uint8 的 L 加 11」折到 0~100 口径；与那一列逐像素对拍最大 5 灰阶
    /// （cv2 自己的浮点路径对同一参照是 4 灰阶），三把尺同档：见 tools/whiten_parity.py 的判决表。
    /// 网回来的 float 可以越出 0~1（pow 负底会出 NaN），PC 那一列是先 clip 成 8 位再算的，这里同一刀。
    static func whiten(_ gen: inout [Float], side: Int) {
        let plane = side * side
        let xr = 0.950456, yr = 1.0, zr = 1.089058        // cv2 Lab98 用的 D65 参考白
        let eps = 0.008856, kap = 903.3
        let ladd = 100.0 * 11.0 / 255.0
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func enc(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055 }
        func f(_ t: Double) -> Double { t > eps ? cbrt(t) : (kap * t + 16.0) / 116.0 }
        func h(_ t: Double) -> Double { let c = t * t * t; return c > eps ? c : (116.0 * t - 16.0) / kap }
        for o in 0..<plane {
            let r = lin(min(1.0, max(0.0, Double(gen[o]))))
            let g = lin(min(1.0, max(0.0, Double(gen[plane + o]))))
            let b = lin(min(1.0, max(0.0, Double(gen[2 * plane + o]))))
            let fx = f((0.412453 * r + 0.357580 * g + 0.180423 * b) / xr)
            let fy = f((0.212671 * r + 0.715160 * g + 0.072190 * b) / yr)
            let fz = f((0.019334 * r + 0.119193 * g + 0.950532 * b) / zr)
            let L = min(100.0, max(0.0, (116.0 * fy - 16.0) * 1.06 + ladd))
            let aa = 500.0 * (fx - fy) * 0.90
            let bb = 200.0 * (fy - fz) * 0.92
            let ny = (L + 16.0) / 116.0
            let X = h(ny + aa / 500.0) * xr
            let Y = (L > kap * eps ? ny * ny * ny : L / kap) * yr
            let Z = h(ny - bb / 200.0) * zr
            gen[o] = Float(enc(min(1.0, max(0.0, 3.240481 * X - 1.537158 * Y - 0.498537 * Z))))
            gen[plane + o] = Float(enc(min(1.0, max(0.0, -0.969254 * X + 1.875990 * Y + 0.041556 * Z))))
            gen[2 * plane + o] = Float(enc(min(1.0, max(0.0, 0.055643 * X - 0.204026 * Y + 1.057311 * Z))))
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
