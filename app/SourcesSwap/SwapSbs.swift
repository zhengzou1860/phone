import CoreVideo
import Foundation

/// 预览全屏那一档的左右眼：把一帧单眼画面铺成宽两倍的「左半＋右半」，塞进眼镜里看。
///
/// 换算与 iPhone VR 那条完全同源（`.wt-vr3d` 播放上屏的 `kSbsShift`／`kSbsFish`），只是这里在 CPU 上算：
/// 预览本来就三格一秒、钱全在换脸网那 130 ms 上，这一趟 1280×358 ≈ 0.46 Mpx 摊得起，
/// 也省得为它另搭一套 Metal 与上屏层。深度视差那一条（VRDepth／VRWarp 的 DIBR）不在这儿——
/// 两只眼读的是同一幅画面，不各算一遍；VR3D 自己从 0.29 起那条实时线也不跑深度。
///
/// 三个控件的意思、上下限、默认值都跟那边对齐，连词也一样：
/// - 一起移＝两只眼同方向水平挪（对镜片中心用），±12% 每眼宽封顶；
/// - 间距＝把两张图互相推远或拉近，图本身大小不变（＋ 拉开、中缝出黑边；− 靠近、外侧各裁一条），±25% 封顶；
/// - 鱼眼＝把每只眼那半幅按镜片的桶形弯一遍：画面外圈挤向中心，直边的中段就往外弓，
///   黑只落在画框外，源图一个像素都不裁（0＝不弯＝手持直看；顶格黑边最厚），0~1，没存过默认 0.35。
enum SwapSbs {
    static let shiftRange: Double = 0.12
    static let gapRange: Double = 0.25
    static let fishMax: Double = 1.0
    static let fishDefault: Double = 0.35

    /// 三个数各存各的：镜片间距与弯度是硬件定的，一次对好就一直用
    static let shiftKey = "swap.sbs.shift"
    static let gapKey = "swap.sbs.gap"
    static let fishKey = "swap.sbs.fish"

    struct Cfg {
        var shiftPct: Double
        var gapPct: Double
        var fishPct: Double
    }

    /// 展一帧到调用方给的那块 2w×h 缓冲里：源是一整幅单眼 BGRA ⇒ 两只眼都从第 0 列起读同一幅
    /// （对应 kernel 里 `mono` 那一支）。返回空串＝成；不然是「为什么没成」，调用方照原样递单眼那一幅。
    /// 缓冲由调用方攒着重复用：这一趟三格一秒，每格新造一块 1.8 MB 的 IOSurface 没道理。
    static func expand(_ src: CVPixelBuffer, _ c: Cfg, into dst: CVPixelBuffer) -> String {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        guard CVPixelBufferGetWidth(dst) == w * 2, CVPixelBufferGetHeight(dst) == h else {
            return "左右眼缓冲尺寸对不上（\(CVPixelBufferGetWidth(dst))x\(CVPixelBufferGetHeight(dst)) 要 \(w * 2)x\(h)）"
        }
        guard w >= 2, h >= 2 else { return "源那一格 \(w)x\(h) 太小，弯不了" }
        guard CVPixelBufferLockBaseAddress(src, .readOnly) == kCVReturnSuccess else {
            return "源缓冲锁不上（只读）"
        }
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        guard CVPixelBufferLockBaseAddress(dst, []) == kCVReturnSuccess else {
            return "左右眼缓冲锁不上"
        }
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }
        guard let sBase = CVPixelBufferGetBaseAddress(src),
              let dBase = CVPixelBufferGetBaseAddress(dst) else {
            return "拿不到基址"
        }
        let sr = CVPixelBufferGetBytesPerRow(src), dr = CVPixelBufferGetBytesPerRow(dst)
        let sp = sBase.assumingMemoryBound(to: UInt8.self)
        let dp = dBase.assumingMemoryBound(to: UInt8.self)

        let wf = Double(w), hf = Double(h)
        let hw = wf / 2.0, hh = hf / 2.0
        // 送进换算的三个数与 VR3D 一致：位移／间距按每眼宽折成像素，鱼眼强度翻倍（kernel 里那个 k）
        let xoff = min(max(c.shiftPct, -shiftRange), shiftRange) * wf
        let gap = min(max(c.gapPct, -gapRange), gapRange) * wf
        let fish = 2.0 * min(max(c.fishPct, 0), fishMax)
        // R＝半幅对角的一半：源图角点正好归一到 1，所以界外只落在画框外那一圈
        let r2 = 0.25 * (wf * wf + hf * hf)

        if fish <= 0 {
            // 不弯：整数照搬。这里要是用线性采样，半幅边界那半格会取到对面那只眼
            for gy in 0..<h {
                let srow = gy * sr, drow = gy * dr
                for gx in 0..<(2 * w) {
                    let left = gx < w
                    let sh = Int((xoff + (left ? -gap : gap)).rounded())
                    let lx = (gx - (left ? 0 : w)) - sh
                    let d = dp.advanced(by: drow + gx * 4)
                    if lx < 0 || lx >= w {
                        d.assign(repeating: 0, count: 4)     // 腾出来的那一头留纯黑
                    } else {
                        memcpy(d, sp.advanced(by: srow + lx * 4), 4)
                    }
                }
            }
        } else {
            for gy in 0..<h {
                let dy = Double(gy) + 0.5 - hh
                let drow = gy * dr
                for gx in 0..<(2 * w) {
                    let left = gx < w
                    let sh = Int((xoff + (left ? -gap : gap)).rounded())
                    let dx = Double((gx - (left ? 0 : w)) - sh) + 0.5 - hw
                    let sc = 1.0 + fish * (dx * dx + dy * dy) / r2
                    let sx = dx * sc + hw
                    let sy = dy * sc + hh
                    let d = dp.advanced(by: drow + gx * 4)
                    // 出界判的是自家那一幅的 0.5~w-0.5：贴着中缝的半格若交给插值，会咬进对面那只眼
                    guard sx >= 0.5, sx <= wf - 0.5, sy >= 0.5, sy <= hf - 0.5 else {
                        d.assign(repeating: 0, count: 4)
                        continue
                    }
                    let fx = sx - 0.5, fy = sy - 0.5
                    let x0 = min(max(Int(fx), 0), w - 2), y0 = min(max(Int(fy), 0), h - 2)
                    let u = fx - Double(x0), v = fy - Double(y0)
                    let a = y0 * sr + x0 * 4, b = a + sr
                    for k in 0..<4 {
                        let p0 = Double(sp[a + k]) * (1 - u) + Double(sp[a + 4 + k]) * u
                        let p1 = Double(sp[b + k]) * (1 - u) + Double(sp[b + 4 + k]) * u
                        d[k] = UInt8((p0 * (1 - v) + p1 * v).rounded())
                    }
                }
            }
        }
        return ""
    }
}
