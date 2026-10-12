import Foundation
import CoreML
import UIKit

/// 换脸逐帧网（MobileFaceSwapUNetRuntime 转出来的 CoreML）在 A13 上到底：
/// 认不认（四个 compute unit 谁接得住）、编得开吗（现场 compileModel）、一次多少钱、
/// 各 unit 出来的数是否一致（fp16 那条路会不会偷偷改画质）。
/// 身份那 18 个权重张量喂的是小随机数：这一版只判速度和数值，不判长相
/// （真要长相得连 arcface + BuildFaceSwap 两张大网一起上包，那是下一版）。
enum SwapBench {
    static let resource = "mfs_unet"

    static var seed: UInt64 = 0x9E3_779B9_7F4A_7C15

    static func rand01() -> Double {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return Double(seed % 100_000) / 100_000.0
    }

    static var cachedLocate: (url: URL?, note: String)?

    static func locate() -> (url: URL?, note: String) {
        if let c = cachedLocate { return c }
        let fm = FileManager.default
        let found: (url: URL?, note: String)
        if let u = Bundle.main.url(forResource: resource, withExtension: "mlmodelc") {
            found = (u, "包里带的是已编译 mlmodelc")
        } else {
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
            if let p = pkg {
                let t0 = DispatchTime.now().uptimeNanoseconds
                do {
                    let c = try MLModel.compileModel(at: p)
                    found = (c, "包里是 mlpackage，A13 现场编译成功（\(SwapUtil.ms(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000))）")
                } catch {
                    found = (nil, "mlpackage 现场编译失败: \(error)")
                }
            } else {
                found = (nil, "包里没有 \(resource).mlmodelc 也没有 \(resource).mlpackage")
            }
        }
        cachedLocate = found
        return found
    }

    /// 按模型自己声明的输入形状造数据。19 个输入里只有那张 1×3×224×224 是"逐帧变"的，
    /// 其余 18 个是身份权重（每人一次）⇒ 权重只造一份，图像造 count 份轮换，
    /// 免得同一张输入反复 predict 命中缓存把单价测低。
    static func makeInputs(_ model: MLModel, count: Int) -> (list: [MLFeatureProvider], note: String) {
        let md = model.modelDescription
        let names = md.inputDescriptionsByName.keys.sorted()
        guard !names.isEmpty else { return ([], "模型一个输入描述都没有") }

        var fixed: [String: MLFeatureValue] = [:]
        var frameName = ""
        var frameValue: MLFeatureValue?
        var shapes: [String] = []

        for n in names {
            guard let d = md.inputDescriptionsByName[n] else { continue }
            if d.type == .multiArray, let c = d.multiArrayConstraint {
                let dims = c.shape.map { max(1, $0.intValue) }
                let total = dims.reduce(1, *)
                let arr: MLMultiArray
                do {
                    arr = try MLMultiArray(shape: dims.map { NSNumber(value: $0) }, dataType: c.dataType)
                } catch {
                    return ([], "造 MLMultiArray 失败 \(n) dims=\(dims): \(error)")
                }
                // 图像那张的真实定义域是 [0,1]；权重给小随机数，避免中间值溢出成 inf/NaN
                let isFrame = dims.count == 4 && dims[1] == 3 && dims[2] >= 32
                let hi = isFrame ? 1.0 : 0.05
                if !fill(arr, total: total, hi: hi) {
                    return ([], "多数组 \(n) 元素类型 \(arr.dataType.rawValue) 我还不会填")
                }
                shapes.append("\(n)\(dims)")
                if isFrame {
                    frameName = n
                    frameValue = MLFeatureValue(multiArray: arr)
                } else {
                    fixed[n] = MLFeatureValue(multiArray: arr)
                }
            } else if d.type == .image {
                let ic = d.imageConstraint
                let w = (ic?.pixelsWide ?? 0) > 0 ? ic!.pixelsWide : 224
                let h = (ic?.pixelsHigh ?? 0) > 0 ? ic!.pixelsHigh : 224
                guard let v = pixelValue(width: w, height: h) else {
                    return ([], "输入 \(n) 是 image，但 \(w)x\(h) 的像素缓冲造不出来")
                }
                shapes.append("\(n) image \(w)x\(h)")
                frameName = n
                frameValue = v
            } else {
                return ([], "输入 \(n) 类型 \(d.type.rawValue) 我还不会喂")
            }
        }

        guard let fv = frameValue, !frameName.isEmpty else {
            return ([], "认不出哪张是逐帧输入（\(names.count) 个输入：\(shapes.joined(separator: " "))）")
        }
        var list: [MLFeatureProvider] = []
        for i in 0..<max(1, count) {
            var dict = fixed
            if i == 0 {
                dict[frameName] = fv
            } else {
                // 后面几份把图像再随机化一遍：逐帧输入每次都该是新内容
                guard let v = reRandomize(fv, name: frameName, model: model) else {
                    return (list, "第 \(i) 份重造逐帧输入失败")
                }
                dict[frameName] = v
            }
            do {
                list.append(try MLDictionaryFeatureProvider(dictionary: dict))
            } catch {
                return ([], "装输入字典失败（\(dict.count) 个键）: \(error)")
            }
        }
        return (list, "输入 \(names.count) 个｜逐帧=\(frameName)｜权重份数=\(fixed.count)｜\(shapes.joined(separator: " "))")
    }

    static func fill(_ arr: MLMultiArray, total: Int, hi: Double) -> Bool {
        let lo = -hi
        switch arr.dataType {
        case .float32:
            let p = arr.dataPointer.assumingMemoryBound(to: Float32.self)
            for i in 0..<total { p[i] = Float32(lo + rand01() * (hi - lo)) }
        case .float16:
            let p = arr.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<total { p[i] = Float16(lo + rand01() * (hi - lo)) }
        case .float64:
            let p = arr.dataPointer.assumingMemoryBound(to: Double.self)
            for i in 0..<total { p[i] = lo + rand01() * (hi - lo) }
        default:
            return false
        }
        return true
    }

    static func reRandomize(_ v: MLFeatureValue, name: String, model: MLModel) -> MLFeatureValue? {
        guard let old = v.multiArrayValue else { return v }
        let dims = old.shape.map { $0.intValue }
        let total = old.count
        guard let arr = try? MLMultiArray(shape: dims.map { NSNumber(value: $0) }, dataType: old.dataType)
        else { return nil }
        _ = name
        guard fill(arr, total: total, hi: 1.0) else { return nil }
        return MLFeatureValue(multiArray: arr)
    }

    static func pixelValue(width: Int, height: Int) -> MLFeatureValue? {
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        var pb: CVPixelBuffer?
        if CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                               attrs as CFDictionary, &pb) != noErr { return nil }
        guard let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        if let base = CVPixelBufferGetBaseAddress(buf) {
            let bytes = CVPixelBufferGetDataSize(buf)
            let p = base.assumingMemoryBound(to: UInt8.self)
            for i in 0..<bytes { p[i] = UInt8(rand01() * 255) }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return MLFeatureValue(pixelBuffer: buf)
    }

    static func predict(_ model: MLModel, inputs: [MLFeatureProvider], runs: Int) -> (ms: [Double], note: String) {
        var times: [Double] = []
        guard !inputs.isEmpty else { return (times, "没有输入可喂") }
        for i in 0..<runs {
            let f = inputs[i % inputs.count]
            let t0 = DispatchTime.now().uptimeNanoseconds
            do {
                _ = try model.prediction(from: f)
            } catch {
                return (times, "第 \(i) 次 predict 抛错: \(error)")
            }
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        }
        return (times, "-")
    }

    /// 输出的数值指纹：均值/极值/NaN 数。四个 unit 各留一行，谁跟谁不一致一眼看得出。
    static func digest(_ model: MLModel, inputs: [MLFeatureProvider]) -> String {
        guard let res = try? model.prediction(from: inputs[0]) else { return "predict 取不到输出" }
        let names = model.modelDescription.outputDescriptionsByName.keys.sorted()
        var parts: [String] = []
        for n in names {
            guard let v = res.featureValue(for: n), let arr = v.multiArrayValue else {
                parts.append("\(n)=取不到多数数组")
                continue
            }
            guard arr.dataType == .float32 else {
                parts.append("\(n) 维数 \(arr.count) 类型 \(arr.dataType.rawValue)")
                continue
            }
            let p = arr.dataPointer.assumingMemoryBound(to: Float32.self)
            let cnt = arr.count
            var mn = Float32.greatestFiniteMagnitude, mx = -Float32.greatestFiniteMagnitude
            var sum = 0.0, bad = 0
            for i in 0..<cnt {
                let x = p[i]
                if x.isNaN || x.isInfinite { bad += 1; continue }
                if x < mn { mn = x }
                if x > mx { mx = x }
                sum += Double(x)
            }
            let mean = cnt > 0 ? sum / Double(cnt - bad) : 0
            parts.append("\(n) 维数 \(cnt) 均值 \(String(format: "%.4f", mean))"
                         + " 范围 [\(String(format: "%.3f", mn)),\(String(format: "%.3f", mx))]"
                         + (bad > 0 ? " NaN/Inf \(bad) 个" : ""))
        }
        return parts.joined(separator: "｜")
    }

    static func probe(runs: Int, onLine: (String) -> Void) -> String {
        var out: [String] = []
        func emit(_ s: String) {
            out.append(s)
            onLine(s)
        }
        emit("换脸逐帧网自检｜权重喂随机数，只测速度与数值，不测长相")
        let found = locate()
        guard let modelURL = found.url else {
            emit("  " + found.note)
            return out.joined(separator: "\n")
        }
        emit("  " + found.note)
        let units: [(String, MLComputeUnits)] = [
            ("ANE(cpuAndNeuralEngine)", .cpuAndNeuralEngine),
            ("GPU(cpuAndGPU)", .cpuAndGPU),
            ("all", .all),
            ("CPU(cpuOnly)", .cpuOnly),
        ]
        for u in units {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = u.1
            let t0 = DispatchTime.now().uptimeNanoseconds
            guard let model = try? MLModel(contentsOf: modelURL, configuration: cfg) else {
                emit("  \(u.0): 加载失败")
                continue
            }
            let loadMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            let made = makeInputs(model, count: 8)
            guard !made.list.isEmpty else {
                emit("  \(u.0): 加载 \(SwapUtil.ms(loadMs))，但\(made.note)")
                continue
            }
            _ = predict(model, inputs: made.list, runs: 5)
            let timed = predict(model, inputs: made.list, runs: runs)
            let med = timed.ms.sorted().isEmpty ? Double.nan
                : timed.ms.sorted()[timed.ms.sorted().count / 2]
            emit("  \(u.0): 加载 \(SwapUtil.ms(loadMs))｜正式 \(runs) 次 \(SwapUtil.stat(timed.ms))"
                 + "｜足迹\(SwapFacts.footprintMB())MB")
            if !med.isNaN {
                emit("      \(runs) 帧总墙钟 \(String(format: "%.1f", med * Double(runs) / 1000)) s"
                     + "｜300 帧（≈10 s 素材）\(String(format: "%.0f", med * 300 / 1000)) s")
            }
            if timed.note != "-" { emit("      \(timed.note)") }
            emit("      \(made.note)")
            emit("      \(digest(model, inputs: made.list))")
        }
        emit("  对照：本机 PC（i7-4790，8 线程）纯网络 56 ms/帧；检测在剪辑线已实测 14~16 ms/帧")
        return out.joined(separator: "\n")
    }
}
