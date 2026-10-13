import Foundation
import CoreML
import CoreVideo
import UIKit

/// 三张 fp32 网在手机上的一次完整生命周期：找模型 → 编 → 装 → 跑。
/// 名字全部照 CI 转出来的 CoreML 名逐字抄（app/SwapModel/out/{arcface,build_swap,mfs_unet}.mlpackage，
/// 输出名在发布位 channel-swap 的 cv_arc.log / cv_build.log / cv_unet.log 里逐条列过）。
enum SwapNets {
    static let arcResource = "arcface"
    static let buildResource = "build_swap"
    static let unetResource = "mfs_unet"

    /// PC 那侧是 `zip(逐帧网的输入顺序[1:], 权重生成网的输出顺序)` 硬按位置对齐的，CoreML 里没有顺序可言，
    /// 所以把这个位置关系逐条落成名字表（左右两列在 PC 上形状逐条相等，tools/mfs_swap.py 就是这么跑通的）。
    /// 注意 w_dec_0 与 w_dec_1 同为 [1,512,3,3] ⇒ 光靠形状认不出谁是谁，只能靠这张表。
    static let weightMap: [(unet: String, build: String)] = [
        ("w_enc_0", "save_infer_model_scale_0_tmp_1"),
        ("w_enc_1", "save_infer_model_scale_1_tmp_1"),
        ("w_enc_2", "save_infer_model_scale_2_tmp_0"),
        ("w_enc_3", "save_infer_model_scale_3_tmp_0"),
        ("w_enc_4", "save_infer_model_scale_4_tmp_0"),
        ("w_dec_0", "save_infer_model_scale_5_tmp_0"),
        ("w_dec_1", "save_infer_model_scale_6_tmp_0"),
        ("w_dec_2", "save_infer_model_scale_7_tmp_0"),
        ("w_dec_3", "save_infer_model_scale_8_tmp_0"),
        ("mod_enc_0", "save_infer_model_scale_9_tmp_0"),
        ("mod_enc_1", "save_infer_model_scale_10_tmp_0"),
        ("mod_enc_2", "save_infer_model_scale_11_tmp_0"),
        ("mod_enc_3", "save_infer_model_scale_12_tmp_0"),
        ("mod_enc_4", "save_infer_model_scale_13_tmp_0"),
        ("mod_dec_0", "save_infer_model_scale_14_tmp_0"),
        ("mod_dec_1", "save_infer_model_scale_15_tmp_0"),
        ("mod_dec_2", "save_infer_model_scale_16_tmp_0"),
        ("mod_dec_3", "save_infer_model_scale_17_tmp_0"),
    ]

    /// arcface 的 ImageNet 归一化：PC 是 (rgb/255 − MEAN)/STD，逐字抄 tools/mfs_swap.py。
    static let arcMean: [Float] = [0.485, 0.456, 0.406]
    static let arcStd: [Float] = [0.229, 0.224, 0.225]

    /// 把模型自己声明的入参/出参打印成人能读的一行。
    /// 万一转换器把 4D 输入声明成了 image 型（喂法就完全不同），这一行当场露馅。
    static func describe(_ model: MLModel) -> String {
        let md = model.modelDescription
        var ins: [String] = []
        for n in md.inputDescriptionsByName.keys.sorted() {
            guard let d = md.inputDescriptionsByName[n] else { continue }
            if d.type == .multiArray, let c = d.multiArrayConstraint {
                ins.append("\(n)=\(c.shape.map { String($0.intValue) }.joined(separator: "x"))/\(dtypeName(c.dataType))")
            } else if d.type == .image, let ic = d.imageConstraint {
                ins.append("\(n)=image\(ic.pixelsWide)x\(ic.pixelsHigh)")
            } else {
                ins.append("\(n)=类型\(d.type.rawValue)")
            }
        }
        var outs: [String] = []
        for n in md.outputDescriptionsByName.keys.sorted() {
            guard let d = md.outputDescriptionsByName[n], d.type == .multiArray,
                  let c = d.multiArrayConstraint else { continue }
            outs.append("\(n)=\(c.shape.map { String($0.intValue) }.joined(separator: "x"))")
        }
        return "入[\(ins.joined(separator: " "))] 出[\(outs.joined(separator: " "))]"
    }

    private static func dtypeName(_ t: MLMultiArrayDataType) -> String {
        switch t {
        case .float16: return "f16"
        case .float32: return "f32"
        case .float64: return "f64"
        case .int32: return "i32"
        @unknown default: return "?\(t.rawValue)"
        }
    }
}

/// 一个源身份的三件套：身份证（512 维嵌入）、身份包（512×7×7 特征图）、逐帧网要的 18 个权重。
/// 每人只算一次，整片共用 ⇒ 换一个人的脸要重新走一遍身份证＋权重生成。
final class SwapRunner {
    let arc: MLModel
    let build: MLModel
    let unet: MLModel
    let loadNote: String

    struct Contract {
        let arcInput: String
        let arcEmbOut: String
        let arcFeatOut: String
        let buildEmbIn: String
        let buildFeatIn: String
        let attName: String
        let unetOutImage: String
        let unetOutMask: String
        let weightNames: [String]
        let weightSources: [String]
    }

    let contract: Contract

    /// 18 个身份权重：装好一次，逐帧复用（预测期间只读）
    private var weightFeed: [String: MLFeatureValue] = [:]
    private(set) var hasWeights = false

    private(set) var identityMs: [Double] = []
    private(set) var genMs: [Double] = []
    private(set) var frameMs: [Double] = []

    /// 找模型：包里优先是 coremlc 编好的 mlmodelc；只剩 mlpackage 的话现场 compileModel。
    /// 绝不在主线程调（204 MB 那张可能编几分钟），调用方必须在后台线程上。
    static func locate(_ resource: String) -> (url: URL?, note: String) {
        let fm = FileManager.default
        if let u = Bundle.main.url(forResource: resource, withExtension: "mlmodelc") {
            return (u, "\(resource) 包里是已编译 mlmodelc")
        }
        var pkg: URL? = Bundle.main.url(forResource: resource, withExtension: "mlpackage")
        if pkg == nil {
            for base in [Bundle.main.bundleURL, Bundle.main.resourceURL].compactMap({ $0 }) {
                let u = base.appendingPathComponent("\(resource).mlpackage")
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                    pkg = u
                    break
                }
            }
        }
        guard let p = pkg else {
            return (nil, "包里没有 \(resource).mlmodelc 也没有 \(resource).mlpackage")
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            let c = try MLModel.compileModel(at: p)
            return (c, "\(resource) 现场编译成功 \(SwapUtil.ms(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000))")
        } catch {
            return (nil, "\(resource) 现场编译失败: \(error)")
        }
    }

    /// 三张都装上。凑不齐或接口对不上就把诊断文本整体带回来——不许半死不活地继续跑。
    static func load(units: MLComputeUnits, onLine: (String) -> Void) -> (runner: SwapRunner?, note: String) {
        var note = ""
        var made: [String: MLModel] = [:]
        for res in [SwapNets.arcResource, SwapNets.buildResource, SwapNets.unetResource] {
            let found = locate(res)
            note += "\(res): \(found.note)\n"
            onLine("\(res): \(found.note)")
            guard let url = found.url else { continue }
            let cfg = MLModelConfiguration()
            cfg.computeUnits = units
            let t0 = DispatchTime.now().uptimeNanoseconds
            do {
                let m = try MLModel(contentsOf: url, configuration: cfg)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                note += "  加载 \(SwapUtil.ms(ms))｜足迹 \(SwapFacts.footprintMB()) MB\n  \(SwapNets.describe(m))\n"
                onLine("  \(res) 加载 \(SwapUtil.ms(ms))｜足迹 \(SwapFacts.footprintMB()) MB")
                onLine("  \(res) \(SwapNets.describe(m))")
                made[res] = m
            } catch {
                note += "  加载失败: \(error)\n"
                onLine("  \(res) 加载失败: \(error)")
            }
        }
        guard let a = made[SwapNets.arcResource], let b = made[SwapNets.buildResource],
              let u = made[SwapNets.unetResource] else {
            return (nil, note + "三张网没凑齐，这一版出不了片")
        }
        let got = SwapRunner.contract(arc: a, build: b, unet: u)
        onLine("接口对账: \(got.note)")
        guard let c = got.value else {
            return (nil, note + "接口对账：\(got.note)\n")
        }
        note += "接口对账：\(got.note)\n"
        return (SwapRunner(arc: a, build: b, unet: u, loadNote: note, contract: c), note)
    }

    /// 名字先按形状认一遍（转换器改了名也能对上），18 个权重再逐条点名。
    /// 任何一条对不上就拒绝出片：w_dec_0/1 同形状，靠形状硬猜会认错，
    /// 认错了画面照样"像个人"，只是身份串了或糊了——那种错必须当场挡下来。
    static func contract(arc: MLModel, build: MLModel, unet: MLModel) -> (value: Contract?, note: String) {
        var err: [String] = []
        func names(_ m: MLModel, _ inputs: Bool) -> [String] {
            let md = m.modelDescription
            return (inputs ? md.inputDescriptionsByName : md.outputDescriptionsByName).keys.sorted()
        }
        func find(_ m: MLModel, inputs: Bool, rank: Int, channels: Int, total: Int, prefers: [String]) -> String? {
            let md = m.modelDescription
            let dict = inputs ? md.inputDescriptionsByName : md.outputDescriptionsByName
            for name in prefers + dict.keys.sorted() where dict[name] != nil {
                if matches(dict[name]!, rank: rank, channels: channels, total: total) { return name }
            }
            return nil
        }

        guard let ai = find(arc, inputs: true, rank: 4, channels: 3, total: 3 * 112 * 112, prefers: ["input"]) else {
            err.append("arcface 找不到 [1,3,112,112] 的输入（实际入 \(names(arc, true))）")
            return (nil, err.joined(separator: "；"))
        }
        guard let ae = find(arc, inputs: false, rank: 2, channels: -1, total: 512, prefers: ["fetch_name_0"]) else {
            err.append("arcface 找不到 [1,512] 的输出（实际出 \(names(arc, false))）")
            return (nil, err.joined(separator: "；"))
        }
        guard let af = find(arc, inputs: false, rank: 4, channels: 512, total: 512 * 7 * 7, prefers: ["fetch_name_1"]) else {
            err.append("arcface 找不到 [1,512,7,7] 的输出（实际出 \(names(arc, false))）")
            return (nil, err.joined(separator: "；"))
        }
        guard let be = find(build, inputs: true, rank: 2, channels: -1, total: 512, prefers: ["id_emb"]) else {
            err.append("权重生成网找不到 id_emb（实际入 \(names(build, true))）")
            return (nil, err.joined(separator: "；"))
        }
        guard let bf = find(build, inputs: true, rank: 4, channels: 512, total: 512 * 7 * 7, prefers: ["id_feature"]) else {
            err.append("权重生成网找不到 id_feature（实际入 \(names(build, true))）")
            return (nil, err.joined(separator: "；"))
        }
        guard let at = find(unet, inputs: true, rank: 4, channels: 3, total: 3 * 224 * 224, prefers: ["att_img"]) else {
            err.append("逐帧网找不到 att_img（实际入 \(names(unet, true))）")
            return (nil, err.joined(separator: "；"))
        }
        guard let gi = find(unet, inputs: false, rank: 4, channels: 3, total: 3 * 224 * 224,
                            prefers: ["save_infer_model_scale_0_tmp_0"]) else {
            err.append("逐帧网找不到换出的脸（实际出 \(names(unet, false))）")
            return (nil, err.joined(separator: "；"))
        }
        guard let mi = find(unet, inputs: false, rank: 4, channels: 1, total: 224 * 224,
                            prefers: ["save_infer_model_scale_1_tmp_0"]) else {
            err.append("逐帧网找不到 mask（实际出 \(names(unet, false))）")
            return (nil, err.joined(separator: "；"))
        }

        let uNames = names(unet, true), bNames = names(build, false)
        var missU: [String] = [], missB: [String] = []
        for w in SwapNets.weightMap {
            if !uNames.contains(w.unet) { missU.append(w.unet) }
            if !bNames.contains(w.build) { missB.append(w.build) }
        }
        if !missU.isEmpty || !missB.isEmpty {
            err.append("权重名对不上：逐帧网缺 \(missU)｜权重生成网缺 \(missB)")
            return (nil, err.joined(separator: "；"))
        }
        let c = Contract(arcInput: ai, arcEmbOut: ae, arcFeatOut: af,
                         buildEmbIn: be, buildFeatIn: bf, attName: at,
                         unetOutImage: gi, unetOutMask: mi,
                         weightNames: SwapNets.weightMap.map { $0.unet },
                         weightSources: SwapNets.weightMap.map { $0.build })
        return (c, "全对上｜arc 入 \(ai) 出 \(ae)+\(af)｜build 入 \(be)+\(bf)｜unet 入 \(at)+18 出 \(gi)+\(mi)")
    }

    /// image 型输入的等价判定：CoreML 把 [1,C,H,W] 折成一张 w×h 的图，面积×通道对得上就算它
    private static func matches(_ d: MLFeatureDescription, rank: Int, channels: Int, total: Int) -> Bool {
        if d.type == .multiArray, let c = d.multiArrayConstraint {
            let dims = c.shape.map { $0.intValue }
            guard dims.count == rank, dims.reduce(1, *) == total else { return false }
            if channels >= 0 && rank >= 3 && dims[1] != channels { return false }
            return true
        }
        if d.type == .image, channels >= 0, let ic = d.imageConstraint {
            return Int(ic.pixelsWide) * Int(ic.pixelsHigh) * channels == total
        }
        return false
    }

    init(arc: MLModel, build: MLModel, unet: MLModel, loadNote: String, contract: Contract) {
        self.arc = arc
        self.build = build
        self.unet = unet
        self.loadNote = loadNote
        self.contract = contract
    }

    // MARK: - 喂数据

    /// 0~1 的 planar RGB → 模型声明的那个形状和类型。
    /// multiArray 型：归一化在这里做（和 PC 同式）；image 型：喂 0~255 像素，
    /// 归一化交给 CoreML 编译期烘进包的预处理——这条到底烘没烘，只能上机看余弦。
    private func feature(_ model: MLModel, name: String, planar01: [Float],
                         mean: [Float]?, std: [Float]?) -> (MLFeatureValue?, String) {
        guard let d = model.modelDescription.inputDescriptionsByName[name] else {
            return (nil, "\(name) 没有输入描述")
        }
        if d.type == .image, let ic = d.imageConstraint {
            let w = Int(ic.pixelsWide), h = Int(ic.pixelsHigh)
            guard planar01.count == 3 * w * h else {
                return (nil, "\(name) 是 image \(w)x\(h)，手里 \(planar01.count) 个数对不上")
            }
            guard let v = pixelValue(planar01, w: w, h: h) else {
                return (nil, "\(name) 是 image \(w)x\(h)，像素缓冲建不出来")
            }
            return (v, "按 image 喂 \(w)x\(h)")
        }
        guard let c = d.multiArrayConstraint else { return (nil, "\(name) 类型 \(d.type.rawValue) 不会喂") }
        let dims = c.shape.map { $0.intValue }
        let total = dims.reduce(1, *)
        guard total == planar01.count else {
            return (nil, "\(name) 要 \(total) 个数（\(dims)），手里 \(planar01.count) 个")
        }
        guard let arr = try? MLMultiArray(shape: dims.map { NSNumber(value: $0) }, dataType: c.dataType)
        else { return (nil, "\(name) 建不出 MLMultiArray \(dims)") }
        var v = planar01
        if let m = mean, let s = std, dims.count == 4 {
            let plane = dims[2] * dims[3]
            for ch in 0..<min(3, dims[1]) {
                for i in 0..<plane { v[ch * plane + i] = (v[ch * plane + i] - m[ch]) / s[ch] }
            }
        }
        switch c.dataType {
        case .float32:
            let p = arr.dataPointer.assumingMemoryBound(to: Float32.self)
            for i in 0..<total { p[i] = Float32(v[i]) }
        case .float16:
            let p = arr.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<total { p[i] = Float16(v[i]) }
        case .float64:
            let p = arr.dataPointer.assumingMemoryBound(to: Double.self)
            for i in 0..<total { p[i] = Double(v[i]) }
        case .int32:
            let p = arr.dataPointer.assumingMemoryBound(to: Int32.self)
            for i in 0..<total { p[i] = Int32(v[i]) }
        default:
            return (nil, "\(name) 的数组类型 \(c.dataType.rawValue) 我还不会填")
        }
        return (MLFeatureValue(multiArray: arr), "按 multiArray 喂 \(dims)")
    }

    /// planar RGB 0~1 → BGRA 像素缓冲
    private func pixelValue(_ planar01: [Float], w: Int, h: Int) -> MLFeatureValue? {
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let buf = pb
        else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf) / 4
        let plane = w * h
        for y in 0..<h {
            for x in 0..<w {
                let k = (y * bpr + x) * 4, o = y * w + x
                p[k + 0] = UInt8(max(0, min(255, planar01[2 * plane + o] * 255.0 + 0.5)))
                p[k + 1] = UInt8(max(0, min(255, planar01[plane + o] * 255.0 + 0.5)))
                p[k + 2] = UInt8(max(0, min(255, planar01[o] * 255.0 + 0.5)))
                p[k + 3] = 255
            }
        }
        return MLFeatureValue(pixelBuffer: buf)
    }

    /// 按 stride 把任意形状的数组摊成行优先的 [Float]（CoreML 给的缓冲不保证连续）
    static func flatten(_ arr: MLMultiArray) -> [Float]? {
        let dims = arr.shape.map { $0.intValue }
        let strides = arr.strides.map { $0.intValue }
        let total = dims.reduce(1, *)
        guard total > 0, dims.count >= 1, dims.count <= 4 else { return nil }
        var out = [Float](repeating: 0, count: total)
        var idx = [Int](repeating: 0, count: dims.count)
        var off = 0
        for i in 0..<total {
            switch arr.dataType {
            case .float32:
                out[i] = arr.dataPointer.assumingMemoryBound(to: Float32.self)[off]
            case .float16:
                out[i] = Float(arr.dataPointer.assumingMemoryBound(to: Float16.self)[off])
            case .float64:
                out[i] = Float(arr.dataPointer.assumingMemoryBound(to: Double.self)[off])
            default:
                return nil
            }
            var k = dims.count - 1
            while k >= 0 {
                idx[k] += 1
                if idx[k] < dims[k] { break }
                idx[k] = 0
                k -= 1
            }
            off = 0
            for d in 0..<dims.count { off += idx[d] * strides[d] }
        }
        return out
    }

    static func l2(_ v: [Float]) -> [Float] {
        var n = 0.0
        for x in v { n += Double(x) * Double(x) }
        n = n.squareRoot()
        guard n > 1e-9 else { return v }
        return v.map { Float(Double($0) / n) }
    }

    // MARK: - 三步

    /// ① 身份证：112 的 0~1 planar RGB → 512 维嵌入（已 L2）＋ 512×7×7 特征图。
    /// 每人一次。PC 实测这一对 1109~1318 ms。
    func identity(crop112_01: [Float]) -> (emb: [Float], feat: [Float], rawNorm: Double, ms: Double, note: String) {
        let (fv, how) = feature(arc, name: contract.arcInput, planar01: crop112_01,
                                mean: SwapNets.arcMean, std: SwapNets.arcStd)
        guard let v = fv else { return ([], [], 0, 0, "身份证喂不进：\(how)") }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let provider = try? MLDictionaryFeatureProvider(dictionary: [contract.arcInput: v])
        guard let dp = provider, let res = try? arc.prediction(from: dp) else {
            return ([], [], 0, 0, "身份证 predict 抛错（\(how)）")
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        identityMs.append(ms)
        guard let eArr = res.featureValue(for: contract.arcEmbOut)?.multiArrayValue,
              let fArr = res.featureValue(for: contract.arcFeatOut)?.multiArrayValue,
              let e = SwapRunner.flatten(eArr), let f = SwapRunner.flatten(fArr) else {
            return ([], [], 0, ms, "身份证输出取不出来（\(contract.arcEmbOut)/\(contract.arcFeatOut)）")
        }
        var n = 0.0
        for x in e { n += Double(x) * Double(x) }
        return (SwapRunner.l2(e), f, n.squareRoot(), ms, how)
    }

    /// ② 身份包：身份证 → 18 个权重。每人一次。PC 实测 27~50 ms。
    func makeWeights(emb: [Float], feat: [Float]) -> (count: Int, ms: Double, note: String) {
        let (ev, howE) = feature(build, name: contract.buildEmbIn, planar01: emb, mean: nil, std: nil)
        let (fvv, howF) = feature(build, name: contract.buildFeatIn, planar01: feat, mean: nil, std: nil)
        guard let e = ev, let f = fvv else { return (0, 0, "身份包喂不进：\(howE)｜\(howF)") }
        let dict: [String: MLFeatureValue] = [contract.buildEmbIn: e, contract.buildFeatIn: f]
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let res = try? build.prediction(
            from: MLDictionaryFeatureProvider(dictionary: dict)) else {
            return (0, 0, "身份包 predict 抛错")
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        genMs.append(ms)
        var out: [String: MLFeatureValue] = [:]
        var bad: [String] = []
        let md = unet.modelDescription
        for (uName, bName) in zip(contract.weightNames, contract.weightSources) {
            guard let v = res.featureValue(for: bName), let a = v.multiArrayValue else {
                bad.append("\(bName)=取不到")
                continue
            }
            // 形状逐条对账：对不上就是名字表错，不许"差一点没关系"
            if let d = md.inputDescriptionsByName[uName], let c = d.multiArrayConstraint {
                let want = c.shape.map { $0.intValue }, got = a.shape.map { $0.intValue }
                if want != got { bad.append("\(uName) 要 \(want) 拿到 \(got)"); continue }
            }
            out[uName] = v
        }
        weightFeed = out
        hasWeights = out.count == contract.weightNames.count
        if bad.isEmpty { return (out.count, ms, "18 个权重全装上，形状逐条对过") }
        return (out.count, ms, "权重装失败：\(bad.joined(separator: "｜"))")
    }

    /// 把内存里那 18 个权重连形状一起摊成 [Float]，交身份库存盘。形状必须跟着存：
    /// 下次装回来要按它核对，光有名字对不上位置就是错的，而错的权重出的画面照样"像个人"。
    func weightDump() -> [(name: String, dims: [Int], data: [Float])] {
        guard hasWeights else { return [] }
        var out: [(name: String, dims: [Int], data: [Float])] = []
        for n in contract.weightNames {
            guard let a = weightFeed[n]?.multiArrayValue, let f = SwapRunner.flatten(a) else { return [] }
            out.append((n, a.shape.map { $0.intValue }, f))
        }
        return out
    }

    /// 从存档装回 18 个权重。逐条按 unet 自己声明的形状和类型核对，凑不齐就整份不收、hasWeights 留假：
    /// 名字表错一位出的画面照样"像个人"，只有身份会串——那种错必须当场挡下来。
    func useWeights(_ tensors: [(name: String, dims: [Int], data: [Float])]) -> (count: Int, note: String) {
        weightFeed = [:]
        hasWeights = false
        let md = unet.modelDescription
        var out: [String: MLFeatureValue] = [:]
        var bad: [String] = []
        for t in tensors {
            guard contract.weightNames.contains(t.name) else { bad.append("\(t.name) 不在名字表里"); continue }
            guard let d = md.inputDescriptionsByName[t.name], let c = d.multiArrayConstraint else {
                bad.append("\(t.name) 网里没有这个入参"); continue
            }
            let want = c.shape.map { $0.intValue }
            guard want == t.dims else { bad.append("\(t.name) 要 \(want) 存档 \(t.dims)"); continue }
            let total = want.reduce(1, *)
            guard t.data.count == total else { bad.append("\(t.name) 要 \(total) 个数，存档 \(t.data.count)"); continue }
            guard let arr = try? MLMultiArray(shape: want.map { NSNumber(value: $0) }, dataType: c.dataType)
            else { bad.append("\(t.name) 建不出 MLMultiArray \(want)"); continue }
            switch c.dataType {
            case .float32:
                let p = arr.dataPointer.assumingMemoryBound(to: Float32.self)
                for i in 0 ..< total { p[i] = t.data[i] }
            case .float16:
                let p = arr.dataPointer.assumingMemoryBound(to: Float16.self)
                for i in 0 ..< total { p[i] = Float16(t.data[i]) }
            case .float64:
                let p = arr.dataPointer.assumingMemoryBound(to: Double.self)
                for i in 0 ..< total { p[i] = Double(t.data[i]) }
            default:
                bad.append("\(t.name) 入参类型 \(c.dataType.rawValue) 不会填"); continue
            }
            out[t.name] = MLFeatureValue(multiArray: arr)
        }
        guard bad.isEmpty, out.count == contract.weightNames.count else {
            return (out.count, "存档的权重没收：\(bad.joined(separator: "｜"))")
        }
        weightFeed = out
        hasWeights = true
        return (out.count, "18 个权重从存档装上，形状逐条对过")
    }

    /// ③ 逐帧：224 的 0~1 planar RGB ＋ 那 18 个权重 → 换出的脸 + mask。
    /// PC 56 ms/帧；上一版上机实测这张网 CPU 12.00 ms/帧。
    func frame(att224_01: [Float]) -> (out: [Float], mask: [Float], ms: Double, note: String) {
        guard hasWeights else { return ([], [], 0, "还没算身份") }
        let (v, how) = feature(unet, name: contract.attName, planar01: att224_01, mean: nil, std: nil)
        guard let av = v else { return ([], [], 0, "逐帧网喂不进：\(how)") }
        var dict = weightFeed
        dict[contract.attName] = av
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: dict) else {
            return ([], [], 0, "逐帧输入字典装不起来（\(dict.count) 个键）")
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let res = try? unet.prediction(from: provider) else {
            frameMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            return ([], [], 0, "逐帧 predict 抛错（\(how)）")
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        frameMs.append(ms)
        guard let gArr = res.featureValue(for: contract.unetOutImage)?.multiArrayValue,
              let mArr = res.featureValue(for: contract.unetOutMask)?.multiArrayValue,
              let g = SwapRunner.flatten(gArr), let m = SwapRunner.flatten(mArr) else {
            return ([], [], ms, "逐帧输出取不出来（\(contract.unetOutImage)/\(contract.unetOutMask)）")
        }
        return (g, m, ms, "")
    }

    func statsLine() -> String {
        "身份证 \(SwapUtil.stat(identityMs))｜权重生成 \(SwapUtil.stat(genMs))｜逐帧 \(SwapUtil.stat(frameMs))"
    }
}

enum SwapMath {
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -9 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y; na += x * x; nb += y * y
        }
        guard na > 1e-12, nb > 1e-12 else { return -9 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// -9 只有三种来路：某一边是空的／两边维度不一样／某一边是全零。
    /// 上一版日志只印 -9.000，这三种在机上分不开，「已存的人」那条路的账就永远结不了。
    static func whyNot(_ v: Double, _ a: [Float], _ b: [Float]) -> String {
        guard v < -8 else { return "不是量不出" }
        if a.isEmpty { return "这边没回话" }
        if b.isEmpty { return "那边是空的" }
        if a.count != b.count { return "维度 \(a.count) vs \(b.count)" }
        var na = 0.0, nb = 0.0
        for i in 0 ..< a.count {
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        if na <= 1e-12 { return "这边全零（模长 0）" }
        if nb <= 1e-12 { return "那边全零（模长 0）" }
        return "两条都正常却没回数"
    }
}
