import Foundation

/// 链路里的错误。形状类报错一律带上实际读数，手机上出错只能靠"发到电脑"那一行文本复盘。
enum ChainError: Error, LocalizedError {
    case shape(String)
    case input(String)

    var errorDescription: String? {
        switch self {
        case .shape(let m): return "形状对不上：\(m)"
        case .input(let m): return "输入不合用：\(m)"
        }
    }
}

/// 一段「帧 × 维度」的浮点序列，行主序展平。bn 和 mel 都是这个形态。
private struct ChainRows {
    var data: [Float]
    var frames: Int
    var dim: Int
}

/// MeanVC 整条推理链的手机侧驱动，逐段照抄 tools/_f16_ab.py 的 build_bn / run_chain。
/// 那份 python 在 PC 上跑出过 CER 0.077、音色余弦 0.72，链路里每个数（窗 23 / 步 20、
/// 每次调用出 5 帧、bn 沿时间 ×4 上采样 align_corners、DiT 每片 20 帧、2 步 euler、
/// timesteps [1.0, 0.8, 0.0]、off>40 后 kv 只留最后 100 帧、vocos 每 173 帧一片）
/// 都是拿真模型定过的，这里一个都不改。
///
/// 和 python 唯一的差别是内存：python 把 7 张 DiT 一次全载入（≈192 MB），这里按状态号
/// 用到哪张开哪张。状态号是 min(chunk, 6)，单调不回退，所以不会出现反复装卸。
/// sv 那张 368 MB 单独占顶，用完即关；编码器三张同活（它们要互相接力缓存）。
final class ChainDriver {

    // 文件名和 tools/_ship2 一致；models-fp16.zip 里就是这 12 张（w600k 是人脸模型，没打包）。
    static let fileSV = "sv_dynamic_len.onnx"
    static let fileEncFirst = "fastu2plusplus_state_a_first.onnx"
    static let fileEncSecond = "fastu2plusplus_state_b_second.onnx"
    static let fileEncSteady = "fastu2plusplus_state_c_steady.onnx"
    static let fileVocos = "vocos.onnx"
    static func ditFile(_ state: Int) -> String { "dit_state_\(state).onnx" }

    static let encWindow = 23        // 编码器窗长（fbank 帧）
    static let encStride = 20        // 窗滑动步长
    static let encAttSteady = 10     // att_cache 时间维到这个长度就换 steady 图
    static let ditChunk = 20         // DiT 每片帧数
    static let ditStates = 7
    static let kvKeep = 100          // off>40 之后 kv 缓存只留最后这么多个时间步
    static let kvTrimAfter = 40
    static let promptFrames = 150    // DiT 的 prompts 输入钉死 150 帧
    static let vocosWindow = 173
    static let melHop = 160          // mel 帧 → 样本
    static let noiseSeed: UInt64 = 7
    static let timesteps: [Double] = [1.0, 0.8, 0.0]

    private let runtime: OrtRuntime
    private let modelDir: URL

    /// 每开一段报一句，顺带把耗时写进磁盘日志。
    var onStage: (String) -> Void = { VoiceJournal.line($0) }
    /// 端到端对拍用的噪声（PC 侧录下来的 fixture）。给了就不用自己生成。
    var noiseOverride: [Float]?

    init(modelDir: URL, intraThreads: Int = 4) throws {
        self.modelDir = modelDir
        self.runtime = try OrtRuntime(intraThreads: intraThreads)
    }

    private func graph(_ name: String) throws -> OrtGraph {
        return try runtime.graph(at: modelDir.appendingPathComponent(name))
    }

    /// source / reference 都是 16 kHz 单声道 [-1,1]。返回同口径的转换结果。
    func convert(source: [Float], reference: [Float]) throws -> [Float] {
        let t0 = Date()
        guard let basis = AudioProcessor.melBasis() else {
            throw ChainError.input("bundle 里没有 librosa_mel_basis.f32，prompt 通道算不出来")
        }

        let fb = MelFrontEnd.kaldiFbank(AudioProcessor.scaled(source))
        let fbFrames = fb.count / MelFrontEnd.nMels
        guard fbFrames >= 1 else {
            throw ChainError.input("源音频只有 \(source.count) 样本，凑不满一个 25 ms 帧（要 ≥\(MelFrontEnd.kaldiFrame)）")
        }

        let pm = MelFrontEnd.promptMel(reference, basis: basis)
        let pmFrames = pm.count / MelFrontEnd.nMels
        let needSamples = Self.promptFrames * Self.melHop
        guard pmFrames >= Self.promptFrames else {
            let needSec = String(format: "%.2f", Double(needSamples) / AudioProcessor.sampleRate)
            let got = "参考音频只有 \(pmFrames) 帧 mel（\(reference.count) 样本）"
            let rule = "DiT 的 prompts 输入钉死 \(Self.promptFrames) 帧"
            throw ChainError.input(got + "，" + rule + "，至少要 \(needSamples) 样本 ≈ \(needSec) s")
        }

        let spks = try speakerEmbedding(reference)
        let bn = try encode(fbank: fb, frames: fbFrames)
        let promptSlice = Array(pm.prefix(Self.promptFrames * MelFrontEnd.nMels))
        let mel = try denoise(bn: bn, spks: spks, prompts: promptSlice)
        let wav = try vocode(mel)
        let wall = max(Date().timeIntervalSince(t0), 0.001)
        let srcSec = Double(source.count) / AudioProcessor.sampleRate
        let outSec = Double(wav.count) / AudioProcessor.sampleRate
        let realtime = String(format: "%.1f", outSec / wall)
        onStage(String(format: "整链 源 %.2f s → 出 %.2f s，墙钟 %.1f s（实时倍率 %@）",
                       srcSec, outSec, wall, realtime))
        return wav
    }

    // MARK: - ① 音色嵌入

    private func speakerEmbedding(_ wav: [Float]) throws -> OrtTensor {
        let t0 = Date()
        onStage("① 音色嵌入：载入 \(Self.fileSV)")
        let g = try graph(Self.fileSV)
        defer { g.close() }
        let out = try g.run([feedF32("wave", [1, wav.count], wav)], wants: ["emb"])
        guard let emb = out.first else { throw ChainError.shape("sv 没吐出 emb") }
        onStage(String(format: "① emb %@（%.1f s）", dimText(emb.dims), Date().timeIntervalSince(t0)))
        return emb
    }

    // MARK: - ② 内容编码（fastu2++ 三态流式）

    private func encode(fbank: [Float], frames: Int) throws -> ChainRows {
        let nM = MelFrontEnd.nMels
        let t0 = Date()
        onStage("② 内容编码：\(frames) 帧 fbank")
        let gFirst = try graph(Self.fileEncFirst)
        let gSecond = try graph(Self.fileEncSecond)
        let gSteady = try graph(Self.fileEncSteady)
        defer { gFirst.close(); gSecond.close(); gSteady.close() }

        var rows: [Float] = []
        var featureDim = 0
        var att: OrtTensor?
        var cnn: OrtTensor?
        var attLen = -1              // -1 = 还没有缓存，第一窗走 a_first
        var off = 0
        var calls = 0

        var i0 = 0
        while i0 < frames {
            var xs = [Float](repeating: 0, count: Self.encWindow * nM)
            let take = min(Self.encWindow, frames - i0)     // 尾窗不足 23 帧：补零，和 F.pad 一致
            for w in 0..<take {
                let src = (i0 + w) * nM
                for k in 0..<nM { xs[w * nM + k] = fbank[src + k] }
            }

            let g: OrtGraph
            if attLen < 0 { g = gFirst }
            else if attLen < Self.encAttSteady { g = gSecond }
            else { g = gSteady }

            var feeds = [feedF32("xs", [1, Self.encWindow, nM], xs),
                         feedI64("offset", [Int64(off)])]
            if let a = att, let c = cnn {
                feeds.append(OrtNamedFeed(name: "att_cache", value: a))
                feeds.append(OrtNamedFeed(name: "cnn_cache", value: c))
            }
            let res = try g.run(feeds, wants: ["encoder_out", "new_att_cache", "new_cnn_cache"])
            guard res.count == 3 else { throw ChainError.shape("编码器只回 \(res.count)/3 项") }
            guard case .f32(let edims, let edata) = res[0], edims.count == 3, edims[0] == 1 else {
                throw ChainError.shape("encoder_out 不是 [1,帧,维] 的 f32（\(dimText(res[0].dims))）")
            }
            if featureDim == 0 { featureDim = edims[2] }
            guard edims[2] == featureDim else {
                throw ChainError.shape("第 \(calls) 窗输出维度变了：\(edims[2]) vs \(featureDim)")
            }
            let attDims = res[1].dims
            guard attDims.count == 4 else {
                throw ChainError.shape("new_att_cache 不是 4 维（\(dimText(attDims))）")
            }
            rows.append(contentsOf: edata)
            att = res[1]
            cnn = res[2]
            attLen = attDims[2]
            off += edims[1]          // python: off += enc.shape[1]
            calls += 1
            i0 += Self.encStride
        }

        let nf = rows.count / featureDim
        let up = try interpolateX4(rows, frames: nf, dim: featureDim)
        onStage(String(format: "② %d 窗 → %d×%d，×4 上采样成 %d 帧（%.1f s）",
                       calls, nf, featureDim, nf * 4, Date().timeIntervalSince(t0)))
        return ChainRows(data: up, frames: nf * 4, dim: featureDim)
    }

    /// torch.nn.functional.interpolate(size=N*4, mode="linear", align_corners=True)，
    /// 沿时间轴。align_corners 的坐标就是 i*(in-1)/(out-1)，torch 在 float32 里算这个乘积，
    /// 所以这里也用 Float 而不是 Double（换 Double 会在整数帧上偏半个 ulp，对拍时白费劲）。
    private func interpolateX4(_ src: [Float], frames n: Int, dim: Int) throws -> [Float] {
        guard n >= 1, src.count == n * dim else {
            throw ChainError.shape("上采样输入 \(src.count) 个 float，摊不出 \(n)×\(dim)")
        }
        let m = n * 4
        var out = [Float](repeating: 0, count: m * dim)
        if n == 1 {                  // scale 是 0/0，torch 在这种退化情形下直接铺同一个值
            for i in 0..<m {
                for k in 0..<dim { out[i * dim + k] = src[k] }
            }
            return out
        }
        let scale = Float(n - 1) / Float(m - 1)
        for i in 0..<m {
            let x = Float(i) * scale
            var i0 = Int(x)
            if i0 >= n { i0 = n - 1 }
            let i1 = min(i0 + 1, n - 1)
            let lam = x - Float(i0)
            let a = i0 * dim
            let b = i1 * dim
            let o = i * dim
            for k in 0..<dim {
                out[o + k] = (1.0 - lam) * src[a + k] + lam * src[b + k]
            }
        }
        return out
    }

    // MARK: - ③ DiT 去噪（7 态流式 + 2 步 euler）

    private func denoise(bn: ChainRows, spks: OrtTensor, prompts: [Float]) throws -> ChainRows {
        let nM = MelFrontEnd.nMels
        let chunks = (bn.frames + Self.ditChunk - 1) / Self.ditChunk
        let need = chunks * Self.ditChunk * nM
        let noise: [Float]
        if let ov = noiseOverride {
            guard ov.count >= need else {
                throw ChainError.input("噪声 fixture 只给了 \(ov.count) 个，这条链要 \(need) 个（\(chunks) 片）")
            }
            noise = ov
        } else {
            noise = Self.gaussianNoise(count: need, seed: Self.noiseSeed)
        }

        let t0 = Date()
        onStage("③ 去噪：\(chunks) 片 × \(Self.ditChunk) 帧")
        let kvWants = (0..<4).flatMap { ["new_kv_k\($0)", "new_kv_v\($0)"] }
        let wants = ["u"] + kvWants

        var mel: [Float] = []
        mel.reserveCapacity(chunks * Self.ditChunk * nM)
        var kv: [OrtTensor]?
        var cache: OrtTensor?
        var off = 0
        var loaded = -1
        var g: OrtGraph?
        defer { g?.close() }

        for c in 0..<chunks {
            let state = min(c, Self.ditStates - 1)
            if state != loaded {
                g?.close()
                g = try graph(Self.ditFile(state))
                loaded = state
            }
            guard let sg = g else { throw ChainError.shape("状态 \(state) 的图没载入") }

            var cond = [Float](repeating: 0, count: Self.ditChunk * bn.dim)
            let from = c * Self.ditChunk
            let take = min(Self.ditChunk, bn.frames - from)
            if take > 0 {
                let src = from * bn.dim
                for k in 0..<(take * bn.dim) { cond[k] = bn.data[src + k] }
            }
            let nAt = from * nM
            let nEnd = nAt + Self.ditChunk * nM
            var x = Array(noise[nAt..<nEnd])

            for i in 0..<2 {
                let tv = Self.timesteps[i]
                let rv = Self.timesteps[i + 1]
                var feeds = [feedF32("x", [1, Self.ditChunk, nM], x),
                            feedF32("t", [1], [Float(tv)]),
                            feedF32("r", [1], [Float(rv)]),
                            feedF32("cond", [1, Self.ditChunk, bn.dim], cond),
                            OrtNamedFeed(name: "spks", value: spks),
                            feedF32("prompts", [1, Self.promptFrames, nM], prompts)]
                if sg.takes("offset") { feeds.append(feedI64("offset", [Int64(off)])) }
                if let ca = cache, sg.takes("cache") {
                    feeds.append(OrtNamedFeed(name: "cache", value: ca))
                }
                if let kk = kv, sg.takes("kv_k0") {
                    guard kk.count == 8 else {
                        throw ChainError.shape("kv 缓存应该有 8 项（4 层 k/v），实际 \(kk.count)")
                    }
                    for j in 0..<4 {
                        feeds.append(OrtNamedFeed(name: "kv_k\(j)", value: kk[2 * j]))
                        feeds.append(OrtNamedFeed(name: "kv_v\(j)", value: kk[2 * j + 1]))
                    }
                }
                let res = try sg.run(feeds, wants: wants)
                guard res.count == wants.count else {
                    throw ChainError.shape("状态 \(state) 回了 \(res.count)/\(wants.count) 项")
                }
                guard case .f32(_, let u) = res[0], u.count == x.count else {
                    throw ChainError.shape("状态 \(state) 的 u 是 \(res[0].count) 个，x 是 \(x.count) 个")
                }
                let dt = Float(tv - rv)          // python 用两个 float 相减再乘，这里同一口径
                for k in 0..<x.count { x[k] = x[k] - dt * u[k] }
                if i == 1 { kv = Array(res[1...]) }
            }

            mel.append(contentsOf: x)
            cache = .f32(dims: [1, Self.ditChunk, nM], data: x)
            off += Self.ditChunk
            if off > Self.kvTrimAfter, let kk = kv {
                kv = kk.map { kvTail($0, keep: Self.kvKeep) }
            }
        }

        onStage(String(format: "③ mel %d×%d（%.1f s）",
                       mel.count / nM, nM, Date().timeIntervalSince(t0)))
        return ChainRows(data: mel, frames: mel.count / nM, dim: nM)
    }

    /// kv 缓存的时间维是 dims[2]（形状 [b, heads, 时间, head_dim]）；只留最后 keep 帧。
    private func kvTail(_ t: OrtTensor, keep: Int) -> OrtTensor {
        guard case .f32(let dims, let data) = t, dims.count == 4, dims[2] > keep else { return t }
        let bh = dims[0] * dims[1]
        let len = dims[2]
        let hd = dims[3]
        let start = len - keep
        var out = [Float](repeating: 0, count: bh * keep * hd)
        for o in 0..<bh {
            let src = (o * len + start) * hd
            let dst = o * keep * hd
            for k in 0..<(keep * hd) { out[dst + k] = data[src + k] }
        }
        return .f32(dims: [dims[0], dims[1], keep, hd], data: out)
    }

    // MARK: - ④ 声码

    private func vocode(_ mel: ChainRows) throws -> [Float] {
        let nM = MelFrontEnd.nMels
        let T = mel.frames
        guard mel.dim == nM else {
            throw ChainError.shape("mel 通道数 \(mel.dim)，vocos 只吃 \(nM)")
        }
        let t0 = Date()
        onStage("④ 声码：\(T) 帧 mel")

        // python: ((mel.transpose(1,2) + 1) / 2).contiguous() → [1,80,T] 通道主序
        var mv = [Float](repeating: 0, count: nM * T)
        for t in 0..<T {
            let src = t * nM
            for c in 0..<nM { mv[c * T + t] = (mel.data[src + c] + 1.0) * 0.5 }
        }

        let g = try graph(Self.fileVocos)
        defer { g.close() }
        var out: [Float] = []
        out.reserveCapacity(T * Self.melHop)
        var i0 = 0
        while i0 < T {
            var win = [Float](repeating: 0, count: nM * Self.vocosWindow)
            let take = min(Self.vocosWindow, T - i0)     // 尾片补零，不是重复末尾
            for c in 0..<nM {
                let src = c * T + i0
                for k in 0..<take { win[c * Self.vocosWindow + k] = mv[src + k] }
            }
            let res = try g.run([feedF32("mel", [1, nM, Self.vocosWindow], win)], wants: ["wav"])
            guard let head = res.first, case .f32(_, let pcm) = head else {
                throw ChainError.shape("vocos 没吐出 f32 的 wav")
            }
            out.append(contentsOf: pcm)
            i0 += Self.vocosWindow
        }
        let trimmed = Array(out.prefix(T * Self.melHop))
        onStage(String(format: "④ 波形 %.2f s（%.1f s）",
                       Double(trimmed.count) / AudioProcessor.sampleRate,
                       Date().timeIntervalSince(t0)))
        return trimmed
    }

    // MARK: - 小工具

    private func feedF32(_ name: String, _ dims: [Int], _ data: [Float]) -> OrtNamedFeed {
        OrtNamedFeed(name: name, value: .f32(dims: dims, data: data))
    }

    private func feedI64(_ name: String, _ data: [Int64]) -> OrtNamedFeed {
        OrtNamedFeed(name: name, value: .i64(dims: [], data: data))
    }

    private func dimText(_ dims: [Int]) -> String {
        dims.isEmpty ? "标量" : dims.map { String($0) }.joined(separator: "×")
    }

    /// 高斯噪声：SplitMix64 出均匀比特、Box–Muller 变正态，seed 固定。
    /// 不指望和 torch 的 randn 撞同一串（那是 MT19937 + torch 自己的正态变换），
    /// 换一串噪声只是换一次采样，音色/内容那两把尺不动。端到端对拍走 noiseOverride：
    /// PC 侧把这一串录成 fixture，两边喂同一份噪声，输出才谈得上逐元素比。
    static func gaussianNoise(count: Int, seed: UInt64 = 7) -> [Float] {
        var state = seed
        func bits() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        var out: [Float] = []
        out.reserveCapacity(count)
        while out.count < count {
            let u1 = Double((bits() >> 11) + 1) / 9007199254740992.0   // (0,1]，log 碰不到 0
            let u2 = Double(bits() >> 12) / 4503599627370496.0         // [0,1)
            let r = sqrt(-2.0 * log(u1))
            let th = 2.0 * Double.pi * u2
            out.append(Float(r * cos(th)))
            if out.count < count { out.append(Float(r * sin(th))) }
        }
        return out
    }
}
