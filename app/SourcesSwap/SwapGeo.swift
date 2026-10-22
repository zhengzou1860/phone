import Foundation
import CoreGraphics

/// 对齐 / 回贴的数学，逐式对照 PC 那份跑通的实现：
///   模板点位＋回贴：官方 align_face.align_with_five_points 的 REFERENCE_FACIAL_POINTS 与
///   官方 dealign + tools/mfs_dealign.py 的"只贴脸框"版（PC 上 217 帧对拍过：与整幅版差 ≤2 灰阶、17 个像素）
///   拟合这一格是唯一的偏离：官方是 5 点 → 6 参数最小二乘仿射，这一版换成 4 参相似拟合。
///   换的理由不是「更简单」，是量出来的：6 参里各向异性＋剪切那两档没人约束，逐帧点位噪声被它们吸收成形状变化，
///   同一格内容遮罩全冻住、只挪矩阵时边界爬行 3.0 px/帧（锁成相似 2.3 px），出片整链 3.47→2.22 px/帧。
///   与 PC 已验的 10 方程 4 未知最小二乘同解（见 fitSimilarity 那一段的对拍数字）。
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

    /// 5 点 → 模板的 4 自由度相似拟合（等比缩放＋旋转＋平移）。先各自减质心，一次项与交叉项归零，
    /// 剩下 a＝Σ(p̃·d̃)/Σ|p̃|²、b＝Σ(p̃x·d̃y − p̃y·d̃x)/Σ|p̃|²，平移由两个质心补齐。
    /// 与「10 方程 4 未知最小二乘」同解：本机 20000 组随机 5 点上矩阵元最大差 4.8e-11、
    /// 224×236 每格位移最大 7.2e-10 px ⇒ 这一式可以直接顶掉上面那一式，不用解 3×3。
    /// 锁掉的那两档（各向异性＋剪切）正是闪的来源：6 参拟合里它们没有约束，
    /// 逐帧的点位噪声被它们吸收成形状变化（本机量到放大倍率 avg 1.033、相邻帧 |Δ| 0.009）。
    static func fitSimilarity(_ src: [CGPoint], _ dst: [CGPoint]) -> Affine? {
        guard src.count == dst.count, src.count >= 3 else { return nil }
        let n = Double(src.count)
        var psx = 0.0, psy = 0.0, dsx = 0.0, dsy = 0.0
        for i in 0..<src.count {
            psx += Double(src[i].x); psy += Double(src[i].y)
            dsx += Double(dst[i].x); dsy += Double(dst[i].y)
        }
        let pmx = psx / n, pmy = psy / n, dmx = dsx / n, dmy = dsy / n
        var s2 = 0.0, dot = 0.0, cross = 0.0
        for i in 0..<src.count {
            let px = Double(src[i].x) - pmx, py = Double(src[i].y) - pmy
            let qx = Double(dst[i].x) - dmx, qy = Double(dst[i].y) - dmy
            s2 += px * px + py * py
            dot += px * qx + py * qy
            cross += px * qy - py * qx
        }
        guard s2 > 1e-12 else { return nil }
        let a = dot / s2, b = cross / s2
        return Affine(a: a, b: -b, c: dmx - (a * pmx - b * pmy),
                      d: b, e: a, f: dmy - (b * pmx + a * pmy))
    }

    /// 手性两把叉（点序 [眼左,眼右,鼻,嘴角左,嘴角右]）：眼轴×鼻位、眼轴×嘴角中点。
    /// 相似拟合只会给一个「转正」的解、det ＝ a²＋b² 恒正，所以点位被排成镜像不能靠 det 的符号看，
    /// 只能靠手性：判法＝这两把叉各自与模板同号否。
    /// 为什么不用 5 点围成多边形的有向面积（0.24 及以前的判据）：它是两大块相消，正脸那点余量只剩模板面积的 1 倍，
    /// 合成几何（tools/_swap_yaw.py）算出来俯仰 30° 就只剩 8%、45° 直接翻号＝抬头低头被当成镜像挡掉。
    /// 这两把叉在偏航／俯仰／滚转下符号都不动，而 y 真被翻面（鼻跑到眼轴之上）时两把一起翻号。
    static func chirality(_ pts: [CGPoint]) -> (nose: Double, mouth: Double) {
        guard pts.count == 5 else { return (0, 0) }
        let ux = Double(pts[1].x) - Double(pts[0].x)
        let uy = Double(pts[1].y) - Double(pts[0].y)
        let ex = (Double(pts[0].x) + Double(pts[1].x)) / 2
        let ey = (Double(pts[0].y) + Double(pts[1].y)) / 2
        let mx = (Double(pts[3].x) + Double(pts[4].x)) / 2
        let my = (Double(pts[3].y) + Double(pts[4].y)) / 2
        return (ux * (Double(pts[2].y) - ey) - uy * (Double(pts[2].x) - ex),
                ux * (my - ey) - uy * (mx - ex))
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

    /// 官方 preprocess_mask：>0.001 归 1 → 11×11 膨胀 → 11×11 腐蚀×2 → 横向再放宽 1×41 → 7×7 模糊 → 乘 10 px 内收衰减
    /// 只这两处偏离官方：下边不再内收（下巴下半截就是被那一刀切掉的），左右和上边照旧；
    /// 腐蚀之后加一刀只往左右长的放宽——「侧脸没遮完」是横向的缺口，各向同性地放大会连带往头发和额头上长。
    /// 下边缘的剖面不在这里乘，由 featherMask 折进 244 行那张再整张糊一次（伸出补丁那几行只有现算才有）。
    static func preprocessMask(_ inMask: [Float], _ m2: inout [Float]) {
        let s = size
        var m = inMask
        for i in 0..<m.count { m[i] = m[i] > 0.001 ? 1.0 : m[i] }
        m = boxMax(m, s, 11)
        m = boxMin(m, s, 11); m = boxMin(m, s, 11)   // iterations=2
        m = boxMaxX(m, s, 61)                        // 只往左右各放 30 px（41→61：10-22 对拍那批臂都是这一档）
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

    /// 只沿着一行取最大值 ＝ cv2.dilate(m, np.ones((1, k)))：核只有一行，所以列方向一个像素也不动
    private static func boxMaxX(_ a: [Float], _ s: Int, _ k: Int) -> [Float] {
        let r = k / 2
        var o = [Float](repeating: 0, count: a.count)
        for y in 0..<s {
            for x in 0..<s {
                var v = a[y * s + x]
                let x0 = max(0, x - r), x1 = min(s - 1, x + r)
                for xx in x0...x1 { v = max(v, a[y * s + xx]) }
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
    // ——巴尖压根不在补丁里，光挪遮罩内收量最多盖到 218 行。所以剖面伸出补丁 chinExt 行。
    // 伸出那几行接什么，本机 20 帧对拍过四档（tools/_swap_tail.py）：
    // ① 拿补丁末行平铺（0.17 及以前）＝那一行是网画的下颌暗面，摊在脖子上是一道横着的黑缝；
    // ② 拿对齐原片末行平铺（0.18~0.27）＝一条纵向纹理 0.41（补丁内 0.9）的亮带，压着比原片暗 8.96 L 的
    //    换脸下巴，补丁线那道台阶 −16.61 L、相邻行最大跳变 18.30＝他判的「遮罩和源脸边缘处有深色边痕迹」；
    // ③ 镜像接＝脖子上多一道弧形的下巴鬼影，比平铺更难看；
    // ④ 0.28 起＝「这一格整幅原像素＋一个色差」（tailShift）：台阶 +1.34、硬线 5.68、伸出带纹理 0.71
    //    （回到有纹理那一档），而下巴带覆盖 95.3%、↔源 0.771、能量比 0.506 三个一个没动
    //    （那 20 行本来就不带身份信息）。
    // ⑤ 10-22 换图对拍（源＝aa/3.png 目标＝aa/4.png，tools/_swap_img.py）＝他判「为什么都延伸到肩膀了，
    //    下巴这还是有明显的分界线痕迹，我看所有的都有」的那一条：所有臂的「硬行」都落在 223 行（补丁下沿），
    //    缝净 26.65。成因＝补丁末几行以 −3.5 L/行往下掉、原图从 224 起是亮的，而 ④ 那档「带内均值差」
    //    在接缝处错开，多出 +21 L 的台阶。改成切线对齐（上下两侧各拟合一条直线，在第 223.5 行对上值和斜率），
    //    硬线 22.72→4.87、缝净 26.65→5.97，肩那一带也不再被提亮（肩差 5.46→−0.02）。
    // 这一刀同时挪到肩线：alpha 满格压到第 385 行（肩线），386~398 之间淡出。
    // 那 13 行淡出段里的内容与原片逐像素相同（＝接缝偏置到第 263 行就衰减完了），所以看不出边。
    static let chinRamp0 = 385.0                   // alpha 满格压到这一行（肩线）
    static let chinExt = 175.0                    // 补丁下面还留这么多行（385→398 之间淡出）
    static var chinRamp1: Double { Double(size - 1) + chinExt }   // 到这一行掉到 0

    /// smoothstep 1→0：第 385 行之前 alpha 一律满（补丁那 224 行、还有下巴到肩那一段都是 1），
    /// 落差整段落在 385~398 之间
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
    static var maskRows: Int { Int(chinRamp1) + 1 }        // 399 行＝补丁 224 行＋下巴到肩那 175 行

    /// 224 那张遮罩 → 399×224 的成品 alpha：下巴剖面先折进来（下面那几行拿末行接下去），
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

    /// 接缝偏置往下几行内衰减到零（对齐 224 空间）＝本机对拍他选的那一档 40 行
    static let seamDecayRows = 40.0

    /// 接缝偏置的衰减：第 224 行满格，seamDecayRows 行内 smoothstep 到 0。
    /// 40 这一档是他在本机对拍图里选的（rig 的 nseam＝40 那臂）。
    private static func seamDecay(_ fy: Double) -> Float {
        let t = (fy - Double(size - 1)) / seamDecayRows
        if t <= 0 { return 1 }
        if t >= 1 { return 0 }
        return Float(1 - t * t * (3 - 2 * t))
    }

    /// 最小二乘拟合一条直线 y = a·x + b
    private static func fitLine(_ xs: [Double], _ ys: [Double]) -> (Double, Double) {
        let n = Double(xs.count)
        guard n >= 2 else { return (0, ys.first ?? 0) }
        var mx = 0.0, my = 0.0
        for i in 0..<xs.count { mx += xs[i]; my += ys[i] }
        mx /= n; my /= n
        var sxy = 0.0, sxx = 0.0
        for i in 0..<xs.count {
            let dx = xs[i] - mx
            sxy += dx * (ys[i] - my); sxx += dx * dx
        }
        guard sxx > 1e-12 else { return (0, my) }
        let a = sxy / sxx
        return (a, my - a * mx)
    }

    /// 补丁线（223/224）那道接缝的色差（planar 序 R,G,B，0~1 刻度与 gen 同）：
    /// 补丁末 10 行（214~223）与原图接下去的 10 行（224~233）各自拟合一条直线，
    /// 在第 223.5 行上把两条直线的值对上，差值就是原图那一侧要加的偏置。
    /// 为什么不再用带内均值差（旧 tailShift）：补丁末几行以 −3.5 L/行往下掉，原图从 224 起是亮的，
    /// 均值差在接缝处错开，多出 +21 L 的台阶＝他判「下巴这还是有明显的分界线痕迹」。
    /// 本机对拍（tools/_swap_img.py，源＝aa/3.png 目标＝aa/4.png）：硬线 22.72→4.87、缝净 26.65→5.97。
    private static func seamTangent(_ p: UnsafePointer<UInt8>, rowPix: Int, w: Int, h: Int,
                                    gen: [Float], back: Affine) -> [Float] {
        let s = size, plane = s * s, c0 = s / 2 - 30, c1 = s / 2 + 30
        var segP = [[Double]](repeating: [], count: 3)
        var segG = [[Double]](repeating: [], count: 3)
        var xsP = [Double](), xsG = [Double]()
        for i in 0..<10 {
            xsP.append(Double(s - 10 + i) + 0.5)
            xsG.append(Double(s + i) + 0.5)
        }
        // 补丁侧：gen 的行均值（列 c0..<c1，与本机对拍同一组列）
        for y in (s - 10)..<s {
            for pl in 0..<3 {
                var m = 0.0
                for x in c0..<c1 { m += Double(gen[pl * plane + y * s + x]) }
                segP[pl].append(m / Double(c1 - c0))
            }
        }
        // 原图侧：把对齐空间的 (x, 224+k) 按 back 映回整幅，直接取那一格的原像素
        for k in 0..<10 {
            let fy = Double(s + k)
            for pl in 0..<3 {
                var m = 0.0
                var hit = 0
                for x in c0..<c1 {
                    let fx = Double(x)
                    let gx = back.a * fx + back.b * fy + back.c
                    let gy = back.d * fx + back.e * fy + back.f
                    let ix = Int(gx.rounded()), iy = Int(gy.rounded())
                    guard ix >= 0, iy >= 0, ix < w, iy < h else { continue }
                    let o = iy * rowPix * 4 + ix * 4
                    switch pl {
                    case 0: m += Double(p[o + 2]) / 255.0      // R
                    case 1: m += Double(p[o + 1]) / 255.0      // G
                    default: m += Double(p[o]) / 255.0         // B
                    }
                    hit += 1
                }
                guard hit >= (c1 - c0) else { return [0, 0, 0] }   // 这一行整个在画面外＝没得对色
                segG[pl].append(m / Double(hit))
            }
        }
        var out = [Float](repeating: 0, count: 3)
        for pl in 0..<3 {
            let fp = fitLine(xsP, segP[pl])
            let fg = fitLine(xsG, segG[pl])
            out[pl] = Float((fp.0 * 223.5 + fp.1) - (fg.0 * 223.5 + fg.1))
        }
        return out
    }

    /// 官方 dealign 的框内版：整幅像素 (gx,gy) 用正向 M（整幅→模板）去 224 结果和 mask 里取样，
    /// 再按 mask 就地混进 BGRA。clip 到 0~255 同 cv2 存盘那一步。
    /// 补丁底下伸出去那几行：取样落不进 gen 的那几格用「这一格整幅原像素＋接缝偏置」，
    /// 偏置按对齐行往下衰减（224 行满格、40 行内到 0），
    /// 不再平铺对齐原片的末行（旧版那样接出来的是一条纵向纹理≈0 的亮带，压着补丁里画暗了的下巴，
    /// 接缝就是他判的「遮罩和源脸边缘处有深色边痕迹」）。
    static func pasteBack(_ base: UnsafeMutableRawPointer, bytesPerRow: Int, w: Int, h: Int,
                          gen: [Float], mask: [Float], fwd: Affine, back: Affine,
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
        let se = seamTangent(p, rowPix: rowPix, w: w, h: h, gen: gen, back: back)
        for gy in yi0..<yi1 {
            for gx in xi0..<xi1 {
                let u = Double(gx), v = Double(gy)
                let fx = fwd.a * u + fwd.b * v + fwd.c
                let fy = fwd.d * u + fwd.e * v + fwd.f
                guard fx >= 0, fy >= 0, fx <= Double(size - 1), fy <= chinRamp1 else { continue }
                // alpha 落在 featherMask 那张 244×224 上（剖面和羽化都在里面了），不再按行现算
                let mk = bilinearFloat(mask, size, mask.count / size, fx, fy)
                if mk <= 0 { continue }
                let x0 = Int(fx), y0 = Int(fy)
                let dx = Float(fx - Double(x0)), dy = Float(fy - Double(y0))
                let x1 = min(x0 + 1, size - 1), y1 = min(y0 + 1, maskRows - 1)
                let o = gy * rowPix * 4 + gx * 4
                let dec = seamDecay(fy)
                for (ci, planeIdx) in [(2, 0), (1, 1), (0, 2)] {   // BGRA 内存序：B←planar R 反着写
                    let g = planeIdx * plane
                    // 补丁只到 223 行；224 往上（含 223↔224 那一格插值）落进「这一格原像素＋接缝偏置」
                    let tv = Float(p[o + ci]) / 255.0 + se[planeIdx] * dec
                    let a00 = y0 < size ? gen[g + y0 * size + x0] : tv
                    let a10 = y0 < size ? gen[g + y0 * size + x1] : tv
                    let a01 = y1 < size ? gen[g + y1 * size + x0] : tv
                    let a11 = y1 < size ? gen[g + y1 * size + x1] : tv
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
