import Foundation
import CoreML
import CoreVideo

/// fsx 那条链路的两张网：脸向量网（112 出 512 维身份证）＋ hyperswap_1a_256（256 进 256 出）。
/// 换脸网这一格收的就是那张归一化过的 512 维向量本身，不再乘 latent 矩阵——
/// inswapper 那套 emap 是它自己图上的安排；这一张网没有那一步，喂 emap 出来的东西它不认识。
enum FsxNets {
    static let arcResource = "fsx_arc"
    static let swapResource = "fsx_swap"
    static let embDim = 512
    static let side112 = 112
    static let sideSwap = 256

    /// arcface 那一路的归一化：手里是 0..1 的 planar，先还原成 0..255 再走 PC 那一式 (x−127.5)/127.5
    static func normalizeArc(_ v: Float) -> Float { (v * 255.0 - 127.5) / 127.5 }

    /// 换脸网那一路：mean 0.5／std 0.5，0..1 的 planar 进去就是 2x−1
    static func normalizeSwap(_ v: Float) -> Float { v * 2.0 - 1.0 }

    /// 把模型自己声明的入参/出参打印成人能读的一行（对账全靠它）
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

    static func dtypeName(_ t: MLMultiArrayDataType) -> String {
        switch t {
        case .float16: return "f16"
        case .float32: return "f32"
        case .float64: return "f64"
        case .int32: return "i32"
        @unknown default: return "?\(t.rawValue)"
        }
    }
}

/// 一次换脸的运行时：两张网都装好、当前身份的向量在手，逐帧只剩「裁 256 → 一次前向 → 贴回」。
/// 只能在调用方的后台线程上用：装包那一步现场编译可能几分钟，绝不在主线程。
final class FsxEngine {
    let arc: MLModel
    let swap: MLModel
    let loadNote: String

    struct Contract {
        let arcInput: String
        let arcOutput: String
        let swapTarget: String
        let swapSource: String
        let swapOutput: String
    }
    let contract: Contract

    /// 当前这个人的向量（512 维，已归一化）。这一格收的就是它本身，不再过 emap。
    private var latent: [Float] = []
    private(set) var identityEmb: [Float] = []

    private(set) var arcMs: [Double] = []
    private(set) var swapMs: [Double] = []

    // MARK: - 装网

    /// 只用盘上那一份（Documents/swap_models，模型单独下载到手机上的那份 mlpackage，现场编译）。
    /// 这一版没有「包里还塞着老四张」那条退路：退路只会把人引回已经被否掉的那条链路。
    ///
    /// 编好的那一份挪进 Caches 复用：compileModel 每一趟都要把 527 MB 那一张整包重编，编完扔在临时目录里，
    /// 跑第二次还是同样的分钟数——这一段钱跟画面质量一点关系都没有，纯是白烧。
    /// 缓存按模型版本分目录（version.txt 那一串），重下模型版本一变，旧目录自然不再命中。
    static func locate(_ resource: String) -> (url: URL?, note: String) {
        guard let p = SwapStore.local(resource) else {
            return (nil, "\(resource) 盘上没有（Documents/swap_models 里没这一份），得先下模型")
        }
        if let hit = compiledDir(resource) {
            return (hit, "\(resource) 用编好的那一份（版本 \(SwapStore.localVersion())），不重编")
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            let c = try MLModel.compileModel(at: p)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            let kept = stash(c, resource)
            return (kept ?? c, "\(resource) 现场编译 \(SwapUtil.ms(ms))"
                + (kept == nil ? "｜缓存没挪动，这趟先用临时那一份" : "｜已存进缓存"))
        } catch {
            return (nil, "\(resource) 现场编译失败: \(error)")
        }
    }

    /// 缓存目录的本名（还没建出来也返回路径，挪进去那一步要建）
    private static func cacheDir(_ resource: String) -> URL? {
        let v = SwapStore.localVersion()
        guard !v.isEmpty,
              let c = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return c.appendingPathComponent("compiled/\(v)/\(resource).mlmodelc", isDirectory: true)
    }

    /// 命中＝目录在且不是空的（空的可能是上一趟挪到一半被系统清了）
    private static func compiledDir(_ resource: String) -> URL? {
        guard let d = cacheDir(resource),
              let e = try? FileManager.default.contentsOfDirectory(atPath: d.path), !e.isEmpty
        else { return nil }
        return d
    }

    private static func stash(_ url: URL, _ resource: String) -> URL? {
        let fm = FileManager.default
        guard let d = cacheDir(resource) else { return nil }
        try? fm.removeItem(at: d)
        try? fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? fm.moveItem(at: url, to: d)) != nil, fm.fileExists(atPath: d.path) else { return nil }
        return d
    }

    /// 换模型版本后，旧版本编好的那几份不再命中，却还占着 Caches（一份包编出来也是几百 MB）。
    /// 留着两份就是双倍占用，A13 上会直接影响下一趟装包，所以版本一对不上就删。
    private static func dropOldCompiled() {
        guard let c = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let root = c.appendingPathComponent("compiled", isDirectory: true)
        let v = SwapStore.localVersion()
        guard !v.isEmpty,
              let all = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }
        for u in all where u.lastPathComponent != v {
            try? FileManager.default.removeItem(at: u)
        }
    }

    static func load(units: MLComputeUnits, onLine: @escaping (String) -> Void) -> (engine: FsxEngine?, note: String) {
        var note = ""
        if !SwapStore.haveAll() {
            onLine("模型 盘上没有这一份，先下（第一次是几百 MB，要等一会儿）")
            let g = SwapStore.ensure(force: false, onLine: onLine)
            onLine("模型 \(g.note)")
            if !g.ok { return (nil, "模型 没下下来：\(g.note)") }
        }
        dropOldCompiled()
        var made: [String: MLModel] = [:]
        for res in [FsxNets.arcResource, FsxNets.swapResource] {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = units
            var found = locate(res)
            for attempt in 0..<2 {
                note += "\(res): \(found.note)\n"
                onLine("\(res): \(found.note)")
                guard let url = found.url else { break }
                let t0 = DispatchTime.now().uptimeNanoseconds
                do {
                    let m = try MLModel(contentsOf: url, configuration: cfg)
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                    let line = "  \(res) 装包 \(SwapUtil.ms(ms))｜足迹 \(SwapFacts.footprintMB()) MB｜\(FsxNets.describe(m))"
                    note += line + "\n"
                    onLine(line)
                    made[res] = m
                    break
                } catch {
                    note += "  \(res) 装包失败: \(error)\n"
                    onLine("  \(res) 装包失败: \(error)")
                    // 缓存那一份装不上＝系统升级把编好的格式换了这类事；扔掉重编一趟，
                    // 不能让人从此每一趟都卡在这儿（手机上没有手动清缓存的入口）
                    guard attempt == 0, let d = cacheDir(res), d.path == url.path else { break }
                    try? FileManager.default.removeItem(at: d)
                    onLine("  \(res) 缓存那一份装不上，删掉重编")
                    found = locate(res)
                }
            }
        }
        guard let a = made[FsxNets.arcResource], let s = made[FsxNets.swapResource] else {
            let got = made.keys.sorted().joined(separator: "／")
            return (nil, note + "两张网没凑齐（装上的是 \(got)），这一版出不了片")
        }
        let got = FsxEngine.contract(arc: a, swap: s)
        onLine("接口对账: \(got.note)")
        guard let c = got.value else { return (nil, note + "接口对账：\(got.note)\n") }
        note += "接口对账：\(got.note)\n"
        return (FsxEngine(arc: a, swap: s, loadNote: note, contract: c), note)
    }

    /// 名字按声明的元素数认领，不认顺序：
    /// 换脸那一张有两个入参（256 的图和 512 的向量），光看名字（target/source）转换器一改就认不出，
    /// 认反了两张网照样跑、不报错，只是画面是错的——所以只认形状，认不出就拒绝出片。
    /// 声明成 image 型的也拒绝：那一路的归一化是编译期烘进包的，喂法完全不同，
    /// 这一版对账用的是张量口径，包要是变成 image 就回去改转换配方，不在手机上猜。
    static func contract(arc: MLModel, swap: MLModel) -> (value: Contract?, note: String) {
        var err: [String] = []
        func tot(_ md: MLFeatureDescription) -> Int? {
            guard md.type == .multiArray, let c = md.multiArrayConstraint else { return nil }
            return c.shape.reduce(1) { $0 * $1.intValue }
        }
        func findIn(_ m: MLModel, want: Int) -> String? {
            let d = m.modelDescription.inputDescriptionsByName
            for n in d.keys.sorted() where tot(d[n]!) == want { return n }
            return nil
        }
        func findOut(_ m: MLModel, want: Int) -> String? {
            let d = m.modelDescription.outputDescriptionsByName
            for n in d.keys.sorted() where tot(d[n]!) == want { return n }
            return nil
        }
        let arcTot = 3 * FsxNets.side112 * FsxNets.side112
        let swTot = 3 * FsxNets.sideSwap * FsxNets.sideSwap
        func listed(_ m: MLModel, _ ins: Bool) -> String {
            let d = m.modelDescription
            let k = (ins ? d.inputDescriptionsByName : d.outputDescriptionsByName).keys.sorted()
            return k.map { n -> String in
                let dd = (ins ? d.inputDescriptionsByName : d.outputDescriptionsByName)[n]!
                if dd.type == .image { return "\(n)=image" }
                return "\(n)=\(tot(dd) ?? -1)"
            }.joined(separator: " ")
        }
        guard let ai = findIn(arc, want: arcTot) else {
            err.append("向量网找不到 \(arcTot) 个数那个入参（实际入 \(listed(arc, true))）")
            return (nil, err.joined(separator: "；"))
        }
        guard let ao = findOut(arc, want: FsxNets.embDim) else {
            err.append("向量网找不到 512 那个出参（实际出 \(listed(arc, false))）")
            return (nil, err.joined(separator: "；"))
        }
        guard let st = findIn(swap, want: swTot) else {
            err.append("换脸网找不到 \(swTot) 个数那个入参（实际入 \(listed(swap, true))）")
            return (nil, err.joined(separator: "；"))
        }
        guard let sl = findIn(swap, want: FsxNets.embDim) else {
            err.append("换脸网找不到 512 那个入参（身份向量喂不进去）")
            return (nil, err.joined(separator: "；"))
        }
        guard let so = findOut(swap, want: swTot) else {
            err.append("换脸网找不到 \(swTot) 个数那个出参（实际出 \(listed(swap, false))）")
            return (nil, err.joined(separator: "；"))
        }
        let c = Contract(arcInput: ai, arcOutput: ao, swapTarget: st, swapSource: sl, swapOutput: so)
        return (c, "arc 入 \(ai)→出 \(ao)｜swap 入 \(st)+\(sl)→出 \(so)")
    }

    init(arc: MLModel, swap: MLModel, loadNote: String, contract: Contract) {
        self.arc = arc
        self.swap = swap
        self.loadNote = loadNote
        self.contract = contract
    }

    // MARK: - 喂与读

    /// 喂进去之前要对 0..1 的 planar 做哪一式：两张网的口径不一样，混了画面不会报错、只是不对。
    private enum Scale {
        case raw        // 原样喂（512 那路已经归一化过）
        case arc        // (x·255−127.5)/127.5
        case swap       // (x−0.5)/0.5
    }

    /// planar 数组 → 模型声明的那个形状和类型。
    private func value(_ model: MLModel, name: String, planar: [Float], scale: Scale)
        -> (MLFeatureValue?, String) {
        guard let d = model.modelDescription.inputDescriptionsByName[name] else {
            return (nil, "\(name) 没有输入描述")
        }
        guard d.type == .multiArray, let c = d.multiArrayConstraint else {
            return (nil, "\(name) 声明成 image 型（类型 \(d.type.rawValue)）：这一版不会喂，得回去改转换配方")
        }
        let dims = c.shape.map { $0.intValue }
        let total = dims.reduce(1, *)
        guard total == planar.count else {
            return (nil, "\(name) 要 \(total) 个数（\(dims)），手里 \(planar.count) 个")
        }
        guard let arr = try? MLMultiArray(shape: dims.map { NSNumber(value: $0) }, dataType: c.dataType)
        else { return (nil, "\(name) 建不出 MLMultiArray \(dims)") }
        var v = planar
        switch scale {
        case .arc:
            for i in 0..<v.count { v[i] = FsxNets.normalizeArc(v[i]) }
        case .swap:
            for i in 0..<v.count { v[i] = FsxNets.normalizeSwap(v[i]) }
        case .raw:
            break
        }
        switch c.dataType {
        case .float32:
            if isContiguous(arr, dims: dims) {
                v.withUnsafeBufferPointer { src in
                    memcpy(arr.dataPointer, src.baseAddress!, total * MemoryLayout<Float32>.size)
                }
            } else {
                let p = arr.dataPointer.assumingMemoryBound(to: Float32.self)
                strideWalk(arr, dims: dims) { off, i in p[off] = v[i] }
            }
        case .float16:
            let p = arr.dataPointer.assumingMemoryBound(to: Float16.self)
            strideWalk(arr, dims: dims) { off, i in p[off] = Float16(v[i]) }
        case .float64:
            let p = arr.dataPointer.assumingMemoryBound(to: Double.self)
            strideWalk(arr, dims: dims) { off, i in p[off] = Double(v[i]) }
        case .int32:
            let p = arr.dataPointer.assumingMemoryBound(to: Int32.self)
            strideWalk(arr, dims: dims) { off, i in p[off] = Int32(v[i]) }
        @unknown default:
            return (nil, "\(name) 的数组类型 \(c.dataType.rawValue) 我还不会填")
        }
        return (MLFeatureValue(multiArray: arr), "\(name) 按 \(dims)/\(FsxNets.dtypeName(c.dataType)) 喂")
    }

    /// 行优先连续（每一维的 stride 等于后面各维元素数之积）才敢整段 memcpy。
    /// 认错了不报错、只把画面搬乱，所以每次读回来都要对一遍。
    private func isContiguous(_ arr: MLMultiArray, dims: [Int]) -> Bool {
        let st = arr.strides.map { $0.intValue }
        guard st.count == dims.count, st.last == 1 else { return false }
        var expect = 1
        for k in stride(from: dims.count - 1, through: 0, by: -1) {
            if st[k] != expect { return false }
            expect *= dims[k]
        }
        return expect == dims.reduce(1, *)
    }

    /// 非连续那一档：下标按行优先一个个走（里程表进位），每个下标乘它自己的 stride。
    /// 连续时这式就退化成顺序读，所以调用方先走 memcpy 那条快路。
    private func strideWalk(_ arr: MLMultiArray, dims: [Int], _ body: (_ off: Int, _ i: Int) -> Void) {
        let n = dims.reduce(1, *)
        let st = arr.strides.map { $0.intValue }
        var pos = [Int](repeating: 0, count: dims.count)
        var off = 0
        for i in 0..<n {
            body(off, i)
            var d = dims.count - 1
            while d >= 0 {
                pos[d] += 1
                off += st[d]
                if pos[d] < dims[d] { break }
                off -= dims[d] * st[d]
                pos[d] = 0
                d -= 1
            }
        }
    }

    /// 模型回来的数组 → [Float]（出参可能是 f16，也可能不是连续的）
    private func readOut(_ model: MLModel, name: String, feat: MLFeatureValue?) -> (v: [Float], note: String) {
        guard let arr = feat?.multiArrayValue else {
            let t = feat.map { "类型\($0.type.rawValue)" } ?? "这个出参整个没有"
            return ([], "\(name) 没回 multiArray（\(t)）")
        }
        let dims = arr.shape.map { $0.intValue }
        let n = dims.reduce(1, *)
        var out = [Float](repeating: 0, count: n)
        let cont = isContiguous(arr, dims: dims)
        switch arr.dataType {
        case .float32:
            let p = arr.dataPointer.assumingMemoryBound(to: Float32.self)
            if cont {
                memcpy(&out, p, n * MemoryLayout<Float32>.size)
            } else {
                strideWalk(arr, dims: dims) { off, i in out[i] = p[off] }
            }
        case .float16:
            let p = arr.dataPointer.assumingMemoryBound(to: Float16.self)
            if cont {
                for i in 0..<n { out[i] = Float(p[i]) }
            } else {
                strideWalk(arr, dims: dims) { off, i in out[i] = Float(p[off]) }
            }
        case .float64:
            let p = arr.dataPointer.assumingMemoryBound(to: Double.self)
            strideWalk(arr, dims: dims) { off, i in out[i] = Float(p[off]) }
        case .int32:
            let p = arr.dataPointer.assumingMemoryBound(to: Int32.self)
            strideWalk(arr, dims: dims) { off, i in out[i] = Float(p[off]) }
        @unknown default:
            return ([], "\(name) 的类型 \(arr.dataType.rawValue) 还不会读")
        }
        return (out, "\(name) 回来 \(dims.map { String($0) }.joined(separator: "x"))/\(FsxNets.dtypeName(arr.dataType))")
    }

    // MARK: - 三步

    /// ① 身份证：112 的 planar RGB 0..1 → 512 维单位向量。
    /// 原始模长也带回来：归一化之后谁都看不出，只有模长能露「喂的口径错了」这种馅（PC 参照 2.84~3.72）。
    func embedding(crop112_01: [Float]) -> (emb: [Float], rawNorm: Double, ms: Double, note: String) {
        guard crop112_01.count == 3 * FsxNets.side112 * FsxNets.side112 else {
            return ([], 0, 0, "112 裁片个数不对（\(crop112_01.count)）")
        }
        let vr = value(arc, name: contract.arcInput, planar: crop112_01, scale: .arc)
        guard let fv = vr.0 else { return ([], 0, 0, vr.1) }
        guard let inp = try? MLDictionaryFeatureProvider(dictionary: [contract.arcInput: fv]) else {
            return ([], 0, 0, "\(vr.1)｜建不进输入")
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            let out = try arc.prediction(from: inp)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            let r = readOut(arc, name: contract.arcOutput, feat: out.featureValue(for: contract.arcOutput))
            guard r.v.count >= FsxNets.embDim else { return ([], 0, ms, r.note) }
            var e = Array(r.v[0..<FsxNets.embDim])
            let raw = FsxEngine.norm(e)
            if raw > 1e-9 {
                let sc = Float(1.0 / raw)
                for i in 0..<e.count { e[i] *= sc }
            }
            arcMs.append(ms)
            return (e, raw, ms, r.note)
        } catch {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            return ([], 0, ms, "向量网抛错：\(error)")
        }
    }

    /// ② 装当前身份：512 维单位向量原样留着（每人一次，整片共用）。
    /// 这一张网收的就是归一化后的向量本身；inswapper 那一步 emb@emap 是它自己图上的安排，这里没有。
    @discardableResult
    func useIdentity(emb: [Float]) -> Bool {
        guard emb.count == FsxNets.embDim else { return false }
        let n = FsxEngine.norm(emb)
        guard n > 1e-9 else { return false }
        latent = emb.map { Float(Double($0) / n) }
        identityEmb = emb
        return true
    }

    var hasIdentity: Bool { latent.count == FsxNets.embDim }

    /// ③ 一次换脸：256 的 planar RGB 0..1 → 换出来的那张脸（planar RGB 0..1）。
    /// 这一张网的出参是带符号的（mean 0.5／std 0.5 口径，PC 实测 −0.999..1.000），
    /// 先 y·0.5+0.5 还原回 0..1，再按 PC 那一式截断到 8 位（clip 后 astype(uint8) 是向下取整，不是四舍五入）。
    /// 非有限数（NaN/inf）单独报数：fp16 装的那一份要是栽在这一格上，画面会是一片黑，必须当场看见。
    func swap(cropSwap_01: [Float]) -> (face: [Float], ms: Double, note: String) {
        guard hasIdentity else { return ([], 0, "还没装身份（先 useIdentity）") }
        let side = FsxNets.sideSwap
        guard cropSwap_01.count == 3 * side * side else {
            return ([], 0, "\(side) 裁片个数不对（\(cropSwap_01.count)）")
        }
        let vt = value(swap, name: contract.swapTarget, planar: cropSwap_01, scale: .swap)
        guard let t = vt.0 else { return ([], 0, vt.1) }
        let vs = value(swap, name: contract.swapSource, planar: latent, scale: .raw)
        guard let s = vs.0 else { return ([], 0, vs.1) }
        guard let inp = try? MLDictionaryFeatureProvider(
            dictionary: [contract.swapTarget: t, contract.swapSource: s]) else {
            return ([], 0, "\(vt.1)＋\(vs.1)｜建不进输入")
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            let out = try swap.prediction(from: inp)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            let r = readOut(swap, name: contract.swapOutput,
                            feat: out.featureValue(for: contract.swapOutput))
            let want = 3 * side * side
            guard r.v.count >= want else { return ([], ms, r.note) }
            var f = Array(r.v[0..<want])
            var bad = 0
            for i in 0..<f.count {
                if !f[i].isFinite { bad += 1; f[i] = 0 }
                let v = max(0.0, min(1.0, Double(f[i]) * 0.5 + 0.5))
                f[i] = Float(floor(v * 255.0) / 255.0)
            }
            swapMs.append(ms)
            var note = r.note
            if bad > 0 { note += "｜非有限数 \(bad) 个（这张包的这一格不对，画面会有一片黑）" }
            return (f, ms, note)
        } catch {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            return ([], ms, "换脸网抛错：\(error)")
        }
    }

    static func norm(_ v: [Float]) -> Double {
        var s = 0.0
        for x in v { s += Double(x) * Double(x) }
        return s.squareRoot()
    }

    /// 单价一行（进流水）：这两张网各跑过几次、平均多少钱
    func statsLine() -> String {
        "向量网 \(arcMs.count) 次｜换脸网 \(swapMs.count) 次｜"
            + "换脸 avg \(SwapUtil.stat(swapMs))｜身份证 avg \(SwapUtil.stat(arcMs))"
    }
}

/// 身份那把尺：余弦和「量不出」的三种来路。
enum FsxMath {
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
    /// 只印 -9.000 的话这三种在机上分不开，「已存的人」那条路的账就永远结不了。
    static func whyNot(_ v: Double, _ a: [Float], _ b: [Float]) -> String {
        guard v < -8 else { return "不是量不出" }
        if a.isEmpty { return "这边没回话" }
        if b.isEmpty { return "那边是空的" }
        if a.count != b.count { return "维度 \(a.count) vs \(b.count)" }
        var na = 0.0, nb = 0.0
        for i in 0..<a.count {
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        if na <= 1e-12 { return "这边全零（模长 0）" }
        if nb <= 1e-12 { return "那边全零（模长 0）" }
        return "两条都正常却没回数"
    }
}
