import Foundation
import CoreGraphics

/// fsx 那条链路的几何，逐式对照 PC 上跑通、肉眼认过的 fsx/swapcore.py：
/// 5 点 → 相似变换 → warpAffine 到 112（身份证）和 128（补丁）→ 结果按官方那三刀贴回。
/// 这一份不调旧算法（SwapGeo）里的任何函数：矩阵、取样、遮罩、腐蚀、糊全在这里现写——
/// 旧那条线的贴区形状是分割网画出来的，这一条线的贴区是 128 方块投回帧空间的那个平行四边形。
enum FsxGeo {
    static let side112 = 112
    static let side128 = 128

    /// 2×3：dst = [a b c; d e f]·(x, y, 1)，和 cv2 的 M 同一个排法
    struct M23 { var a, b, c, d, e, f: Double }

    /// arcface 的 5 点标准框（112 空间）＝官方 REFERENCE_FACIAL_POINTS 的 x 各 +8。
    /// 换脸那一步按 size/112 缩放它（PC: TPL112*(size/112)）——所以 112 和 128 两个框是同一个框，
    /// 身份证和补丁落在同一张脸上，不会错开。
    static let tpl112: [(Double, Double)] = [(38.2946, 51.6963), (73.5318, 51.5014), (56.0252, 71.7366),
                                             (41.5493, 92.3655), (70.7299, 92.2041)]

    static func templateFor(_ size: Int) -> [CGPoint] {
        let s = Double(size) / 112.0
        return tpl112.map { CGPoint(x: $0.0 * s, y: $0.1 * s) }
    }

    /// 5 组点对求 4 自由度相似（等比缩放＋旋转＋平移）。
    /// PC 那式是 10 方程 4 未知的最小二乘闭式解；先各自减质心，一次项与交叉项归零，
    /// 剩下 a＝Σ(p̃·d̃)/Σ|p̃|²、b＝Σ(p̃×d̃)/Σ|p̃|²，平移由两个质心补齐——两式同解（本机对拍过）。
    static func fit(_ src: [CGPoint], _ dst: [CGPoint]) -> M23? {
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
        return M23(a: a, b: -b, c: dmx - (a * pmx - b * pmy),
                   d: b, e: a, f: dmy - (b * pmx + a * pmy))
    }

    /// 齐次 3×3 求逆取前两行＝cv2.invertAffineTransform（非奇异时同 pinv）
    static func inverse(_ m: M23) -> M23? {
        let det = m.a * m.e - m.b * m.d
        guard abs(det) > 1e-12 else { return nil }
        return M23(a: m.e / det, b: -m.b / det, c: (m.b * m.f - m.e * m.c) / det,
                   d: -m.d / det, e: m.a / det, f: (m.d * m.c - m.a * m.f) / det)
    }

    /// 5 个点位 → 这一条链路要的那两份正向矩阵（整幅→112、整幅→128）
    static func align(_ pts: [CGPoint]) -> (fwd112: M23, fwd128: M23)? {
        guard let f112 = fit(pts, templateFor(side112)),
              let f128 = fit(pts, templateFor(side128)) else { return nil }
        return (f112, f128)
    }

    // MARK: - 正向：整幅 BGRA → size×size planar RGB 0..1

    /// cv2.warpAffine(img, M, (size,size), INTER_LINEAR, BORDER_REPLICATE)：
    /// 它的取样是 dst(x,y)=src(M⁻¹·(x,y))，所以这里收正向 M、自己求逆；越界那一格取边缘值（不是补 0）。
    /// 走不通（点位退化求不出逆）返回 false，调用方把这帧当没脸处理，不许静默交半张图。
    @discardableResult
    static func warpCrop(_ base: UnsafeRawPointer, bytesPerRow: Int, w: Int, h: Int,
                         fwd: M23, size: Int, out: inout [Float]) -> Bool {
        guard let inv = inverse(fwd) else { return false }
        let plane = size * size
        if out.count != 3 * plane { out = [Float](repeating: 0, count: 3 * plane) }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let rowPix = bytesPerRow / 4
        for oy in 0..<size {
            for ox in 0..<size {
                let fx = inv.a * Double(ox) + inv.b * Double(oy) + inv.c
                let fy = inv.d * Double(ox) + inv.e * Double(oy) + inv.f
                let k = oy * size + ox
                out[k] = tapCrop(p, rowPix, w, h, fx, fy, 0)
                out[plane + k] = tapCrop(p, rowPix, w, h, fx, fy, 1)
                out[2 * plane + k] = tapCrop(p, rowPix, w, h, fx, fy, 2)
            }
        }
        return true
    }

    /// 裁进去那一格的双线性取样：通道走 BGRA 内存序倒着读＝R,G,B（同 PC 的 [:,:,::-1]）。
    /// BORDER_REPLICATE 的口径：两个邻各自钳到画面内再按原权重合——
    /// 先钳整数坐标再把第二个邻跟着钳，fx=-1.3 时两邻同是第 0 列，取到的就是边缘那一格；
    /// 要是先钳了 x0 再 x1=x0+1，权重会把第 1 列掺进来，边上就会比 PC 亮一档。
    private static func tapCrop(_ p: UnsafePointer<UInt8>, _ rowPix: Int, _ w: Int, _ h: Int,
                                _ fx: Double, _ fy: Double, _ ch: Int) -> Float {
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let dx = Float(fx - Double(x0)), dy = Float(fy - Double(y0))
        let xa = min(max(x0, 0), w - 1), xb = min(max(x0 + 1, 0), w - 1)
        let ya = min(max(y0, 0), h - 1), yb = min(max(y0 + 1, 0), h - 1)
        func v(_ xx: Int, _ yy: Int) -> Float { Float(p[yy * rowPix * 4 + xx * 4 + ch]) }
        let top = v(xa, ya) + (v(xb, ya) - v(xa, ya)) * dx
        let bot = v(xa, yb) + (v(xb, yb) - v(xa, yb)) * dx
        return (top + (bot - top) * dy) / 255.0
    }

    // MARK: - 反向：128 的补丁贴回整幅

    /// 官方 inswapper 的贴回，三刀一刀不减：
    /// ① 白图随 128 方块投回帧空间，>20 的格子拉成 255＝贴区就是这个平行四边形自己；
    /// ② 按这块贴区量出的边长腐蚀 k＝max(mask_size//10,10)，把插值糊出去的那一圈收回来；
    /// ③ 再糊一刀，核长 2*max(mask_size//20,5)+1、σ 由核长现算（cv2 传 sigma=0 就是这个口径）。
    /// 全程只在外接框（再加腐蚀与糊的半径）里做，框外一像素不碰。
    /// face 必须是已经量化到 8 位那一份（PC 是 uint8 转 float 再 warp 的，跳过这步差半格）。
    static func pasteBack(_ base: UnsafeMutableRawPointer, bytesPerRow: Int, w: Int, h: Int,
                          face: [Float], fwd: M23) -> Bool {
        let s = side128
        guard face.count == 3 * s * s, let im = inverse(fwd) else { return false }
        let q = base.assumingMemoryBound(to: UInt8.self)
        let rowPix = bytesPerRow / 4
        let last = Double(s - 1)
        var xs: [Double] = [], ys: [Double] = []
        for (u, v) in [(0.0, 0.0), (last, 0.0), (0.0, last), (last, last)] {
            xs.append(im.a * u + im.b * v + im.c)
            ys.append(im.d * u + im.e * v + im.f)
        }
        // ① 外接框各留 2 格：边界外那一格的插值也算 >20，不留就把它切在框上
        let r1x0 = max(0, Int((xs.min() ?? 0).rounded(.down)) - 2)
        let r1y0 = max(0, Int((ys.min() ?? 0).rounded(.down)) - 2)
        let r1x1 = min(w - 1, Int((xs.max() ?? 0).rounded(.up)) + 2)
        let r1y1 = min(h - 1, Int((ys.max() ?? 0).rounded(.up)) + 2)
        guard r1x1 >= r1x0, r1y1 >= r1y0, r1x0 < w, r1y0 < h else { return false }
        let r1w = r1x1 - r1x0 + 1, r1h = r1y1 - r1y0 + 1
        var bin = [Float](repeating: 0, count: r1w * r1h)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for oy in 0..<r1h {
            for ox in 0..<r1w {
                let fx = fwd.a * Double(r1x0 + ox) + fwd.b * Double(r1y0 + oy) + fwd.c
                let fy = fwd.d * Double(r1x0 + ox) + fwd.e * Double(r1y0 + oy) + fwd.f
                if whiteTap(fx, fy) > 20 {
                    bin[oy * r1w + ox] = 255
                    if ox < minX { minX = ox }
                    if ox > maxX { maxX = ox }
                    if oy < minY { minY = oy }
                    if oy > maxY { maxY = oy }
                }
            }
        }
        guard maxX >= 0, maxY >= 0 else { return false }
        let maskSize = Int(((Double(maxY - minY) * Double(maxX - minX)).squareRoot()))
        let k = max(maskSize / 10, 10)
        let kb = max(maskSize / 20, 5)

        // ② 腐蚀。方核 k×k、cv2 的默认锚点 (k/2, k/2)，所以核覆盖 x+[-k/2, k/2-1]
        //（k 是偶数时这一串不对称，照它的样，别自作聪明居中）。
        // 二值方核腐蚀＝这一块窗口全白才留：用积分图把每格 k² 次比较降成一次求和。
        // 窗口越出画面那几格按 cv2 形态学的边框＝最大值（所以贴着画面边的脸不会被这一刀再收一圈）；
        // 越出外接框但还在画面里的，遮罩本来就是 0。
        let padE = k + kb + 8
        let gw = r1w + 2 * padE, gh = r1h + 2 * padE
        var integ = [Int](repeating: 0, count: (gh + 1) * (gw + 1))
        for gy in 0..<gh {
            let Y = r1y0 - padE + gy
            var run = 0
            for gx in 0..<gw {
                let X = r1x0 - padE + gx
                var on = 0
                if X < 0 || Y < 0 || X >= w || Y >= h {
                    on = 1                                  // 画面以外＝最大，腐蚀不吃这一圈
                } else {
                    let lx = X - r1x0, ly = Y - r1y0
                    if lx >= 0, ly >= 0, lx < r1w, ly < r1h, bin[ly * r1w + lx] > 0 { on = 1 }
                }
                run += on
                integ[(gy + 1) * (gw + 1) + (gx + 1)] = integ[gy * (gw + 1) + (gx + 1)] + run
            }
        }
        func allWhite(_ X: Int, _ Y: Int) -> Bool {
            // 窗口 [X-k/2, X+k/2-1]×[Y-k/2, Y+k/2-1] 换成积分图的下标
            let gx0 = X - r1x0 + padE - k / 2, gy0 = Y - r1y0 + padE - k / 2
            let s0 = integ[gy0 * (gw + 1) + gx0] + integ[(gy0 + k) * (gw + 1) + gx0 + k]
                - integ[gy0 * (gw + 1) + gx0 + k] - integ[(gy0 + k) * (gw + 1) + gx0]
            return s0 == k * k
        }

        let pad = k / 2 + kb + 4
        let r2x0 = max(0, r1x0 + minX - pad), r2y0 = max(0, r1y0 + minY - pad)
        let r2x1 = min(w - 1, r1x0 + maxX + pad), r2y1 = min(h - 1, r1y0 + maxY + pad)
        guard r2x1 >= r2x0, r2y1 >= r2y0 else { return false }
        let r2w = r2x1 - r2x0 + 1, r2h = r2y1 - r2y0 + 1
        var ero = [Float](repeating: 0, count: r2w * r2h)
        for oy in 0..<r2h {
            for ox in 0..<r2w {
                ero[oy * r2w + ox] = allWhite(r2x0 + ox, r2y0 + oy) ? 255 : 0
            }
        }

        // ③ 糊＋混合
        let alpha = gaussSep(ero, r2w, r2h, gauss1d(2 * kb + 1))
        let plane = s * s
        for oy in 0..<r2h {
            let Y = r2y0 + oy
            for ox in 0..<r2w {
                let al = Double(alpha[oy * r2w + ox]) / 255.0
                if al <= 0 { continue }
                let X = r2x0 + ox
                let fx = fwd.a * Double(X) + fwd.b * Double(Y) + fwd.c
                let fy = fwd.d * Double(X) + fwd.e * Double(Y) + fwd.f
                let o = Y * rowPix * 4 + X * 4
                for ch in 0..<3 {
                    // 内存是 BGRA，模型的 planar 是 RGB：第 0 通道 R 落在内存的第 2 格
                    let fake = Double(planarTap(face, plane, s, fx, fy, 2 - ch))
                    let mix = al * fake * 255.0 + (1 - al) * Double(q[o + ch])
                    // PC 收的是 np.clip(out,0,255).astype(np.uint8)＝截断不是四舍五入，照它的来
                    q[o + ch] = UInt8(max(0.0, min(255.0, mix)).rounded(.down))
                }
            }
        }
        return true
    }

    /// 白图投回来：落在 128 方块里的邻按双线性权重相加再乘 255（方块外那一份就是 borderValue=0）
    private static func whiteTap(_ fx: Double, _ fy: Double) -> Double {
        let lim = Double(side128) - 1
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let dx = fx - Double(x0), dy = fy - Double(y0)
        var sum = 0.0
        for (ox, wx) in [(x0, 1 - dx), (x0 + 1, dx)] {
            for (oy, wy) in [(y0, 1 - dy), (y0 + 1, dy)] {
                if ox >= 0 && oy >= 0 && Double(ox) <= lim && Double(oy) <= lim { sum += wx * wy }
            }
        }
        return sum * 255.0
    }

    /// 补丁 planar 数组的双线性取样，越界那一邻补 0（＝cv2 的 borderValue=0）
    private static func planarTap(_ f: [Float], _ plane: Int, _ s: Int, _ fx: Double, _ fy: Double,
                                  _ ch: Int) -> Float {
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let dx = Float(fx - Double(x0)), dy = Float(fy - Double(y0))
        let b = ch * plane
        func v(_ xx: Int, _ yy: Int) -> Float {
            guard xx >= 0, yy >= 0, xx < s, yy < s else { return 0 }
            return f[b + yy * s + xx]
        }
        let top = v(x0, y0) + (v(x0 + 1, y0) - v(x0, y0)) * dx
        let bot = v(x0, y0 + 1) + (v(x0 + 1, y0 + 1) - v(x0, y0 + 1)) * dx
        return top + (bot - top) * dy
    }

    /// cv2.getGaussianKernel(ksize, 0)：σ 由核长现算＝0.3*((k-1)*0.5-1)+0.8，核就是这一串归一化高斯
    static func gauss1d(_ ksize: Int) -> [Double] {
        var ks = max(1, ksize)
        if ks % 2 == 0 { ks += 1 }
        let sigma = 0.3 * (Double(ks - 1) * 0.5 - 1.0) + 0.8
        let r = ks / 2
        var w = [Double](repeating: 0, count: ks)
        var tot = 0.0
        for i in 0..<ks {
            let x = Double(i - r)
            w[i] = exp(-0.5 * (x / sigma) * (x / sigma))
            tot += w[i]
        }
        for i in 0..<ks { w[i] /= tot }
        return w
    }

    /// 可分离高斯＋BORDER_REFLECT_101（-1→1 那种翻法，不复制边缘）。
    /// 只在 ROI 上糊：ROI 外那一圈腐完本来就是 0，翻边翻到的也是 0，跟整幅糊同一个结果。
    private static func gaussSep(_ a: [Float], _ w0: Int, _ h0: Int, _ k: [Double]) -> [Float] {
        let r = k.count / 2
        var tmp = [Float](repeating: 0, count: w0 * h0)
        for y in 0..<h0 {
            for x in 0..<w0 {
                var s = 0.0
                for i in 0..<k.count { s += k[i] * Double(a[y * w0 + refl101(x + i - r, w0)]) }
                tmp[y * w0 + x] = Float(s)
            }
        }
        var out = [Float](repeating: 0, count: w0 * h0)
        for y in 0..<h0 {
            for x in 0..<w0 {
                var s = 0.0
                for i in 0..<k.count { s += k[i] * Double(tmp[refl101(y + i - r, h0) * w0 + x]) }
                out[y * w0 + x] = Float(s)
            }
        }
        return out
    }

    private static func refl101(_ i: Int, _ n: Int) -> Int {
        if i >= 0 && i < n { return i }
        if i < 0 { return -i }
        return 2 * n - 2 - i
    }

    // MARK: - 一帧的账：5 点 → 两份正向矩阵＋手性＋残差

    struct Placed {
        let fwd112: M23      // 整幅 → 112（身份证）
        let fwd128: M23      // 整幅 → 128（补丁；回贴用的就是这一份的正向，它的逆把补丁投回帧空间）
        let pts: [CGPoint]
        let src: String      // 点位来路：真点位／框猜
        let shortSide: Double
        let mirrored: Bool
        let chir: (nose: Double, mouth: Double)
        let resid128: Double // 5 点映进 128 后离模板的平均距离，单位＝128 方块里的像素
        let residPx: Double  // 同一件事折回原图像素
        let scale: Double    // 拟合的缩放（＝√det）
    }

    /// 眼轴×鼻位、眼轴×嘴角中点这两把叉。
    /// 相似拟合不会把点位映反（它只给一个转正的最优解），y 口径判错时 5 个点是真被翻了面的，只有手性认得出来。
    /// 用叉积而不是「5 点围成多边形的有向面积」：后者是两大块相消，抬头低头到 45° 就翻号，会把姿态当成镜像挡掉。
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

    /// 5 个像素点 → 这一条链路要的整帧产物。点不够 5 个、拟合退化、映不出逆，都返回 nil＝这帧不换。
    static func place(pts: [CGPoint], src: String, shortSide: Double) -> Placed? {
        guard pts.count == 5, let both = align(pts) else { return nil }
        let tpl = templateFor(side128)
        let c = chirality(pts), t = chirality(tpl)
        let mir = c.nose * t.nose < 0 || c.mouth * t.mouth < 0
        var sum = 0.0
        for i in 0..<5 {
            let px = Double(pts[i].x), py = Double(pts[i].y)
            let qx = both.fwd128.a * px + both.fwd128.b * py + both.fwd128.c
            let qy = both.fwd128.d * px + both.fwd128.e * py + both.fwd128.f
            let dx = qx - Double(tpl[i].x), dy = qy - Double(tpl[i].y)
            sum += (dx * dx + dy * dy).squareRoot()
        }
        let resid = sum / 5.0
        let det = both.fwd128.a * both.fwd128.e - both.fwd128.b * both.fwd128.d
        guard det > 1e-9 else { return nil }
        let sc = det.squareRoot()
        return Placed(fwd112: both.fwd112, fwd128: both.fwd128, pts: pts, src: src,
                      shortSide: shortSide, mirrored: mir, chir: c,
                      resid128: resid, residPx: sc > 1e-9 ? resid / sc : 999.0, scale: sc)
    }

    // MARK: - 128 → 112（身份复测要把贴完的补丁再送一次向量网）


    /// 双线性缩小（PC 是 cv2.resize(...,(112,112))，默认 INTER_LINEAR，半像素口径）
    static func resizePlanar(_ src: [Float], from: Int, to: Int, into dst: inout [Float]) {
        let sp = from * from, dp = to * to
        guard src.count >= 3 * sp, dst.count >= 3 * dp else { return }
        let sc = Double(from) / Double(to)
        for plane in 0..<3 {
            for oy in 0..<to {
                let fy = (Double(oy) + 0.5) * sc - 0.5
                let y0 = max(0, min(from - 1, Int(floor(fy))))
                let y1 = max(0, min(from - 1, y0 + 1))
                let wy = Float(max(0.0, min(1.0, fy - Double(y0))))
                for ox in 0..<to {
                    let fx = (Double(ox) + 0.5) * sc - 0.5
                    let x0 = max(0, min(from - 1, Int(floor(fx))))
                    let x1 = max(0, min(from - 1, x0 + 1))
                    let wx = Float(max(0.0, min(1.0, fx - Double(x0))))
                    let a = src[plane * sp + y0 * from + x0], b = src[plane * sp + y0 * from + x1]
                    let c = src[plane * sp + y1 * from + x0], d = src[plane * sp + y1 * from + x1]
                    let top = a + (b - a) * wx
                    dst[plane * dp + oy * to + ox] = top + ((c + (d - c) * wx) - top) * wy
                }
            }
        }
    }

    /// 给自己看的判据（CI 里编成命令行跑）：
    /// ① 这一份模板必须逐点等于 insightface 官方 REFERENCE_FACIAL_POINTS（x 各 +8 是官方 preprocess 那一格）
    ///    ×size/112——旧那条线在手机上验过的就是这一组点，同一个模板才对得上同一套 Vision 点位；
    /// ② 映出去再映回来必须回到原地（逆矩阵那式没写反）；
    /// ③ 腐蚀/糊那两档的取整口径（mask_size 100 时 k=10、kb=5）钉住，改式子就会被这里抓到。
    static func selfTest() -> String {
        let official: [(Double, Double)] = [(30.29459953, 51.69630051), (65.53179932, 51.50139999),
                                            (48.02519989, 71.73660278), (33.54930115, 92.3655014),
                                            (62.72990036, 92.20410156)]
        let t224 = templateFor(224)
        var worst = 0.0
        for i in 0..<5 {
            worst = max(worst, abs(t224[i].x - (official[i].0 + 8) * 2), abs(t224[i].y - official[i].1 * 2))
        }
        let pts: [CGPoint] = [CGPoint(x: 38, y: 52), CGPoint(x: 74, y: 51), CGPoint(x: 56, y: 72),
                              CGPoint(x: 42, y: 92), CGPoint(x: 71, y: 92)]
        guard let m = fit(pts, templateFor(128)), let im = inverse(m) else { return "拟合失败" }
        let u = m.a * 50 + m.b * 60 + m.c, v = m.d * 50 + m.e * 60 + m.f
        let bx = im.a * u + im.b * v + im.c, by = im.d * u + im.e * v + im.f
        let round = max(abs(bx - 50), abs(by - 60))
        let ms = 100
        let gate = (max(ms / 10, 10) == 10 && max(ms / 20, 5) == 5 && gauss1d(11).count == 11)
        return "模板 224 与官方那份最大差 \(String(format: "%.6f", worst))｜往返残差 \(String(format: "%.9f", round))"
            + "｜腐蚀糊两档 \(gate ? "对" : "错")"
    }
}
