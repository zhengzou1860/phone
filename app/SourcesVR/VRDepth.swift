import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreML
import Metal

/// Apple 官方那份 DepthAnythingV2SmallF16 的上机侧。
/// 这里要一次回答三件事：A13 认不认这个包、哪个 compute unit 接、送检尺寸的口径是什么
/// （固定尺寸还是允许范围），以及输出那张"灰度深度图"到底是什么像素布局。
enum VRDepth {
    static let resource = "DepthAnythingV2SmallF16"

    static var cachedURL: (url: URL?, note: String)?

    static func locate() -> (url: URL?, note: String) {
        if let c = cachedURL { return c }
        let fm = FileManager.default
        /// Bundle.url(forResource:withExtension:) 对"一个目录当资源"不保证认，
        /// 所以除它以外再直接按路径摸一遍（CI 是直接把 mlpackage 拷进 .app 的）。
        func dir(_ ext: String) -> URL? {
            if let u = Bundle.main.url(forResource: resource, withExtension: ext) { return u }
            for base in [Bundle.main.bundleURL, Bundle.main.resourceURL].compactMap({ $0 }) {
                let u = base.appendingPathComponent("\(resource).\(ext)")
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { return u }
            }
            return nil
        }
        let found: (url: URL?, note: String)
        if let u = dir("mlmodelc") {
            found = (u, "包里带的是已编译 mlmodelc")
        } else if let u = dir("mlpackage") {
            found = compile(u)
        } else {
            found = (nil, "包里没有 \(resource).mlmodelc 也没有 .mlpackage")
        }
        cachedURL = found
        return found
    }

    /// 设备自己编 mlpackage。文档里同步那条只点名 .mlmodel，带回调那条才是通用的——
    /// 所以先试同步（iOS 11 就有），它抛错再走回调那条，两条的报错都留在报告里，
    /// 上机一眼看出这台 A13 到底认哪条路（认错了整份深度自检就作废，得当场看得见）。
    /// 调用方一律在 Task.detached 里，不是主线程，所以这里可以阻塞等。
    private static func compile(_ u: URL) -> (url: URL?, note: String) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        func sec(_ from0: UInt64) -> String { String(format: "%.1f", Double(from0) / 1_000_000_000) }
        var syncErr = ""
        do {
            let c = try MLModel.compileModel(at: u)
            return (c, "包里是 mlpackage，同步 compileModel 现场编过 \(sec(DispatchTime.now().uptimeNanoseconds - t0)) s")
        } catch {
            syncErr = "\(error)"
        }
        var res: Result<URL, Error>?
        let sem = DispatchSemaphore(value: 0)
        MLModel.compileModel(at: u) { r in
            res = r
            sem.signal()
        }
        if sem.wait(timeout: .now() + 600) == .timedOut {
            return (nil, "同步版抛错（\(syncErr)）；回调版 600 s 没回话")
        }
        if let got = res {
            switch got {
            case let .success(c):
                return (c, "包里是 mlpackage，同步版不接（\(syncErr)）⇒ 回调版编过 \(sec(DispatchTime.now().uptimeNanoseconds - t0)) s")
            case let .failure(e):
                return (nil, "mlpackage 两条编译路都失败｜同步: \(syncErr)｜回调: \(e)")
            }
        }
        return (nil, "mlpackage 回调版没给结果（同步版: \(syncErr)）")
    }

    static func load(_ units: MLComputeUnits) -> (model: MLModel?, ms: Double, note: String) {
        guard let url = locate().url else { return (nil, 0, locate().note) }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            let m = try MLModel(contentsOf: url, configuration: cfg)
            return (m, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000, "-")
        } catch {
            return (nil, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000, "\(error)")
        }
    }

    // MARK: - 模型自述

    static func describe(_ model: MLModel) -> String {
        let md = model.modelDescription
        var out: [String] = []
        for (name, d) in md.inputDescriptionsByName.sorted(by: { $0.key < $1.key }) {
            if let ic = d.imageConstraint {
                let mn = ic.minSize, mx = ic.maxSize
                let range = "\(Int(mn.width.rounded()))x\(Int(mn.height.rounded()))"
                    + "~\(Int(mx.width.rounded()))x\(Int(mx.height.rounded()))"
                let decl = "\(ic.pixelsWide)x\(ic.pixelsHigh)"
                let kinds = ic.supportedCVPixelBufferTypes.count
                out.append("  输入 \(name) image 声明 \(decl)｜允许区间 \(range)｜支持的像素缓冲 \(kinds) 种")
            } else if let mc = d.multiArrayConstraint {
                out.append("  输入 \(name) multiArray dims=\(mc.shape.map { $0.intValue }) 类型 \(mc.dataType.rawValue)")
            } else {
                out.append("  输入 \(name) 类型 \(d.type.rawValue)")
            }
        }
        for (name, d) in md.outputDescriptionsByName.sorted(by: { $0.key < $1.key }) {
            if let ic = d.imageConstraint {
                let decl = "\(ic.pixelsWide)x\(ic.pixelsHigh)"
                let mn = ic.minSize, mx = ic.maxSize
                let range = "\(Int(mn.width.rounded()))x\(Int(mn.height.rounded()))"
                    + "~\(Int(mx.width.rounded()))x\(Int(mx.height.rounded()))"
                out.append("  输出 \(name) image 声明 \(decl)｜区间 \(range)")
            } else if let mc = d.multiArrayConstraint {
                out.append("  输出 \(name) multiArray dims=\(mc.shape.map { $0.intValue }) 类型 \(mc.dataType.rawValue)")
            } else {
                out.append("  输出 \(name) 类型 \(d.type.rawValue)")
            }
        }
        return out.joined(separator: "\n")
    }

    /// 送检尺寸：优先按"短边 shortSide、长边凑 14 的倍数"的等比口径，
    /// 但必须夹在模型自己声明的允许区间里；固定尺寸的模型就退化成那个尺寸（这时靠信箱不拉伸）。
    static func inputTarget(_ model: MLModel, eyeW: Int, eyeH: Int, shortSide: Int)
        -> (w: Int, h: Int, flexible: Bool, note: String) {
        guard let name = model.modelDescription.inputDescriptionsByName.keys.first,
              let ic = model.modelDescription.inputDescriptionsByName[name]?.imageConstraint else {
            return (eyeW, eyeH, false, "输入不是图像，按眼尺寸喂")
        }
        let dw = ic.pixelsWide, dh = ic.pixelsHigh
        let mnW = Int(ic.minSize.width.rounded()), mnH = Int(ic.minSize.height.rounded())
        let mxW = Int(ic.maxSize.width.rounded()), mxH = Int(ic.maxSize.height.rounded())
        let flexible = mxW > mnW || mxH > mnH || (mnW == 0 && mxW == 0)
        if !flexible {
            return (dw, dh, false, "模型只认固定 \(dw)x\(dh) ⇒ 等比塞进去留黑边，不拉伸")
        }
        let want = VRUtil.modelSize(eyeW: eyeW, eyeH: eyeH, short: shortSide,
                                    minW: mnW, minH: mnH, maxW: mxW, maxH: mxH)
        return (want.w, want.h, true,
                "模型允许 \(mnW)x\(mnH)~\(mxW)x\(mxH) ⇒ 本次送检 \(want.w)x\(want.h)（短边 \(shortSide)、长边 14 倍数）")
    }

    // MARK: - 四单元单价

    static func probe(runs: Int, shortSide: Int) -> String {
        var out: [String] = ["深度自检（\(resource)）"]
        let found = locate()
        guard let url = found.url else {
            out.append("  \(found.note)")
            return out.joined(separator: "\n")
        }
        out.append("  \(found.note)｜\(url.lastPathComponent)")
        for unit in [("cpuAndNeuralEngine", MLComputeUnits.cpuAndNeuralEngine),
                     ("cpuAndGPU", MLComputeUnits.cpuAndGPU),
                     ("all", MLComputeUnits.all),
                     ("cpuOnly", MLComputeUnits.cpuOnly)] {
            let got = load(unit.1)
            guard let model = got.model else {
                out.append("  \(unit.0): 加载失败 \(got.note)")
                continue
            }
            out.append("  \(unit.0): 加载 \(VRUtil.ms(got.ms))")
            out.append(describe(model))
            let tgt = inputTarget(model, eyeW: 540, eyeH: 960, shortSide: shortSide)
            out.append("  送检口径 \(tgt.note)")
            let made = randomInputs(model: model, w: tgt.w, h: tgt.h, count: 8)
            guard !made.list.isEmpty else {
                out.append("      造不出输入: \(made.note)")
                continue
            }
            let warm = loop(model, made.list, 5)
            let timed = loop(model, made.list, runs)
            out.append("      预热5次 \(VRUtil.stat(warm.ms))｜正式 \(runs) 次 \(VRUtil.stat(timed.ms))")
            if !timed.note.isEmpty { out.append("      \(timed.note)") }
            if unit.0 == "cpuAndNeuralEngine" {
                out.append("      \(outputPeek(model, made.list[0]))")
            }
        }
        out.append("  对照：PC 那套 base 模型 m6 臂 0.278 s/帧；Apple 模型卡给 iPhone 12 Pro Max 是 31.10 ms（ANE）")
        return out.joined(separator: "\n")
    }

    static func randomInputs(model: MLModel, w: Int, h: Int, count: Int)
        -> (list: [MLFeatureProvider], note: String) {
        let name = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        var list: [MLFeatureProvider] = []
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func rnd() -> UInt8 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return UInt8(seed & 0xFF)
        }
        for _ in 0..<count {
            let made = VRTech.pixelBuffer(width: w, height: h)
            guard let pb = made.pb else { return ([], made.note) }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let total = CVPixelBufferGetDataSize(pb)
                let p = base.assumingMemoryBound(to: UInt8.self)
                var i = 0
                while i < total { p[i] = rnd(); i += 1 }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            do {
                list.append(try MLDictionaryFeatureProvider(
                    dictionary: [name: MLFeatureValue(pixelBuffer: pb)]))
            } catch {
                return ([], "造 \(name) 的 feature provider 失败: \(error)")
            }
        }
        return (list, "8 份随机输入 \(w)x\(h)")
    }

    static func loop(_ model: MLModel, _ inputs: [MLFeatureProvider], _ runs: Int)
        -> (ms: [Double], note: String) {
        var times: [Double] = []
        for i in 0..<runs {
            let t0 = DispatchTime.now().uptimeNanoseconds
            do {
                _ = try model.prediction(from: inputs[i % inputs.count])
            } catch {
                return (times, "第 \(i) 次 predict 抛错: \(error)")
            }
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        }
        return (times, "")
    }

    /// 输出到底长什么样：像素格式、尺寸、数值范围。灰度 8 位意味着这个包已经在内部
    /// 逐帧把深度拉成 0..255 了——那会直接否掉 PC 的"整片归一化"，必须当场看见。
    static func outputPeek(_ model: MLModel, _ input: MLFeatureProvider) -> String {
        guard let key = model.modelDescription.outputDescriptionsByName.keys.first,
              let res = try? model.prediction(from: input),
              let v = res.featureValue(for: key) else {
            return "输出取不到：\(model.modelDescription.outputDescriptionsByName.keys.joined(separator: ","))"
        }
        if let arr = v.multiArrayValue {
            let dims = arr.shape.map { $0.intValue }
            let n = arr.count
            let p = arr.dataPointer
            var mn = Float.greatestFiniteMagnitude, mx = -Float.greatestFiniteMagnitude
            if arr.dataType == .float32 {
                let f = p.assumingMemoryBound(to: Float32.self)
                var i = 0
                while i < n { mn = min(mn, f[i]); mx = max(mx, f[i]); i += 1 }
            }
            return "输出 \(key) multiArray dims=\(dims) 类型 \(arr.dataType.rawValue) 数值 \(String(format: "%.3f~%.3f", mn, mx))"
        }
        guard let pb = v.imageBufferValue?.pixelBuffer else {
            return "输出 \(key) 类型 \(v.type.rawValue)：既不是 multiArray 也取不到 pixelBuffer"
        }
        let plane = VRPlane.read(pb)
        return "输出 \(key) 图像 \(plane.w)x\(plane.h) 格式 \(plane.fourcc) 每像素 \(plane.bpp) 字节"
            + "｜随机图喂进去的数值 \(String(format: "%.3f~%.3f", plane.min, plane.max))"
            + (plane.note.isEmpty ? "" : "｜\(plane.note)")
    }
}

// MARK: - 深度平面读出

/// 把模型输出的那张图摊平成 [Float]，并按"眼格"重采样。
/// 这里刻意不用 CoreVideo 的具名格式常量（那批 OneComponent* 在 Swift 里叫什么我不敢赌），
/// 改成按每像素字节数解，并把 fourcc 原样报出去——猜错了一眼就能在报告里看到。
enum VRPlane {
    struct Out {
        var vals: [Float] = []
        var w = 0
        var h = 0
        var bpp = 0
        var fourcc = "?"
        var min: Float = .greatestFiniteMagnitude
        var max: Float = -.greatestFiniteMagnitude
        var note = ""
    }

    static func read(_ pb: CVPixelBuffer) -> Out {
        var o = Out()
        let f = CVPixelBufferGetPixelFormatType(pb)
        o.fourcc = VRUtil.fourcc(f)
        o.w = CVPixelBufferGetWidth(pb)
        o.h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        o.bpp = o.w > 0 ? bpr / o.w : 0
        guard o.w > 0, o.h > 0, bpr >= o.w else {
            o.note = "输出尺寸/行宽不认：\(o.w)x\(o.h) bpr=\(bpr)"
            return o
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            o.note = "取不到基地址（没锁？）"
            return o
        }
        let cc = f
        o.vals = [Float](repeating: 0, count: o.w * o.h)
        switch o.bpp {
        case 1:
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<o.h {
                let row = y * bpr
                for x in 0..<o.w {
                    let v = Float(p[row + x])
                    o.vals[y * o.w + x] = v
                    if v < o.min { o.min = v }
                    if v > o.max { o.max = v }
                }
            }
        case 2:
            // 两种可能：16 位无符号整数，或半浮点。半浮点的判据是"当整数读出来一片 15xxx~16xxx
            // 而按 half 读出来落在 0..2 之间"；取 half 优先，因为 CoreML 的图像输出常用 OneComponent16Half。
            let p = base.assumingMemoryBound(to: UInt16.self)
            var asHalfSum = 0.0
            var asIntSum = 0.0
            var n = 0
            for y in stride(from: 0, to: o.h, by: 8) {
                for x in stride(from: 0, to: o.w, by: 16) {
                    let b = p[y * (bpr / 2) + x]
                    let hv = Float16(bitPattern: b)
                    asHalfSum += Double(Float(hv))
                    asIntSum += Double(b)
                    n += 1
                }
            }
            let halfSane = n > 0 && abs(asHalfSum / Double(n)) < 4.0
            let p2 = base.assumingMemoryBound(to: UInt16.self)
            for y in 0..<o.h {
                let row = y * (bpr / 2)
                for x in 0..<o.w {
                    let b = p2[row + x]
                    let v = halfSane ? Float(Float16(bitPattern: b)) : Float(b)
                    o.vals[y * o.w + x] = v
                    if v < o.min { o.min = v }
                    if v > o.max { o.max = v }
                }
            }
            o.note = "16 位按\(halfSane ? "半浮点" : "无符号整数")读（均值 half \(String(format: "%.3f", n > 0 ? asHalfSum / Double(n) : 0))"
                + " / int \(String(format: "%.1f", n > 0 ? asIntSum / Double(n) : 0))）"
        case 4:
            let p = base.assumingMemoryBound(to: Float32.self)
            for y in 0..<o.h {
                let row = y * (bpr / 4)
                for x in 0..<o.w {
                    let v = p[row + x]
                    o.vals[y * o.w + x] = v
                    if v < o.min { o.min = v }
                    if v > o.max { o.max = v }
                }
            }
        default:
            o.note = "每像素 \(o.bpp) 字节这个格式还不认（fourcc \(o.fourcc)）"
        }
        if o.vals.isEmpty { o.note = "读出来是空的" }
        return o
    }

    /// 整片归一化用的 1/99 百分位：每帧抽 1/16 个像素排序，够稳也快
    static func percentile(_ vals: [Float]) -> (lo: Float, hi: Float) {
        var sample: [Float] = []
        sample.reserveCapacity(vals.count / 16 + 8)
        var i = 0
        while i < vals.count { sample.append(vals[i]); i += 16 }
        guard sample.count > 2 else { return (vals.first ?? 0, vals.last ?? 1) }
        let s = sample.sorted()
        let a = s[max(0, Int(Double(s.count) * 0.01))]
        let b = s[min(s.count - 1, Int(Double(s.count) * 0.99))]
        return (a, b > a ? b : s[s.count - 1])
    }
}
