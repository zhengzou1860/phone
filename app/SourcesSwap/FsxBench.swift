import CoreML
import Foundation

/// 一按把界面上那四档算力逐档量一遍。
/// 为什么要有这一按：0.38 上机每帧 1230 ms，钱全在换脸网那一次前向（avg 1157／中位 1114 ms），
/// 检测 22＋裁 128 那 0.3＋贴回 50 加起来才七十几个毫秒——慢的不是手机的几何，是 units=all 这一档
/// CoreML 自己挑的硬件。挑对了没有，光看一个数判不出来；四档各装各跑一遍才有得比。
/// 每一档都要重新装一次那两张网（换脸网单张装包 5～6.5 s、足迹 726 MB），四档连着几十秒，
/// 只能在后台线程跑，而且一句一句往界面上递——不递的话这一趟看着就跟死机一样。
enum FsxBench {
    /// 名字跟界面上那格一字一样，量完直接照名字切
    static let arms: [(String, MLComputeUnits)] = [
        ("CPU(cpuOnly)", .cpuOnly),
        ("GPU(cpuAndGPU)", .cpuAndGPU),
        ("all", .all),
        ("ANE(cpuAndNeuralEngine)", .cpuAndNeuralEngine),
    ]
    /// 每档跑 5 格：第一格单独报（ANE 现编、GPU 首次调度那类钱都在第一格上），后面取均速
    static let passes = 5

    static func run(onLine: @escaping (String) -> Void) {
        guard SwapStore.haveAll() else {
            onLine("量速 没跑：盘上没有那两张网（先点「下模型」）")
            return
        }
        var best = (name: "", avg: Double.infinity)
        var allAvg: [String: Double] = [:]
        for arm in arms {
            let got = measure(arm.0, arm.1, onLine: onLine)
            if let a = got {
                allAvg[arm.0] = a
                if a < best.avg { best = (arm.0, a) }
            }
            waitRelease()
        }
        let mine = allAvg["all"]
        if best.avg.isFinite, let m = mine {
            onLine("量速 判决 最快是「\(best.name)」avg \(SwapUtil.ms(best.avg))"
                + (m > 1 ? "＝现在这一档（all \(SwapUtil.ms(m))）的 \(String(format: "%.1f", m / max(best.avg, 0.001))) 倍快" : "（和 all 同档）"))
        } else {
            onLine("量速 判决 四档里没有一档跑出数来（上面每档那句就是原因）")
        }
    }

    /// 一档的整趟：装网 → 装身份 → 跑 5 格。返回后面几格的均速（没跑成就 nil，原因已经递出去了）
    private static func measure(_ name: String, _ units: MLComputeUnits,
                                onLine: @escaping (String) -> Void) -> Double? {
        let (eng, note) = FsxEngine.load(units: units, onLine: onLine)
        guard let e = eng else {
            onLine("量速 \(name) 装不上：\(note.split(separator: "\n").last.map(String.init) ?? "没写上原因")")
            return nil
        }
        guard e.useIdentity(emb: fakeEmb()) else {
            onLine("量速 \(name) 身份装不上（emap 那一张乘不出来）")
            return nil
        }
        let side = FsxGeo.side128
        let crop = fakeCrop()
        var ms: [Double] = []
        for i in 0..<passes {
            let r = e.swap(crop128_01: crop)
            if r.face.count != 3 * side * side {
                onLine("量速 \(name) 第 \(i + 1) 格网没回话：\(r.note)")
                return nil
            }
            ms.append(r.ms)
            onLine("量速 \(name) 第 \(i + 1) 格 \(SwapUtil.ms(r.ms))｜足迹 \(SwapFacts.footprintMB()) MB")
        }
        let rest = Array(ms.dropFirst())
        guard !rest.isEmpty else { return nil }
        let avg = rest.reduce(0, +) / Double(rest.count)
        onLine("量速 \(name)｜首次 \(SwapUtil.ms(ms[0])｜后面 \(rest.count) 格 avg \(SwapUtil.ms(avg))"
            + "／最快 \(SwapUtil.ms(rest.min() ?? 0))／最慢 \(SwapUtil.ms(rest.max() ?? 0))")
        return avg
    }

    /// 全 0 的裁片会让逐元素那几步走得偏便宜，拿一张有内容的图量才诚实
    private static func fakeCrop() -> [Float] {
        let side = FsxGeo.side128
        let plane = side * side
        var v = [Float](repeating: 0, count: 3 * plane)
        for i in 0..<plane {
            v[i] = Float(i % 97) / 97.0
            v[plane + i] = Float((i * 7) % 89) / 89.0
            v[2 * plane + i] = Float((i * 13) % 83) / 83.0
        }
        return v
    }

    private static func fakeEmb() -> [Float] {
        var e = [Float](repeating: 0, count: FsxNets.embDim)
        for i in 0..<FsxNets.embDim { e[i] = Float((i * 31) % 251) / 251.0 - 0.5 }
        return e
    }

    /// 这一档的两张网要真交出去再装下一档：两份 726 MB 同时在手里不是慢，是被系统当场杀掉
    private static func waitRelease() {
        var spins = 0
        while SwapFacts.footprintMB() > 260 && spins < 40 {
            Thread.sleep(forTimeInterval: 0.25)
            spins += 1
        }
    }
}
