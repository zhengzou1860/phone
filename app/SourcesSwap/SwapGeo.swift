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
    ///
    /// 最后再乘一道「收形」＝ min(1, 网自己的 mask ÷ shrinkK)：几何那几步（阈值 0.001＋横放宽 61 px）把遮罩撑到
    /// 比网真正画过的那一片大得多——本机三帧量下来，α>0.5 且在 224 窗口里的可见贴区占整幅 46~55 %，
    /// 其中 **22~33 % 的格子网自己的 mask < 0.3**，也就是那一片它根本没重画，贴进去的是原片缩到 224
    /// 再放大 5.5~6.2 倍的那一份＝一张糊掉的原片，边界正是 1×61 横核长出来的直边＝他 10-23 描的那个正方形、
    /// 判的那层「整个遮罩一层白膜」。乘完这三帧的可见贴区 55.1→38.6 %／50.3→40.5 %／46.2→34.2 %，
    /// 「没画」那一份压到 4.0 %／3.6 %／6.3 %，而 ↔源 0.787→0.786／0.790→0.790／0.743→0.745
    /// ＝那一片本来就不带身份信息，撤掉它身份一格不赔（tools/_veil23.py）。
    static let shrinkK: Float = 0.3

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
        let k = shrinkK
        for i in 0..<m.count { m2[i] = m[i] * m1[i] * min(1.0, inMask[i] / k) }
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
    // 那 13 行淡出段里的内容与原片逐像素相同（接缝色差已经搬到补丁侧了，接缝以下一个像素都不动），所以看不出边。
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

    /// 接缝色差搬到补丁侧：补丁末 10 行（214~223）按 smoothstep 渐变地补上 −se，
    /// 让补丁末行的颜色对上原图第 224 行往下走的那条趋势线。
    /// 为什么不再加在原片那一侧（0.29/0.30 那档）：加在原片上＝给脖子那一整块染色，
    /// 出来就是下巴下面一个直边矩形（他 10-22 圈的那道分界线）；
    /// 本机量到那一块相对原片偏暗 16 L（均值 −5.4 L），搬到补丁侧以后接缝以下逐像素等于原片（0.00 L）。
    static let seamTaperRows = 10.0

    // MARK: - 接缝那道分界线：把交接从半个对齐像素摊到 16 行（他 10-23 令「把那条分界线隐藏掉吧」）
    //
    // 成因（先定位再动手，tools/_veil26.py 按对齐行带扫出来的）：补丁在下巴／脖子那一片本来就比
    // 原片暗 5~10 L（行 196-223 那几带 −6.7~−9.8 L），而贴的交接压在**一个对齐像素**里
    // （gen[223] 与原像素那半格的双线性）＝u≈6.2 时 3.57 L 的落差摊在 6 个输出像素上＝一条线。
    // ⚠️ 我第一版那把尺（沿输出行求均值，tools/_veil25.py 旧臂）量出来接缝只跳 0.71 L、与原片自己
    // 的 0.63 L 没差＝根本没这条线——**错在接缝在这张图里是斜的**（仿射带旋转），按输出行求均值
    // 把上下两档混在同一行里抹平了。尺子必须按对齐行带量：跳＝mean(成品−原片) 在 [220,223.5) 减 [224,228)。
    // 改法＝α 在接缝上方 seamFadeRows 行里 smoothstep 淡到 0（补丁自己把脖子交回原片）：
    // 那一档落差从 6 个输出像素摊到 ~99 个＝不再是线；差图（成品−原片 ×8）上原来沿接缝有一串亮珠，
    // 淡出以后那串没了（图 tools/_veil25_map_b336.png，肉眼与尺子同向）。
    // 本机三帧（tools/_veil25.py，跨缝跳／↔源／贴区；地板＝原片自己 +0.06/−0.01/+0.03 L）：
    //   b336（脸 740 px，u=6.20）跳 −3.57 → 淡 8 −0.87／淡 16 −0.53／淡 24 −0.47／淡 40 −0.45；↔源 0.715 一分不掉；
    //   b312（u=5.87）跳 +3.16 → 淡 8 +0.13／淡 16 −0.16／淡 40 −0.22；↔源 0.793 → 0.787／0.781／0.744；
    //   b384（u=5.52）跳 −1.76 → 淡 8 −0.56／淡 16 −0.47／淡 40 −0.48；↔源 0.744 → 0.732／0.723／0.668。
    // 鼻孔差、洞差、带通四档在淡 16 以内全不动（b336 带通 1.000/0.981/1.068/1.003 → 0.994/0.977/1.063/1.003）；
    // 淡到 40 行开始亏（↔源 掉 0.03~0.08、b336 ↔目标 0.262→0.223、带通 0.949＝把目标的脸搬回来了）。
    // 取 16＝他报的那一帧（b336）↔源零代价、三帧跳都压到 0.5 L 档；8 那一格 b336 还留 −0.87。
    // 淡出的是巴尖（≈对齐 233 行）以上那 16 行巴／颈，盖全脸那件事不受影响；接缝以下本来就逐字节等于原片。
    static let seamFadeRows = 16.0

    /// 接缝上方的 α 行因子：第 223.5−16 行以上＝1，到第 223.5 行＝0，再往下恒 0（那一片就是原片）
    static func seamFade(_ fy: Double) -> Float {
        let t = (fy - (Double(size) - 0.5 - seamFadeRows)) / seamFadeRows
        if t <= 0 { return 1 }
        if t >= 1 { return 0 }
        return Float(1 - t * t * (3 - 2 * t))
    }

    /// 补丁末 10 行的补色权重：第 213 行 0、第 223 行 1
    private static func seamTaper(_ row: Int) -> Float {
        let t = (Double(row) - (Double(size - 1) - seamTaperRows)) / seamTaperRows
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return Float(t * t * (3 - 2 * t))
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
    /// 在第 223.5 行上把两条直线的值对上，差值就是补丁侧要减掉的量（0.31 起不再往原片那一侧加）。
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

    // MARK: - 逐频带搬（他 10-23 令「就是糊，包括遮罩五官的位置，把回填从一档改成逐频带搬」）
    //
    // restoreDetail 那一档在 224 里搬，能搬到的最细周期＝一个对齐像素。脸一大，一个对齐像素盖好几个输出像素，
    // 那一档就比原片自己的细节粗得多。本机在脸 952×1131 那一帧量（tools/_band3.py，补丁内 α 满格那块，
    // 「成品/原片」的带通能量比）：<0.8 档 0.319、0.8-2 档 0.536，而 2-4／4-8 档已经是 1.098／1.078
    // ＝细的两档搬不回来，粗的两档网络自己画过了还有余。所以「搬不搬」跟着放大倍率 u 走：
    // u < 1.6（＝一个对齐像素盖不满 1.6 个输出像素）一档都不搬＝成品逐字节等于现役——
    // 脸 51×66 那张 u=0.32、脸 175×232 那张 u=0.91，那里硬搬会把 ↔源 0.861 打到 0.545、↔目标 0.014 抬到 0.464
    // ＝把目标自己的脸搬回来（他判的「没遮住」）。
    //
    // 搬的是哪一档＝「224 这张网格装不下的那一档」：原片亮度 − 这一帧对齐原片（att）双线性映回整幅。
    // 取样的坐标与补丁用的完全是同一组（x0/y0/x1/y1、dx/dy），手机上不额外糊任何一张图、不多开一张整幅缓冲，
    // 钱＝贴回循环里每个像素多读 4 个数。本机对拍（tools/_band3.py「224 网格高通 仅亮度」那一臂，
    // 灰度两侧都走浮点＝与 Swift 同一式；先前一版按 8 位灰度量出的 1.107／1.105 是把 <0.8 那档被
    // ±0.5 灰阶的量化抖动抬假了，作废）：
    //   搬 2 档（σ=2 的 17 抽高斯）b336 1.055／1.048、b384 1.047／1.068｜↔源 0.701／0.746
    //   这一臂                b336 1.062／1.101、b384 1.071／1.120｜↔源 0.713／0.743
    //   现役                  b336 0.319／0.536、b384 0.341／0.590｜↔源 0.718／0.747
    // ＝粗的那档补得更足、身份少丢一格、钱是一份高斯的几分之一。四邻高通（0.942／0.652）和 5 盒×2（1.056／1.075）在这两臂之间。
    // 搬的是亮度（三通道同一个量）：灰度是线性组合，逐通道与仅亮度在灰度带通上是同一个数，差的只有色度和钱。
    static let bandSigmas: [Double] = [0.8, 2.0, 4.0, 8.0]

    /// 一个对齐像素盖几个输出像素 ＝ back（模板→整幅）那支的尺度 ＝ 1／fwd（整幅→模板）的尺度
    static func upscale(_ fwd: Affine) -> Double {
        let det = abs(fwd.a * fwd.e - fwd.b * fwd.d)
        return det > 1e-9 ? 1.0 / det.squareRoot() : 0.0
    }

    /// 搬前 K 档（σ ≤ u/2）；0 ＝ 一档都不搬。这一版只用它当闸门（K>0 才搬），档界由 att 那张网格自己定
    static func bandCount(_ up: Double) -> Int {
        var n = 0
        for s in bandSigmas { if s <= up / 2.0 { n += 1 } else { break } }
        return n
    }

    /// 这一帧搬不搬（pasteBack 与流水那一格共用这一个判断，两处不许各写一遍）
    static func wantsBand(_ fwd: Affine) -> Bool { bandCount(upscale(fwd)) > 0 }

    /// att 的亮度面（0~255 刻度）：三张平面按 BT.601 合一张，5 万点，一次一帧。
    /// 只有闸门要搬时才算；不搬时这一张根本不建。
    private static func lumPlane(_ att: [Float]) -> [Float] {
        let plane = size * size
        var g = [Float](repeating: 0, count: plane)
        for i in 0..<plane {
            g[i] = (0.299 * att[i] + 0.587 * att[plane + i] + 0.114 * att[2 * plane + i]) * 255.0
        }
        return g
    }

    /// 官方 dealign 的框内版：整幅像素 (gx,gy) 用正向 M（整幅→模板）去 224 结果和 mask 里取样，
    /// 再按 mask 就地混进 BGRA。clip 到 0~255 同 cv2 存盘那一步。
    /// 补丁底下伸出去那几行：取样落不进 gen 的那几格用「这一格整幅原像素」，
    /// 接缝色差改加在补丁末 10 行上（seamTaper）——
    /// 原来那档是把色差加在原片一侧往下衰减 40 行，出来是下巴下面一个直边矩形（他 10-22 圈的那道分界）。
    /// 逐频带搬并进同一个循环（不是回贴之后再叠一遍）：见上面那段。返回值＝建 att 亮度面那一句花了多少 ms（没搬＝0），给单价那一格记账。
    @discardableResult
    static func pasteBack(_ base: UnsafeMutableRawPointer, bytesPerRow: Int, w: Int, h: Int,
                          gen: [Float], mask: [Float], att: [Float], fwd: Affine, back: Affine,
                          padRatio: Double = 0.06) -> Double {
        let roi = faceRoi(back: back, yMax: chinRamp1)
        let rw = roi.x1 - roi.x0, rh = roi.y1 - roi.y0
        let xi0 = max(0, Int(floor(roi.x0 - rw * padRatio)))
        let yi0 = max(0, Int(floor(roi.y0 - rh * padRatio)))
        let xi1 = min(w, Int(ceil(roi.x1 + rw * padRatio)))
        let yi1 = min(h, Int(ceil(roi.y1 + rh * padRatio)))
        if xi1 <= xi0 || yi1 <= yi0 { return 0 }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let rowPix = bytesPerRow / 4
        let plane = size * size
        let se = seamTangent(p, rowPix: rowPix, w: w, h: h, gen: gen, back: back)
        // 逐频带搬：闸门＝一个对齐像素盖够 1.6 个输出像素（bandCount>0），不搬时下面这张根本不建。
        // 建的是 att 的亮度面（224×224，一帧一次），高通在下面那个循环里就地取——
        // 取样坐标与补丁那三档完全同一组，所以不糊图、不开整幅缓冲。
        let tb = DispatchTime.now().uptimeNanoseconds
        let lum = wantsBand(fwd) ? lumPlane(att) : [Float]()
        let bandMs = Double(DispatchTime.now().uptimeNanoseconds - tb) / 1_000_000
        let hasLum = !lum.isEmpty
        for gy in yi0..<yi1 {
            for gx in xi0..<xi1 {
                let u = Double(gx), v = Double(gy)
                let fx = fwd.a * u + fwd.b * v + fwd.c
                let fy = fwd.d * u + fwd.e * v + fwd.f
                guard fx >= 0, fy >= 0, fx <= Double(size - 1), fy <= chinRamp1 else { continue }
                // alpha 落在 featherMask 那张 399×224 上（剖面和羽化都在里面了），不再按行现算；
                // 再乘一道接缝淡出＝把补丁与原片的交接从半个对齐像素摊到 16 行（见 seamFade 那一段）
                let mk = bilinearFloat(mask, size, mask.count / size, fx, fy) * seamFade(fy)
                if mk <= 0 { continue }
                let x0 = Int(fx), y0 = Int(fy)
                let dx = Float(fx - Double(x0)), dy = Float(fy - Double(y0))
                let x1 = min(x0 + 1, size - 1), y1 = min(y0 + 1, maskRows - 1)
                let o = gy * rowPix * 4 + gx * 4
                // 逐频带搬＝「224 这张网格装不下的那一档」＝这一格整幅原片亮度 − att 亮度面在
                // 同一组坐标上的双线性。只在补丁里、α 从 0.95 缓坡爬到 1.0（硬切会沿遮罩等值线留一圈边）。
                // 行方向同样不许硬断：接缝以下贴的＝逐字节原片，若第 223 行带着这一项、第 224 行归零，
                // 沿整条 223/224 接缝就留一道亮线（＝他 10-23 报的「下巴的白线」）。
                // 本机三帧量接缝上方那半格相对原片亮多少：硬门 +13.2／+8.2／+13.9 L（配补丁 taper 那档 +11.0／+16.9／+20.5），
                // 原片自己同一条线 +0.05／+0.04／−0.01 L＝地板。
                // 改成末 10 行（对齐 213→223）smoothstep 淡出到 0：三帧全部落回「不搬」那一档（−1.6／−5.2／−7.6），
                // 而带通四档 1.034/1.016/1.090/1.007 → 1.001/0.982/1.070/1.001、↔源 0.785、鼻孔差 3.66 一分没丢
                // （tools/_veil24.py，b336 七臂特写在 _veil24_b336.png：第 2 格有线、第 4 格没有）。
                var hpv: Float = 0
                if hasLum, mk > 0.95 {
                    let q = min(1.0, max(0.0, (fy - Double(size - 11)) / 10.0))
                    let fade = Float(1.0 - q * q * (3.0 - 2.0 * q))
                    if fade > 0 {
                        let ry0 = min(y0, size - 1), ry1 = min(y1, size - 1)
                        let w00 = (1 - dx) * (1 - dy), w10 = dx * (1 - dy)
                        let w01 = (1 - dx) * dy, w11 = dx * dy
                        let grid = w00 * lum[ry0 * size + x0] + w10 * lum[ry0 * size + x1]
                            + w01 * lum[ry1 * size + x0] + w11 * lum[ry1 * size + x1]
                        let ogv = 0.299 * Float(p[o + 2]) + 0.587 * Float(p[o + 1]) + 0.114 * Float(p[o])
                        hpv = (ogv - grid) * min(1.0, (mk - 0.95) * 20.0) * fade
                    }
                }
                // 补丁末 10 行按 taper 补上 −se（接缝色差搬到补丁侧）
                let t0 = y0 < size ? seamTaper(y0) : 0
                let t1 = y1 < size ? seamTaper(y1) : 0
                for (ci, planeIdx) in [(2, 0), (1, 1), (0, 2)] {   // BGRA 内存序：B←planar R 反着写
                    let g = planeIdx * plane
                    // 补丁只到 223 行；224 往上（含 223↔224 那一格插值）直接用原像素：
                    // 不再叠接缝偏置——那一格是把脖子整块染色，出来是下巴下面一个直边矩形
                    let tv = Float(p[o + ci]) / 255.0
                    let a00 = y0 < size ? max(0, min(1, gen[g + y0 * size + x0] - se[planeIdx] * t0)) : tv
                    let a10 = y0 < size ? max(0, min(1, gen[g + y0 * size + x1] - se[planeIdx] * t0)) : tv
                    let a01 = y1 < size ? max(0, min(1, gen[g + y1 * size + x0] - se[planeIdx] * t1)) : tv
                    let a11 = y1 < size ? max(0, min(1, gen[g + y1 * size + x1] - se[planeIdx] * t1)) : tv
                    let v0 = a00 + (a10 - a00) * dx
                    let v1 = a01 + (a11 - a01) * dx
                    let g2 = v0 + (v1 - v0) * dy
                    let orig = Float(p[o + ci])
                    let v2 = g2 * 255.0 * mk + orig * (1 - mk) + hpv
                    p[o + ci] = UInt8(max(0, min(255, v2 + 0.5)))
                }
            }
        }
        return bandMs
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
