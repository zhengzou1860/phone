import Foundation

/// 链外的旋钮：音调。
///
/// 为什么在链外：MeanVC 的输出帧数和源内容的帧数是逐帧对齐的（源 1340 帧 mel → 出 13.40 s），
/// 官方 infer 脚本能调的全部参数只有 --steps / --chunk-size / --seed，**没有语速也没有音调**。
/// 所以音调只能加在 ④ 声码之后的波形上，性质是"事后移调"，别当成模型能力。
///
/// 语速本来同一条路上做了一半，用户判"播放器都有"，界面和入口都撤了；
/// timeStretch 留着，因为 pitchShift 就是「先重采样升调、再 WSOLA 拉回原时长」，它现在是内部步骤。
///
/// 为什么自己写 WSOLA 而不用 AVAudioUnitTimePitch：那个单元的离线渲染要 renderOffline
/// 配 offline tap，这条接口形态在 CI 的 macOS 对拍里验不到（对拍只编得进纯 Foundation 的算法文件），
/// 只能盲发真机试错；WSOLA 百来行，而且能量出来 —— 用单音当尺：拉伸前后 300 Hz 的幅度不许变成 600 Hz，
/// 时长比必须等于 1/rate；移调 +1200 音分后 300 Hz 要落到 600 Hz 而时长不许动。
enum PostProcessor {
    /// 30 ms @16 kHz。窗太长经不起大移速，太短周期模糊。
    static let win = 480
    /// 相似度搜索范围 ±10 ms，比一个 16k 基音周期(62 样本)宽，够找同相的段。
    static let search = 160

    /// 语速：只改时长，音高不动。rate > 1 是说快（变短）。
    static func timeStretch(_ x: [Float], rate: Double) -> [Float] {
        guard rate > 0.05, rate < 20, abs(rate - 1.0) > 1e-6, x.count > win * 3 else { return x }
        let hop = win / 2
        let w = hann(win)
        let outTarget = Int(Double(x.count) / rate)
        var out = [Float](repeating: 0, count: outTarget + win)
        var norm = [Float](repeating: 0, count: outTarget + win)

        // 参考＝上一段的后半；下一段在它前半 ±search 里找最像的一段，接上去才不"打格"
        var refTail = Array(x[hop..<win])
        var pos = 0
        var o = 0
        while o + win <= out.count {
            let center = pos + Int((Double(hop) * rate).rounded())
            let last = max(0, x.count - win)
            let hi = min(last, center + search)
            let lo = max(0, min(center - search, hi))
            var best = lo
            var bestScore = -Double.greatestFiniteMagnitude
            var c = lo
            while c <= hi {
                let s = ncc(refTail, Array(x[c..<min(c + hop, x.count)]))
                if s > bestScore { bestScore = s; best = c }
                c += 1
            }
            for i in 0..<win {
                out[o + i] += x[best + i] * w[i]
                norm[o + i] += w[i]
            }
            guard best + win <= x.count else { break }
            refTail = Array(x[(best + hop)..<(best + win)])
            pos = best
            o += hop
        }
        // 除回窗权重：50% 交叠的 Hann 每点累计≈1，但段首段尾和搜索跳变处不是
        var y = [Float](repeating: 0, count: max(0, min(outTarget, o + win)))
        for i in 0..<y.count {
            let s = norm[i]
            y[i] = s > 0.05 ? out[i] / s : out[i]
        }
        return y
    }

    /// 无滤波的线性重采样：factor > 1 等于快放 —— 时长 /factor、音高 ×factor。
    static func resample(_ x: [Float], _ factor: Double) -> [Float] {
        guard factor > 0, x.count > 1 else { return x }
        let n = max(1, Int(Double(x.count) / factor))
        var y = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let s = Double(i) * factor
            let i0 = min(x.count - 1, Int(s))
            let i1 = min(x.count - 1, i0 + 1)
            let f = Float(s - Double(i0))
            y[i] = x[i0] * (1.0 - f) + x[i1] * f
        }
        return y
    }

    /// 音调：只改音高，时长不动。cents = 1200 ⇒ 高一个八度。
    ///
    /// 先快放（音高上去、时长掉下来），再 WSOLA 拉回原时长。升调方向是线性重采样，
    /// 4 kHz 以上会有轻微折叠；人声能量都在 4 kHz 以下，界面上限也就收到 ±1200 音分。
    static func pitchShift(_ x: [Float], cents: Double) -> [Float] {
        let k = pow(2.0, cents / 1200.0)
        guard abs(k - 1.0) > 1e-6, x.count > win * 3 else { return x }
        return timeStretch(resample(x, k), rate: 1.0 / k)
    }

    private static func hann(_ n: Int) -> [Float] {
        var w = [Float](repeating: 0, count: n)
        for i in 0..<n { w[i] = Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(n))) }
        return w
    }

    /// 归一化互相关。两路都接近静音时（方差 <1e-9）返回一个很低的分，让搜索回到中心。
    private static func ncc(_ a: [Float], _ b: [Float]) -> Double {
        let n = min(a.count, b.count)
        guard n > 1 else { return -1e9 }
        var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        for i in 0..<n {
            let x = Double(a[i]), y = Double(b[i])
            sa += x; sb += y; saa += x * x; sbb += y * y; sab += x * y
        }
        let d = Double(n)
        let cov = sab - sa * sb / d
        let va = saa - sa * sa / d
        let vb = sbb - sb * sb / d
        let den = (va * vb).squareRoot()
        return den < 1e-9 ? -1e9 : cov / den
    }
}
