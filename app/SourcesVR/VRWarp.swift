import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreML
import Metal

/// Swift 侧的 VRP，字段顺序和 Shaders.metal 里那个 struct 一字不差（44 字节，全 4 字节对齐）。
struct VRParams {
    var W: UInt32 = 0
    var H: UInt32 = 0
    var MW: UInt32 = 0
    var MH: UInt32 = 0
    var scale: Float = 1
    var ox: Float = 0
    var oy: Float = 0
    var zp: Float = 0
    var budget: Float = 0
    var SW: UInt32 = 0
    var rot: UInt32 = 0
}

extension VRTech {
    static var currentCommand: MTLCommandBuffer?

    /// 起一个 compute encoder：纹理按 texture(i) 绑、参数按 constant buffer(0) 绑、
    /// 其余 MTLBuffer 按给的 index 绑，8 的倍数铺满 grid。已经有开着的 commandBuffer 就搭进去，
    /// 由调用方在几个 pass 都编完之后 commitWait()——pass 之间必须严格串行（后一趟读前一趟写的 z 缓冲）。
    static func encode(_ name: String, textures: [MTLTexture], params: VRParams,
                       buffers: [(Int, MTLBuffer)], width: Int, height: Int) -> MTLComputeCommandEncoder? {
        guard let pipe = libs[name] else { return nil }
        // 一次形变要 4 个 pass，必须串在同一个 commandBuffer 里：
        // 每趟各开一个的话，除了第一趟以外都没人 commit，等于后面三趟压根没跑。
        let cmd: MTLCommandBuffer
        if let open = currentCommand {
            cmd = open
        } else {
            guard let fresh = queue?.makeCommandBuffer() else { return nil }
            currentCommand = fresh
            cmd = fresh
        }
        guard let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(pipe)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        var p = params
        enc.setBytes(&p, length: MemoryLayout<VRParams>.stride, index: 0)
        for b in buffers { enc.setBuffer(b.1, offset: 0, index: b.0) }
        let tg = max(4, pipe.maxTotalThreadsPerThreadgroup)
        let side = max(1, min(8, Int(Double(tg).squareRoot())))
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: min(side, width),
                                                           height: min(side, height), depth: 1))
        return enc
    }

    static func commitWait() {
        if let cmd = currentCommand {
            cmd.commit()
            cmd.waitUntilCompleted()
            currentCommand = nil
        }
        // 等完才放：这批纹理还在刚才那条 commandBuffer 里被引用着
        keep.removeAll()
    }
}

/// 眼尺寸的帧 → 送检尺寸（等比 + 黑边），然后 predict，把深度按眼格摊平回来。
final class VRDepthFeed {
    let model: MLModel
    let eyeW: Int
    let eyeH: Int
    let rot: Bool
    let mw: Int
    let mh: Int
    let scale: Float
    let ox: Float
    let oy: Float
    /// 画面在送检框里真正占掉的像素数（两种朝向唯一被这个开关改变的量）
    let usedPx: Int
    let inputName: String
    let inputPB: CVPixelBuffer
    let inputTex: MTLTexture
    /// inputTex 的命根子：commitWait 会清公共 keep 表，跨帧的这块必须自己按住
    let inputCv: CVMetalTexture
    private var map: [Int] = []
    /// 同一张表但故意不做旋转修正：给「朝向自证」当地板读数（逆映射漏掉转 90° 就长这样）
    private var mapMis: [Int] = []
    private var mapForW = 0
    private var mapForH = 0

    init?(model: MLModel, eyeW: Int, eyeH: Int, mw: Int, mh: Int, rot: Bool, note: inout String) {
        self.model = model
        self.eyeW = eyeW
        self.eyeH = eyeH
        self.mw = mw
        self.mh = mh
        self.rot = rot
        inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        // 等比塞进送检框：取两方向里小的那个比例，剩下留黑边——拉伸会把深度也拉歪。
        // rot 时进框的是「转过 90° 的那张」，所以宽高在这一步就要换过来。
        let lw = rot ? Float(eyeH) : Float(eyeW)
        let lh = rot ? Float(eyeW) : Float(eyeH)
        let s = min(Float(mw) / lw, Float(mh) / lh)
        scale = s
        ox = (Float(mw) - lw * s) / 2.0
        oy = (Float(mh) - lh * s) / 2.0
        usedPx = Int(lw * s) * Int(lh * s)
        let mk = VRTech.pixelBuffer(width: mw, height: mh)
        guard let pb = mk.pb else { note = "造送检像素缓冲失败: \(mk.note)"; return nil }
        inputPB = pb
        let got = VRTech.texture(from: pb, width: mw, height: mh)
        guard let tex = got.tex, let cv = got.cv else {
            note = "送检像素缓冲转纹理失败: \(got.note)"; return nil
        }
        inputTex = tex
        inputCv = cv
    }

    /// 一帧：kScale 画进送检框 → CoreML → 输出平面按眼格重采样
    func infer(srcPB: CVPixelBuffer) -> (raw: [Float], ms: (prep: Double, predict: Double),
                                         plane: VRPlane.Out, err: String?) {
        let got = VRTech.texture(from: srcPB, width: eyeW, height: eyeH)
        guard let srcTex = got.tex else {
            return ([], (0, 0), VRPlane.Out(), "帧纹理建不出来: \(got.note)")
        }
        var p = VRParams()
        p.W = UInt32(eyeW); p.H = UInt32(eyeH)
        p.MW = UInt32(mw); p.MH = UInt32(mh)
        p.scale = scale; p.ox = ox; p.oy = oy
        p.rot = rot ? 1 : 0
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let enc = VRTech.encode("kScale", textures: [srcTex, inputTex],
                                      params: p, buffers: [], width: mw, height: mh) else {
            return ([], (0, 0), VRPlane.Out(), "kScale 没编出来")
        }
        enc.endEncoding()
        VRTech.commitWait()
        let prepMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000

        let t1 = DispatchTime.now().uptimeNanoseconds
        do {
            let feed = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(pixelBuffer: inputPB)])
            let res = try model.prediction(from: feed)
            let key = model.modelDescription.outputDescriptionsByName.keys.first ?? "depth"
            guard let v = res.featureValue(for: key) else {
                return ([], (prepMs, 0), VRPlane.Out(), "输出 \(key) 取不到值")
            }
            let plane: VRPlane.Out
            if let pb = v.imageBufferValue {
                plane = VRPlane.read(pb)
            } else if let arr = v.multiArrayValue {
                plane = VRPlane.fromArray(arr)
            } else {
                return ([], (prepMs, 0), VRPlane.Out(), "输出 \(key) 既不是图也不是多数组（类型 \(v.type.rawValue)）")
            }
            let pms = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000
            return (resample(plane), (prepMs, pms), plane, plane.note.isEmpty ? nil : plane.note)
        } catch {
            return ([], (prepMs, 0), VRPlane.Out(), "predict 抛错: \(error)")
        }
    }

    /// 深度图（连黑边那圈一起）→ 眼格：只在深度图尺寸变了时重建索引表
    private func resample(_ plane: VRPlane.Out) -> [Float] {
        guard plane.w > 0, plane.h > 0, !plane.vals.isEmpty else { return [] }
        if mapForW != plane.w || mapForH != plane.h || map.count != eyeW * eyeH {
            buildMap(dw: plane.w, dh: plane.h)
        }
        let v = plane.vals
        var out = [Float](repeating: 0, count: eyeW * eyeH)
        for i in 0..<(eyeW * eyeH) { out[i] = v[map[i]] }
        return out
    }

    /// 深度图 → 眼格，但走那张「不做旋转修正」的表：只为给朝向自证一个地板读数
    func resampleMis(_ plane: VRPlane.Out) -> [Float] {
        guard plane.w > 0, plane.h > 0, !plane.vals.isEmpty else { return [] }
        if mapForW != plane.w || mapForH != plane.h || map.count != eyeW * eyeH {
            buildMap(dw: plane.w, dh: plane.h)
        }
        let v = plane.vals
        var out = [Float](repeating: 0, count: eyeW * eyeH)
        for i in 0..<(eyeW * eyeH) { out[i] = v[mapMis[i]] }
        return out
    }

    private func buildMap(dw: Int, dh: Int) {
        map = [Int](repeating: 0, count: eyeW * eyeH)
        mapMis = [Int](repeating: 0, count: eyeW * eyeH)
        mapForW = dw; mapForH = dh
        let kx = Float(dw) / Float(mw)
        let ky = Float(dh) / Float(mh)
        // rot 时画布那一行的来源是「眼列」，原来把 dy 提到行外的省法就不成立了；
        // 这张表整轮只建一次（深度图尺寸不变就不重来），所以这不花钱。
        for y in 0..<eyeH {
            for x in 0..<eyeW {
                let cx = rot ? Float(eyeH - 1 - y) : Float(x)
                let cy = rot ? Float(x) : Float(y)
                var dx = Int((ox + (cx + 0.5) * scale) * kx)
                var dy = Int((oy + (cy + 0.5) * scale) * ky)
                if dx < 0 { dx = 0 }
                if dx > dw - 1 { dx = dw - 1 }
                if dy < 0 { dy = 0 }
                if dy > dh - 1 { dy = dh - 1 }
                map[y * eyeW + x] = dy * dw + dx
                // 地板：同一个眼格，逆映射里漏掉转回 90° 会取到哪儿
                var mx2 = Int((ox + (Float(x) + 0.5) * scale) * kx)
                var my2 = Int((oy + (Float(y) + 0.5) * scale) * ky)
                if mx2 < 0 { mx2 = 0 }
                if mx2 > dw - 1 { mx2 = dw - 1 }
                if my2 < 0 { my2 = 0 }
                if my2 > dh - 1 { my2 = dh - 1 }
                mapMis[y * eyeW + x] = my2 * dw + mx2
            }
        }
    }
}

/// Metal 侧的一帧形变：4 个 pass（后向+清 z／前向占格／前向写色／合洞数洞）。
final class VRWarp {
    let eyeW: Int
    let eyeH: Int
    let sbsW: Int
    let budget: Float
    let fbL: MTLTexture
    let fbR: MTLTexture
    let bestL: MTLBuffer
    let bestR: MTLBuffer
    let dnBuf: MTLBuffer
    let holesBuf: MTLBuffer

    init?(eyeW: Int, eyeH: Int, bpct: Float, note: inout String) {
        guard let dev = VRTech.device else { note = "没有 Metal 设备"; return nil }
        self.eyeW = eyeW
        self.eyeH = eyeH
        sbsW = eyeW * 2
        budget = Float(eyeW) * bpct / 100.0
        func makeTex(_ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                             width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            return dev.makeTexture(descriptor: d)
        }
        guard let l = makeTex(eyeW, eyeH), let r = makeTex(eyeW, eyeH) else {
            note = "fbL/fbR 纹理建不出来"; return nil
        }
        fbL = l; fbR = r
        let px = eyeW * eyeH
        guard let b1 = dev.makeBuffer(length: px * 4, options: .storageModeShared),
              let b2 = dev.makeBuffer(length: px * 4, options: .storageModeShared),
              let b3 = dev.makeBuffer(length: px * 4, options: .storageModeShared),
              let b4 = dev.makeBuffer(length: 4, options: .storageModeShared) else {
            note = "z 缓冲/深度/计数器 buffer 建不出来"; return nil
        }
        bestL = b1; bestR = b2; dnBuf = b3; holesBuf = b4
        memset(b1.contents(), 0, px * 4)
        memset(b2.contents(), 0, px * 4)
        memset(b4.contents(), 0, 4)
    }

    /// 一帧。dn 是已归一化到 0..1 的眼格深度；outPB 是 2W×H 的 BGRA 像素缓冲（成片的这一帧）。
    func render(srcPB: CVPixelBuffer, dn: [Float], zp: Float, outPB: CVPixelBuffer)
        -> (upload: Double, gpu: Double, holes: Double, err: String?) {
        let sg = VRTech.texture(from: srcPB, width: eyeW, height: eyeH)
        let og = VRTech.texture(from: outPB, width: sbsW, height: eyeH)
        guard let srcTex = sg.tex, let outTex = og.tex else {
            return (0, 0, 0, "帧或成片纹理建不出来（源 \(sg.note)｜成片 \(og.note)）")
        }
        let px = eyeW * eyeH
        guard dn.count == px else { return (0, 0, 0, "深度数组 \(dn.count) 与眼格 \(px) 不符") }
        var p = VRParams()
        p.W = UInt32(eyeW); p.H = UInt32(eyeH)
        p.MW = UInt32(eyeW); p.MH = UInt32(eyeH)
        p.zp = zp; p.budget = budget
        p.SW = UInt32(sbsW)

        let t0 = DispatchTime.now().uptimeNanoseconds
        dn.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(dnBuf.contents(), base, px * 4) }
        }
        let uploadMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000

        let t1 = DispatchTime.now().uptimeNanoseconds
        let shared: [(Int, MTLBuffer)] = [(1, bestL), (2, bestR), (3, dnBuf)]
        let passes: [(String, [MTLTexture], [(Int, MTLBuffer)])] = [
            ("kBack", [srcTex, fbL, fbR], shared),
            ("kSplatDepth", [], shared),
            ("kSplatColor", [srcTex, outTex], shared),
            ("kCombine", [fbL, fbR, outTex], shared + [(4, holesBuf)]),
        ]
        for one in passes {
            guard let enc = VRTech.encode(one.0, textures: one.1, params: p,
                                          buffers: one.2, width: eyeW, height: eyeH) else {
                // 开在半路的 commandBuffer 不能留给下一帧：它的 encoder 已经没了
                VRTech.currentCommand = nil
                VRTech.keep.removeAll()
                return (uploadMs, 0, 0, "\(one.0) 没编出来")
            }
            enc.endEncoding()
        }
        VRTech.commitWait()
        let gpuMs = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000
        let slot = holesBuf.contents().assumingMemoryBound(to: UInt32.self)
        let h = slot.pointee
        slot.pointee = 0
        let pct = Double(h) / Double(px * 2) * 100.0
        return (uploadMs, gpuMs, pct, nil)
    }
}

extension VRPlane {
    /// 万一这个包给的是多数组而不是图像：按最后两维当 h、w，用 strides 属性逐格读。
    /// （MLMultiArray 没有 stride(for:) 这个方法，只有 strides: [NSNumber]，单位是"元素个数"不是字节。）
    static func fromArray(_ arr: MLMultiArray) -> Out {
        var o = Out()
        let n = arr.shape.count
        guard n >= 2 else {
            o.note = "多数组维数 \(arr.shape.map { $0.intValue })：不足两维"
            return o
        }
        let isF32 = arr.dataType == .float32
        let isF16 = arr.dataType == .float16
        guard isF32 || isF16 else {
            o.note = "多数组类型 \(arr.dataType.rawValue)：还只会读 float32/float16"
            return o
        }
        let h = arr.shape[n - 2].intValue
        let w = arr.shape[n - 1].intValue
        let st = arr.strides
        guard st.count >= n else {
            o.note = "strides 只有 \(st.count) 项，维数 \(n) 对不上"
            return o
        }
        let sy = st[n - 2].intValue
        let sx = st[n - 1].intValue
        o.w = w; o.h = h; o.bpp = isF32 ? 4 : 2; o.fourcc = "ARR"
        o.vals = [Float](repeating: 0, count: w * h)
        func put(_ x: Int, _ y: Int, _ v: Float) {
            o.vals[y * w + x] = v
            if v < o.min { o.min = v }
            if v > o.max { o.max = v }
        }
        if isF32 {
            let p = arr.dataPointer.assumingMemoryBound(to: Float32.self)
            for y in 0..<h {
                for x in 0..<w { put(x, y, p[y * sy + x * sx]) }
            }
        } else {
            let p = arr.dataPointer.assumingMemoryBound(to: Float16.self)
            for y in 0..<h {
                for x in 0..<w { put(x, y, Float(p[y * sy + x * sx])) }
            }
        }
        return o
    }
}
