import Foundation
import CoreML
import CoreVideo
import UIKit

/// 四张 fp32 网在手机上的一次完整生命周期：找模型 → 编 → 装 → 跑。
/// 名字全部照 CI 转出来的 CoreML 名逐字抄（app/SwapModel/out/{arcface,build_swap,mfs_unet,faceparse}.mlpackage，
/// 输出名在发布位 channel-swap 的 cv_arc.log / cv_build.log / cv_unet.log / cv_parse.log 里逐条列过）。
enum SwapNets {
    static let arcResource = "arcface"
    static let buildResource = "build_swap"
    static let unetResource = "mfs_unet"
    /// 人脸语义分割网（19 类，CelebAMask-HQ）。遮罩彻底换掉就是靠它：
    /// 原来那张遮罩的形状＝逐帧网自己画过的那一片，目标本人的脸有大半没被换掉；
    /// 这一张按「皮肤＋五官」分语义，贴区盖住目标脸的比例从 ~90 % 提到 ~96 %。
    static let parseResource = "faceparse"

    /// 分割网的入参尺寸。这张网只认 512×512（onnx 里是死的），所以喂进去的是
    /// 对齐 224 那张裁片放大到 512——真机一次 parse 的钱都在这一趟上，所以按脸缓存，不逐帧跑。
    static let parseSize = 512

    /// 分割网的 19 类里哪些算「脸」：皮肤 鼻 眼镜 左右眼 眉 耳 嘴 上下唇
    /// （头发/帽子/背景/衣服/脖子都不算，贴上去就是一团糊）
    static let parseFaceClasses: [Int] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
    static let parseClassCount = 19

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
/// 第四张是人脸分割网（遮罩用），它跟身份无关，整片共用。
final class SwapRunner {
    let arc: MLModel
    let build: MLModel
    let unet: MLModel
    let parse: MLModel
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
        /// 逐帧网第三个出参＝没混过的 gen。补丁改用它（out 是 gen·mask+(1−mask)·att，
        /// 带着目标本人四成，身份一格赔在那儿）
        let unetOutGen: String
        let parseInput: String
        let parseOutput: String
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
    private(set) var parseMs: [Double] = []

    /// 找模型：先找盘上那一份（Documents/swap_models，模型单独下载到手机上的），
    /// 再找包里已编译的 mlmodelc；只剩 mlpackage 的话现场 compileModel。
    /// 绝不在主线程调（204 MB 那张可能编几分钟），调用方必须在后台线程上。
    static func locate(_ resource: String) -> (url: URL?, note: String) {
        let fm = FileManager.default
        // 盘上那一份（Documents/swap_models，模型单独下载到手机上的）也是 mlpackage，
        // 同样要现场编一次：编译产物在临时目录里，编完这一趟就够用了。
        if let p = SwapStore.local(resource) {
            return compile(p, resource: resource, from: "盘上那一份")
        }
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
            return (nil, "既没有盘上那一份，包里也没有 \(resource).mlmodelc／\(resource).mlpackage")
        }
        return compile(p, resource: resource, from: "包里那份")
    }

    /// mlpackage → 现场编好（编出来的 mlmodelc 落在临时目录里，返回它的地址）。
    /// 盘上那一份和包里那一份走的是同一条路：两个位置的 mlpackage 结构一样。
    private static func compile(_ p: URL, resource: String, from where_: String) -> (url: URL?, note: String) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            let c = try MLModel.compileModel(at: p)
            return (c, "\(resource) \(where_)的 mlpackage 现场编译成功（\(SwapUtil.ms(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000))）")
        } catch {
            return (nil, "\(resource) \(where_)的 mlpackage 现场编译失败: \(error)")
        }
    }

    /// 包里四张都在（老 ipa 那样带着模型的）：这一版不用去碰网络
    private static func bundleHasAll() -> Bool {
        for r in [SwapNets.arcResource, SwapNets.buildResource, SwapNets.unetResource, SwapNets.parseResource] {
            if Bundle.main.url(forResource: r, withExtension: "mlmodelc") != nil { continue }
            if Bundle.main.url(forResource: r, withExtension: "mlpackage") != nil { continue }
            return false
        }
        return true
    }

    /// 四张都装上。凑不齐或接口对不上就把诊断文本整体带回来——不许半死不活地继续跑。
    static func load(units: MLComputeUnits, onLine: (String) -> Void) -> (runner: SwapRunner?, note: String) {
        var note = ""
        // 模型不再跟着 ipa 走（0.33 起）：盘上那一份缺了就先下一份。
        // 下了再改程序不用重下——版本号＝四张 onnx 的 sha256，程序改了模型没变。
        // 这一步要走网络，所以只在真缺时才走；包里有（老 ipa）就不去碰网络。
        if !SwapStore.haveAll() && !bundleHasAll() {
            onLine("模型 盘上那一份没有，先下一份（几百 MB，第一次要等一会儿）")
            let g = SwapStore.ensure(force: false, onLine: onLine)
            onLine("模型 \(g.note)")
            if !g.ok { note += "模型 没下下来：\(g.note)\n" }
        }
        var made: [String: MLModel] = [:]
        for res in [SwapNets.arcResource, SwapNets.buildResource, SwapNets.unetResource, SwapNets.parseResource] {
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
              let u = made[SwapNets.unetResource], let p = made[SwapNets.parseResource] else {
            let got = made.keys.sorted().joined(separator: "／")
            return (nil, note + "四张网没凑齐（装上的是 \(got)），这一版出不了片")
        }
        let got = SwapRunner.contract(arc: a, build: b, unet: u, parse: p)
        onLine("接口对账: \(got.note)")
        guard let c = got.value else {
            return (nil, note + "接口对账：\(got.note)\n")
        }
        note += "接口对账：\(got.note)\n"
        return (SwapRunner(arc: a, build: b, unet: u, parse: p, loadNote: note, contract: c), note)
    }

    /// 名字先按形状认一遍（转换器改了名也能对上），18 个权重再逐条点名。
    /// 任何一条对不上就拒绝出片：w_dec_0/1 同形状，靠形状硬猜会认错，
    /// 认错了画面照样"像个人"，只是身份串了或糊了——那种错必须当场挡下来。
    static func contract(arc: MLModel, build: MLModel, unet: MLModel, parse: MLModel) -> (value: Contract?, note: String) {
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
        // 没混过的 gen：逐帧网两个 [1,3,224,224] 的出参，混过的那张已经认成 unetOutImage，
        // 剩下的那张就是 gen。认不出来就别硬跑——补丁要的就是没混的那一份。
        let imgOuts = names(unet, false).filter { n in
            guard let d = unet.modelDescription.outputDescriptionsByName[n] else { return false }
            return matches(d, rank: 4, channels: 3, total: 3 * 224 * 224)
        }
        guard let gn = imgOuts.first(where: { $0 != gi }) else {
            err.append("逐帧网只有一张 [1,3,224,224] 的出参（\(imgOuts)），没有没混过的 gen")
            return (nil, err.joined(separator: "；"))
        }
        guard let pi = find(parse, inputs: true, rank: 4, channels: 3,
                            total: 3 * SwapNets.parseSize * SwapNets.parseSize, prefers: ["input"]) else {
            err.append("分割网找不到 [1,3,\(SwapNets.parseSize),\(SwapNets.parseSize)] 的输入（实际入 \(names(parse, true))）")
            return (nil, err.joined(separator: "；"))
        }
        guard let po = find(parse, inputs: false, rank: 4, channels: SwapNets.parseClassCount,
                            total: SwapNets.parseClassCount * SwapNets.parseSize * SwapNets.parseSize,
                            prefers: ["out"]) else {
            err.append("分割网找不到 [1,\(SwapNets.parseClassCount),\(SwapNets.parseSize),\(SwapNets.parseSize)] 的输出（实际出 \(names(parse, false))）")
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
                         unetOutImage: gi, unetOutMask: mi, unetOutGen: gn,
                         parseInput: pi, parseOutput: po,
                         weightNames: SwapNets.weightMap.map { $0.unet },
                         weightSources: SwapNets.weightMap.map { $0.build })
        return (c, "全对上｜arc 入 \(ai) 出 \(ae)+\(af)｜build 入 \(be)+\(bf)"
            + "｜unet 入 \(at)+18 出 \(gi)+\(mi)+gen(\(gn))｜分割 入 \(pi) 出 \(po)")
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

    init(arc: MLModel, build: MLModel, unet: MLModel, parse: MLModel, loadNote: String, contract: Contract) {
        self.arc = arc
        self.build = build
        self.unet = unet
        self.parse = parse
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
        // 归一化只有 arcface 那一路要（逐帧网 mean/std 传的是 nil）：要才算一份拷贝，不要就原样搬
        var v: [Float]
        if let m = mean, let s = std, dims.count == 4 {
            v = planar01
            let plane = dims[2] * dims[3]
            for ch in 0..<min(3, dims[1]) {
                for i in 0..<plane { v[ch * plane + i] = (v[ch * plane + i] - m[ch]) / s[ch] }
            }
        } else {
            v = planar01
        }
        switch c.dataType {
        case .float32:
            // 新建的数组按行优先连续排 ⇒ 整段 memcpy。逐个数走 150528 遍是 0.22 量出来的「搬运」那一半的钱
            if total > 0, SwapRunner.isContiguous(arr, dims: dims) {
                v.withUnsafeBufferPointer { src in
                    memcpy(arr.dataPointer, src.baseAddress!, total * MemoryLayout<Float32>.size)
                }
            } else {
                let p = arr.dataPointer.assumingMemoryBound(to: Float32.self)
                for i in 0..<total { p[i] = Float32(v[i]) }
            }
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

    /// 行优先连续（stride 逐维等于上一维的元素数）才敢整段 memcpy。
    /// 新建的数组本该如此、CoreML 回来的不保证，所以每次读回来对一遍：认错了不报错，只把画面搬乱。
    static func isContiguous(_ arr: MLMultiArray, dims: [Int]) -> Bool {
        let st = arr.strides.map { $0.intValue }
        guard st.count == dims.count, st.last == 1 else { return false }
        var expect = 1
        for k in stride(from: dims.count - 1, through: 0, by: -1) {
            if st[k] != expect { return false }
            expect *= dims[k]
        }
        return expect == dims.reduce(1, *)
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
        // 连续那一档占绝大多数：逐个数现算偏移（每格 4 次乘加＋一次越界回卷）是 0.22 量出来的「搬运」另一半
        if isContiguous(arr, dims: dims) {
            switch arr.dataType {
            case .float32:
                var out = [Float](repeating: 0, count: total)
                out.withUnsafeMutableBufferPointer { d in
                    memcpy(d.baseAddress!, arr.dataPointer, total * MemoryLayout<Float32>.size)
                }
                return out
            case .float16:
                let p = arr.dataPointer.assumingMemoryBound(to: Float16.self)
                var out = [Float](repeating: 0, count: total)
                out.withUnsafeMutableBufferPointer { d in for i in 0..<total { d[i] = Float(p[i]) } }
                return out
            case .float64:
                let p = arr.dataPointer.assumingMemoryBound(to: Double.self)
                var out = [Float](repeating: 0, count: total)
                out.withUnsafeMutableBufferPointer { d in for i in 0..<total { d[i] = Float(p[i]) } }
                return out
            default:
                return nil
            }
        }
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

    /// ③ 逐帧：224 的 0~1 planar RGB ＋ 那 18 个权重 → 换出的脸（没混过的 gen）＋ mask。
    /// PC 56 ms/帧；上一版上机实测这张网 CPU 12.00 ms/帧。
    /// 补丁改用 gen：out 是 gen·mask+(1−mask)·att_img，尾巴带着目标本人四成，
    /// 身份一格就赔在那儿（本机 tools/_swap_parse.py：out 那一档 ↔源 0.738，gen 那一档 0.837）。
    func frame(att224_01: [Float]) -> (gen: [Float], ms: Double, note: String) {
        guard hasWeights else { return ([], 0, "还没算身份") }
        let (v, how) = feature(unet, name: contract.attName, planar01: att224_01, mean: nil, std: nil)
        guard let av = v else { return ([], 0, "逐帧网喂不进：\(how)") }
        var dict = weightFeed
        dict[contract.attName] = av
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: dict) else {
            return ([], 0, "逐帧输入字典装不起来（\(dict.count) 个键）")
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let res = try? unet.prediction(from: provider) else {
            frameMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            return ([], 0, "逐帧 predict 抛错（\(how)）")
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        frameMs.append(ms)
        guard let gArr = res.featureValue(for: contract.unetOutGen)?.multiArrayValue,
              let g = SwapRunner.flatten(gArr) else {
            return ([], ms, "逐帧输出取不出来（\(contract.unetOutGen)）")
        }
        return (g, ms, "")
    }

    /// ④ 分割网（遮罩用）：对齐 224 那张裁片 → 512 → 19 类语义 → 「脸」的概率图（224 空间）。
    ///
    /// 一张脸只跑一次，不逐帧跑：512×512 的 BiSeNet 在 A13 上是几百毫秒到一秒的量级，
    /// 而遮罩在 224 空间里对同一张脸几乎不变（那 5 个点是对齐摆正的，语义布局跟着脸走）。
    /// 真机那一次的钱由调用方按脸缓存（SwapMaskCache），这里只管算。
    func parse(att224_01: [Float]) -> (prob224: [Float], ms: Double, note: String) {
        let pc = SwapNets.parseSize, s = SwapGeo.size
        let t0 = DispatchTime.now().uptimeNanoseconds
        // 224 → 512 双线性放大（照 cv2.resize 的半像素口径）＋ ImageNet 归一化
        guard let big = SwapGeo.upscalePlanar(att224_01, from: s, to: pc) else {
            return ([], 0, "分割网：224 那张放大到 \(pc) 失败")
        }
        let (fv, how) = feature(self.parse, name: contract.parseInput, planar01: big,
                                mean: SwapNets.arcMean, std: SwapNets.arcStd)
        guard let av = fv else { return ([], 0, "分割网喂不进：\(how)") }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [contract.parseInput: av]) else {
            return ([], 0, "分割网输入字典装不起来")
        }
        guard let res = try? self.parse.prediction(from: provider) else {
            return ([], Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000, "分割网 predict 抛错（\(how)）")
        }
        guard let arr = res.featureValue(for: contract.parseOutput)?.multiArrayValue else {
            return ([], Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000,
                    "分割网输出取不出来（\(contract.parseOutput)）")
        }
        guard let prob512 = SwapRunner.faceProb(arr, classes: SwapNets.parseFaceClasses) else {
            return ([], Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000,
                    "分割网输出认不出（形状 \(arr.shape.map { $0.intValue })｜类型 \(arr.dataType.rawValue)｜要 [1,19,512,512] 的 float32 且行优先连续）")
        }
        // 512 → 224 双线性（cv2.INTER_LINEAR 那一档）
        let prob224 = SwapGeo.resizeBilinear(prob512, from: pc, to: s)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        parseMs.append(ms)
        return (prob224, ms, "")
    }

    /// 19 类 logits → 「脸类概率图」（512×512）。
    /// 整个 19×512×512 不摊成 Swift 数组（那是 500 万个数＝20 MB 的临时开销），
    /// 只留最后那一张 512×512；softmax 按像素做（先减掉该像素的最大值再取 exp，数值上稳）。
    private static func faceProb(_ arr: MLMultiArray, classes faceClasses: [Int]) -> [Float]? {
        let dims = arr.shape.map { $0.intValue }
        guard dims.count == 4, dims[0] == 1, dims[1] == SwapNets.parseClassCount,
              dims[2] == dims[3] else { return nil }
        // 下面直接按 Float 读裸指针：出参不是 float32 的话读出来是乱数（转换是 fp32，但这条得钉死）
        guard arr.dataType == .float32 else { return nil }
        let n = dims[2] * dims[3]
        let cls = dims[1]
        guard isContiguous(arr, dims: dims) else { return nil }
        let base = arr.dataPointer.assumingMemoryBound(to: Float.self)
        var isFace = [Bool](repeating: false, count: cls)
        for c in faceClasses where c >= 0 && c < cls { isFace[c] = true }
        var mx = [Float](repeating: 0, count: n)
        var den = [Float](repeating: 0, count: n)
        var num = [Float](repeating: 0, count: n)
        mx.withUnsafeMutableBufferPointer { mp in
            for c in 0..<cls {
                let p = base + c * n
                if c == 0 {
                    for i in 0..<n { mp[i] = p[i] }
                } else {
                    for i in 0..<n { if p[i] > mp[i] { mp[i] = p[i] } }
                }
            }
        }
        den.withUnsafeMutableBufferPointer { dp in
            num.withUnsafeMutableBufferPointer { np in
                mx.withUnsafeBufferPointer { mp in
                    for c in 0..<cls {
                        let p = base + c * n
                        let f = isFace[c]
                        for i in 0..<n {
                            let e = expf(p[i] - mp[i])
                            dp[i] += e
                            if f { np[i] += e }
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = den[i] > 1e-20 ? num[i] / den[i] : 0 }
        return out
    }

    func statsLine() -> String {
        "身份证 \(SwapUtil.stat(identityMs))｜权重生成 \(SwapUtil.stat(genMs))｜逐帧 \(SwapUtil.stat(frameMs))"
            + "｜分割 \(SwapUtil.stat(parseMs))"
    }
}

/// 分割网那一趟的缓存：遮罩按脸缓存，不逐帧重跑。
///
/// 为什么能缓存：那 5 个点是对齐摆正的，同一张脸在 224 空间里的语义布局几乎不变，
/// 变了的那点（表情／光照）由 σ=2 那一层摊掉；真变了（转头、镜头切）由漂移那一格抓住。
/// 钱在这儿：分割网一跑是几百毫秒到一秒（本机 PC 上 512×512 一次 0.22 s，A13 上更慢），
/// 逐帧跑就把整片拖垮了。重跑的间隔按实测的 parse 耗时自己定：parseMs × 12 秒，
/// 那一趟多出来的开销 ≤ 8 %，而遮罩最多旧那么久。
final class SwapMaskCache {
    private var alpha: [Float] = []            // 399×224 的成品 alpha
    private var sig: [Float] = []              // 算出这一份遮罩那一帧的签名
    private var curSig: [Float] = []           // 这一帧的签名（算一次，两处用）
    private var lastAt: Double = -1e9          // 上一次 parse 时的素材秒数
    private var lastParseMs: Double = 0
    private(set) var parses = 0
    private(set) var lastDrift: Double = 0

    /// 签名漂过这一格就重跑（转头、镜头切）。表情／光照那一档动不了这么多。
    static let driftGate = 0.05

    var ready: Bool { !alpha.isEmpty }

    /// 要不要为这一帧重跑分割网
    func wantsParse(att: [Float], at sec: Double) -> Bool {
        curSig = SwapMaskCache.signature(att)
        guard !alpha.isEmpty else { return true }
        var sum = 0.0
        for i in 0..<sig.count { sum += abs(Double(sig[i] - curSig[i])) }
        let d = sig.isEmpty ? 1.0 : sum / Double(sig.count)
        lastDrift = d
        let gap = max(0.5, lastParseMs / 1000)
        if d > SwapMaskCache.driftGate, sec - lastAt > gap { return true }
        let interval = max(3.0, lastParseMs / 1000 * 12)
        return sec - lastAt > interval
    }

    /// 算出来的那一份收下
    func commit(_ newAlpha: [Float], at sec: Double, ms: Double) {
        alpha = newAlpha
        sig = curSig.isEmpty ? [] : curSig
        curSig = []
        lastAt = sec
        lastParseMs = ms
        parses += 1
    }

    /// 这一帧用的遮罩（没算过就是空的）
    func current() -> [Float] { alpha }

    /// 对齐 224 那张的签名：16×16 的亮度块均值（照得见姿态与构图，看不见身份）
    static func signature(_ att: [Float]) -> [Float] {
        let s = SwapGeo.size, k = s / 16, plane = s * s
        var out = [Float](repeating: 0, count: 256)
        att.withUnsafeBufferPointer { p in
            for by in 0..<16 {
                for bx in 0..<16 {
                    var sum: Float = 0
                    for y in (by * k)..<((by + 1) * k) {
                        for x in (bx * k)..<((bx + 1) * k) {
                            let i = y * s + x
                            sum += 0.299 * p[i] + 0.587 * p[plane + i] + 0.114 * p[2 * plane + i]
                        }
                    }
                    out[by * 16 + bx] = sum / Float(k * k)
                }
            }
        }
        return out
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
