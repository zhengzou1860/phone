import Foundation
import CoreVideo
import Metal

/// 上机第一件事不靠肉眼、不靠文档：两条自证。
/// 1) 色彩往返 —— BGRA 进 GPU 再出来，字节是不是原样回来（整条链对通道序必须是无感的）。
/// 2) 白线实验 —— 造一根白竖线和一张"只有这根线靠前"的深度，看它在左眼落到右边、
///    在右眼落到左边，原位被后向 remap 填成暗。方向反了、L/R 接反了、z 缓冲比错了、
///    合洞没接上，这一条会当场指着具体格子说不符，不用等戴镜片头晕才发现。
enum VRCheck {

    /// 往 BGRA 像素缓冲里逐字节写：第 i 个字节由 (x,y,i) 算出来
    private static func fill(_ pb: CVPixelBuffer, _ gen: (Int, Int, Int) -> UInt8) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                for i in 0..<4 { p[y * bpr + x * 4 + i] = gen(x, y, i) }
            }
        }
    }

    /// 读一定在锁里读完：基地址只在 lockBaseAddress 到 unlock 之间有效，
    /// 把指针带出锁外就是拿一个随时可能失效的地址。
    private static func peek<T>(_ pb: CVPixelBuffer, _ body: (_ p: UnsafeMutablePointer<UInt8>,
        _ bpr: Int, _ w: Int, _ h: Int) -> T) -> T? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        return body(base.assumingMemoryBound(to: UInt8.self),
                    CVPixelBufferGetBytesPerRow(pb),
                    CVPixelBufferGetWidth(pb),
                    CVPixelBufferGetHeight(pb))
    }

    /// 两块一起比：两份基地址都只能在两把锁都还握着的时候读，所以比较必须整个塞进 body 里。
    private static func peek2<T>(_ a: CVPixelBuffer, _ b: CVPixelBuffer,
        _ body: (_ pa: UnsafeMutablePointer<UInt8>, _ bpa: Int,
                 _ pb: UnsafeMutablePointer<UInt8>, _ bpb: Int,
                 _ w: Int, _ h: Int) -> T) -> T? {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        guard let ba = CVPixelBufferGetBaseAddress(a), let bb = CVPixelBufferGetBaseAddress(b) else { return nil }
        return body(ba.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRow(a),
                    bb.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRow(b),
                    CVPixelBufferGetWidth(a), CVPixelBufferGetHeight(a))
    }

    static func colorRoundTrip(width: Int = 64, height: Int = 24) -> String {
        guard VRTech.boot() else { return "Metal 起不来：\(VRTech.initNote)" }
        VRTech.gate.lock()
        defer { VRTech.gate.unlock() }
        let a = VRTech.pixelBuffer(width: width, height: height)
        let b = VRTech.pixelBuffer(width: width, height: height)
        guard let pa = a.pb, let pb = b.pb else { return "造像素缓冲失败：\(a.note)｜\(b.note)" }
        // 每像素四个字节都错开：通道序要是一换，对账一定露出来
        fill(pa) { x, y, i in UInt8((x &* 7 + y &* 31 + i &* 97) & 0xFF) }
        fill(pb) { _, _, _ in 0 }
        let ta = VRTech.texture(from: pa, width: width, height: height)
        let tb = VRTech.texture(from: pb, width: width, height: height)
        guard let srcT = ta.tex, let dstT = tb.tex else {
            return "往返自检的纹理建不出来：\(ta.note)｜\(tb.note)"
        }
        var p = VRParams()
        p.W = UInt32(width); p.H = UInt32(height)
        guard let enc = VRTech.encode("kCopy", textures: [srcT, dstT], params: p,
                                      buffers: [], width: width, height: height) else {
            return "kCopy 没编出来（Shaders.metal 进包了吗？）"
        }
        enc.endEncoding()
        VRTech.commitWait()
        var result = "读不出基地址"
        let cmp = peek2(pa, pb) { A, bpa, B, bpb, w, h in
            var diff = 0
            var first = ""
            for y in 0..<h {
                for x in 0..<w {
                    for i in 0..<4 {
                        let va = A[y * bpa + x * 4 + i]
                        let vb = B[y * bpb + x * 4 + i]
                        if va != vb {
                            diff += 1
                            if first.isEmpty { first = "首个不同 (\(x),\(y)) 字节\(i) 进 \(va) 出 \(vb)" }
                        }
                    }
                }
            }
            return (diff, first)
        }
        if let got = cmp {
            let n = width * height * 4
            if got.0 == 0 {
                result = "色彩往返 \(width)x\(height) 共 \(n) 字节逐字节一致 ⇒ 这条 GPU 链对 BGRA 是无感的"
            } else {
                result = "色彩往返 \(n) 字节里 \(got.0) 个不同｜\(got.1)"
                    + "｜⇒ 通道序或精度在中间被动过，正式管线前必须先弄清"
            }
        }
        return result
    }

    /// 白线实验。约定：dn>zp 表示"比屏幕靠前"，左眼 dest=x+dd、右眼 dest=x-dd。
    static func warpSmoke() -> String {
        guard VRTech.boot() else { return "白线实验起不来：\(VRTech.initNote)" }
        let W = 100, H = 8, line = 50
        var note = ""
        guard let warp = VRWarp(eyeW: W, eyeH: H, bpct: 8, note: &note) else {
            return "VRWarp 建不起来：\(note)"
        }
        let got = VRTech.pixelBuffer(width: W * 2, height: H)
        guard let out = got.pb else { return "白线实验的输出缓冲造不出来：\(got.note)" }
        let srcGot = VRTech.pixelBuffer(width: W, height: H)
        guard let src = srcGot.pb else { return "白线实验的源帧造不出来：\(srcGot.note)" }
        fill(src) { x, _, _ in x == line ? UInt8(255) : UInt8(0) }
        // 深度：整幅等于 zp ⇒ 别处 dd=0 原地不动；只有那一列推到 1.0 ⇒ dd=(1-zp)*budget
        var dn = [Float](repeating: 0.5, count: W * H)
        for y in 0..<H { dn[y * W + line] = 1.0 }
        let shift = Int(((1.0 - 0.5) * Double(warp.budget)).rounded())
        let r = warp.render(srcPB: src, dn: dn, zp: 0.5, outPB: out)
        if let e = r.err { return "白线实验形变失败：\(e)" }
        var verdict = "白线实验读不出成片"
        if let sum = peek(out, { p, bpr, w, h in (0..<w).map { x in
                Int(p[0 * bpr + x * 4]) + Int(p[0 * bpr + x * 4 + 1]) + Int(p[0 * bpr + x * 4 + 2]) } }) {
            func lum(_ x: Int) -> Int { (x >= 0 && x < sum.count) ? sum[x] : -1 }
            let lMoved = lum(line + shift), rMoved = lum(W + line - shift)
            let lHome = lum(line), rHome = lum(W + line)
            let lOther = lum(line - shift), rOther = lum(W + line + shift)
            var v: [String] = []
            v.append(lMoved > 300 ? "左眼右移 \(shift) px ✓(\(lMoved))" : "左眼没右移 x+\(shift)=\(lMoved) ✗")
            v.append(rMoved > 300 ? "右眼左移 \(shift) px ✓(\(rMoved))" : "右眼没左移 x-\(shift)=\(rMoved) ✗")
            v.append(lOther <= 300 && rOther <= 300 ? "反向无溢出 ✓" : "反向也有一份 左\(lOther)/右\(rOther) ⇒ L/R 或 dd 号接反 ✗")
            v.append(lHome <= 300 && rHome <= 300 ? "原位被填暗 ✓(\(lHome)/\(rHome))" : "原位还亮 \(lHome)/\(rHome) ⇒ 合洞或 z 缓冲没对上 ✗")
            verdict = "白线实验 每眼\(W)x\(H) 视差上限 \(String(format: "%.1f", warp.budget)) px ⇒ 位移 \(shift) px"
                + "｜补洞 \(String(format: "%.2f", r.holes))%（只有那一列该是洞，理论 \(String(format: "%.2f", 100.0 / Double(W)))%）"
                + "｜\(v.joined(separator: "；"))"
        }
        return verdict
    }

    static func all() -> String {
        var out: [String] = ["自检 Metal：\(VRTech.boot() ? "就绪" : "起不来")｜\(VRTech.initNote)"]
        out.append(colorRoundTrip())
        out.append(warpSmoke())
        out.append(VRFacts.modelNote())
        return out.joined(separator: "\n")
    }
}
