import Foundation

/// 一次转换的调度：读数 → ChainDriver → 后处理 → 落盘。算法本体全在 ChainDriver.swift。
///
/// 整件事是纯 CPU 的（几秒到几分钟），所以真正干活的部分放在 userInitiated 的
/// 分离任务上，别占着调用方的线程；onStage 也在那条线程上被调，实现方自己决定
/// 要不要跳回主线程。
///
/// 目标音色有两条来源，和官方那两个脚本一一对应：
/// - 样本（`scripts/infer.sh` 的 `--spk-emb-path` + `--prompt-path`）：① 早先算过一次存盘，
///   这次跳过，省下 4.1 s 和那次 386 MB 的 sv 图载入（真机 09:11:40 实测）。
/// - 现场参考音频（`scripts/infer_ref.sh` 的 `--reference-path`）：每次都要重跑 ①。
final class VoiceEngine {
    let modelDir: URL

    init(modelDir: URL) {
        self.modelDir = modelDir
    }

    /// 一条源音频进链的最长片。硬顶是 200 s（`ChainDriver.encMaxFbankFrames`），
    /// 这里取 150 s：留 25% 余量，而且 122 s 那一跑的真机足迹（峰 280 MB／驻留 458 MB）
    /// 正好是这一档已知的实测样本——片长不超过它，内存这一格就不引入新变量。
    static let convPassSeconds: Double = 150

    /// 在硬切点前后各 ±15 s 里找最安静的 50 ms 下刀。
    /// 每片都把编码器的 att/cnn 缓存清零，落在停顿上才听不见接缝（读小说按句切的同一个理由）。
    /// 取法：按 50 ms 一格算采样平方的和（隔 8 个样本取一个，够稳也快），选最小那格的中点。
    static func quietCut(_ src: [Float], target: Int, radiusSec: Double = 15) -> Int {
        let radius = Int(radiusSec * AudioProcessor.sampleRate)
        let lo = max(0, target - radius)
        let hi = min(src.count, target + radius)
        let grid = Int(0.05 * AudioProcessor.sampleRate)      // 50 ms
        guard hi - lo >= grid else { return min(max(target, 1), src.count) }
        var best = target
        var bestSum = Double.greatestFiniteMagnitude
        var p = lo
        while p + grid <= hi {
            var s = 0.0
            var k = p
            while k < p + grid {
                let v = Double(src[k])
                s += v * v
                k += 8
            }
            if s < bestSum {
                bestSum = s
                best = p + grid / 2
            }
            p += grid
        }
        VoiceJournal.line(String(format: "切点：%.1f s 处找最安静的一格 ⇒ %.1f s（搜索 ±%.0f s）",
                                 Double(target) / AudioProcessor.sampleRate,
                                 Double(best) / AudioProcessor.sampleRate, radiusSec))
        return best
    }

    /// 把一段音频炼成样本存进清单。① 那一次载入是真成本（实测 4.1 s / 峰值足迹 726 MB），
    /// 所以每条参考只做一次，之后反复用。
    ///
    /// 只解前 `ChainDriver.svMaxSecs` 秒：① 的内存随参考长度平方涨，而音色尺 6~11 s 就平了。
    func makeSample(fromWav url: URL, name: String) async throws -> SampleStore.Sample {
        let dir = modelDir
        return try await Task.detached(priority: .userInitiated) {
            VoiceJournal.line("生成样本「\(name)」← \(url.lastPathComponent)")
            let wav = try AudioProcessor.loadWAV16K(url, maxSeconds: ChainDriver.svMaxSecs)
            let driver = try ChainDriver(modelDir: dir)
            let parts = try driver.makeSample(reference: wav)
            return try SampleStore.save(name: name, parts: parts, wav16k: wav)
        }.value
    }

    /// 一条 16 kHz 单声道 Float 进链，按片「②③④ → 移调 → 落盘」。
    ///
    /// 为什么要分段：② 的绝对位置表只有 5000 行 ⇒ 一遍最多 200 s（`ChainDriver.encMaxFbankFrames`）。
    /// 那条 8 分钟素材不是内存不够、也不是闪退，就是走到第 1000 窗撞了这面墙。
    /// 切法和读小说一致：每片各跑一遍进链，编码器缓存只在切点清零 ⇒ 刀要落在停顿上才听不见接缝。
    ///
    /// 音频转换和视频换声共用这一条：两边的分段规矩（硬顶、找安静那格、每片自己算峰值压回）
    /// 一个字都不差，写两遍迟早分叉——到那时视频那条出的片口型偏了，查起来还得先对两份代码。
    ///
    /// `writer` 由调用方开着：峰值守卫是**每片**一次的，收尾（回填 wav 头）也归调用方。
    static func runSegments(driver: ChainDriver, parts: ChainDriver.SampleParts,
                            source: [Float], writer: AudioProcessor.WAVWriter,
                            pitchCents: Double,
                            onStage: (String) -> Void) throws -> (passes: Int, samples: Int) {
        let totalSec = Double(source.count) / AudioProcessor.sampleRate
        let passSamples = Int(convPassSeconds * AudioProcessor.sampleRate)
        VoiceJournal.line(String(format: "转换预算：源 %.1f s ⇒ %d 片（每片 ≤%.0f s）",
                                 totalSec, (source.count + passSamples - 1) / passSamples,
                                 convPassSeconds))
        if abs(pitchCents) > 1e-6 {
            VoiceJournal.line(String(format: "后处理 音高 %+.0f 音分：每片各自移", pitchCents))
        }
        var start = 0
        var passes = 0
        var outSamples = 0
        let t0 = Date()
        while start < source.count {
            let hardEnd = min(start + passSamples, source.count)
            let end = hardEnd < source.count ? quietCut(source, target: hardEnd) : hardEnd
            let chunk = Array(source[start..<end])
            passes += 1
            VoiceJournal.line(String(format: "转换第 %d 片：源 %.1f~%.1f s（进链 %.1f s／整条 %.1f s）",
                                     passes, Double(start) / AudioProcessor.sampleRate,
                                     Double(end) / AudioProcessor.sampleRate,
                                     Double(chunk.count) / AudioProcessor.sampleRate, totalSec))
            onStage(String(format: "第 %d 片进链（%.0f s 音频，整条 %.0f s）",
                           passes, Double(chunk.count) / AudioProcessor.sampleRate, totalSec))
            let shaped = PostProcessor.pitchShift(try driver.convert(source: chunk, sample: parts),
                                                  cents: pitchCents)
            try writer.append(shaped)
            outSamples += shaped.count
            start = end
            onStage(String(format: "第 %d 片已落盘：累计 %.0f s（墙钟 %.0f s）",
                           passes, Double(outSamples) / AudioProcessor.sampleRate,
                           Date().timeIntervalSince(t0)))
        }
        return (passes, outSamples)
    }

    /// inputWav: 用户要转换的那段
    /// sample / refWav: 目标音色，二选一（sample 优先）
    /// outputWav: 落盘路径
    /// pitchCents: 链外移调（±1200 音分），加在 ④ 声码之后的波形上；语速不做，播放器都有
    func convert(inputWav: URL, sample: SampleStore.Sample?, refWav: URL?,
                 outputWav: URL, pitchCents: Double = 0.0,
                 onStage: @escaping (String) -> Void = { VoiceJournal.line($0) }) async throws {
        let dir = modelDir
        try await Task.detached(priority: .userInitiated) {
            let srcName = inputWav.lastPathComponent
            let how: String
            if let s = sample {
                how = "样本「\(s.info.name)」"
            } else if let r = refWav {
                how = "现场参考 \(r.lastPathComponent)"
            } else {
                throw ChainError.input("既没在清单里选样本，也没有参考音频")
            }
            VoiceJournal.line("VoiceEngine 开始 \(srcName) / \(how)")
            let source = try AudioProcessor.loadWAV16K(inputWav)
            onStage("读数完成：源 \(source.count) 样本")
            let driver = try ChainDriver(modelDir: dir)
            driver.onStage = { text in
                VoiceJournal.line(text)
                onStage(text)
            }
            let parts: ChainDriver.SampleParts
            if let s = sample {
                parts = try SampleStore.load(s)
                onStage("用样本：跳过 ①，不载 sv 图")
            } else if let r = refWav {
                let reference = try AudioProcessor.loadWAV16K(r, maxSeconds: ChainDriver.svMaxSecs)
                onStage("读数完成：参考 \(reference.count) 样本")
                parts = try driver.makeSample(reference: reference)
            } else {
                throw ChainError.input("参考没准备起来")
            }

            let t0 = Date()
            let writer = try AudioProcessor.WAVWriter(url: outputWav)
            let (passes, outSamples) = try VoiceEngine.runSegments(
                driver: driver, parts: parts, source: source, writer: writer,
                pitchCents: pitchCents, onStage: onStage)
            try writer.finish()
            VoiceJournal.line(String(format: "转换完成：%d 片 → 输出 %.2f s／墙钟 %.1f s／%@（单片峰值最高 %.3f）",
                                     passes, Double(outSamples) / AudioProcessor.sampleRate,
                                     Date().timeIntervalSince(t0), outputWav.lastPathComponent,
                                     writer.maxPeak))
        }.value
    }

    // MARK: - 视频换声（提音轨 → 现有样本链 → 回写原画面）

    /// 一次视频换声的读数。`fitRate` 是对齐那一步实际用的倍率，1.0 = 没拉伸。
    struct VideoResult {
        var sourceSeconds: Double
        var convertedSeconds: Double
        var fitSeconds: Double
        var fitRate: Double
        var passes: Int
        var mux: VideoClip.MuxResult
        /// 成片真正落在哪儿：口径表里 `mov` 那两组会换扩展名，调用方不能再拿自己拼的那个名字。
        var outURL: URL
    }

    /// 一条视频每秒音频在手机上要占的**常驻**：源 Float 64 KB（16k × 4 B）
    /// ＋对齐那一步 `timeStretch` 再造的 out／norm／结果三份同长 Float ≈ 256 KB/秒。
    /// 按 `AudioProcessor.maxDecodeMB`（512 MB）那一格算 ⇒ 上限约 33 分钟；和链子本身无关，
    /// 链子已经会按 ≤150 s 切片，常驻只有当前那一片。
    static let videoArrayBytesPerSecond: Double = 256_000

    /// 一条视频每秒在**盘上**要占的中间量：转换后 wav 32 KB ＋对齐 wav 32 KB ＋成片里的 AAC 8 KB
    /// ＝ 72 KB/秒。画面那条是透传，所以成片的体积 ≈ 输入那条，单独立项扣掉。
    static let videoTempBytesPerSecond: Double = 72_000

    /// 上限取盘和内存两条里更紧的那一条，超线在开跑之前一行话拒掉（写一半把盘填满更难看）。
    static func videoSecondsCap(dir: URL, inputBytes: Int64) -> Double {
        let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let room = max(0.0, Double(free) - 1_000_000_000.0 - Double(inputBytes))
        let byDisk = room / videoTempBytesPerSecond
        let byMemory = AudioProcessor.maxDecodeMB * 1e6 / videoArrayBytesPerSecond
        return min(byDisk, byMemory)
    }

    /// 开跑前把上一轮没清掉的中间 wav 收一遍（崩在半路时它们留在盘上，`video_` 前缀归本条线）。
    private static func sweepVideoTemps(dir: URL) -> Int64 {
        let fm = FileManager.default
        var reclaimed: Int64 = 0
        for one in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey],
                                                options: [])) ?? [] {
            let n = one.lastPathComponent
            guard n.hasPrefix("video_"), n.hasSuffix("_chain.wav") || n.hasSuffix("_fit.wav") else { continue }
            let sz = (try? one.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if (try? fm.removeItem(at: one)) == nil { reclaimed += Int64(sz) }
        }
        if reclaimed > 0 {
            VoiceJournal.line("先清掉上轮残留的对齐中间量 \(FileHistory.human(reclaimed))")
        }
        return reclaimed
    }

    /// 视频进链：音轨 → 现有分段链 → 拉回原长 → 装回原来那条画面。
    ///
    /// 画面一个像素都不动（透传，见 `VideoClip`），所以这一条比音频转换只多出两头：
    /// 前面解音轨、后面回写。中间进链走的是和 `convert` **同一个** `runSegments`。
    ///
    /// 为什么中间要 `_chain.wav` 和 `_fit.wav` 两份：链子的输出帧数和源逐片对齐，
    /// PC 试点量过整条 +0.15%（16.97 s → 17.00 s）——听着不多，但每 100 s 就差 0.15 s，
    /// 一分钟以上的片子口型必偏。拉伸必须拿**整条**算一个倍率（按片各拉会把误差摊进每一片），
    /// 而整条拉伸要一次读回全部样本 ⇒ 就得分成两个文件。跑完这两个都删掉。
    ///
    /// 音色来源和 `readNovel` 一样只有两条，且必须有：视频里那个人本来就有的嗓子就是「自转换」，
    /// 转给自己听没意义。
    func processVideo(inputVideo: URL, sample: SampleStore.Sample?, refWav: URL?,
                      outputVideo: URL, pitchCents: Double = 0.0,
                      onStage: @escaping (String) -> Void = { VoiceJournal.line($0) }) async throws -> VideoResult {
        let dir = modelDir
        return try await Task.detached(priority: .userInitiated) {
            let name = inputVideo.lastPathComponent
            let how: String
            if let s = sample {
                how = "样本「\(s.info.name)」"
            } else if let r = refWav {
                how = "现场参考 \(r.lastPathComponent)"
            } else {
                throw ChainError.input("既没在清单里选样本，也没有参考音频（视频这条路没有自转换）")
            }
            let info = VideoClip.probe(inputVideo)
            VoiceJournal.line("VoiceEngine 视频换声开始 \(name) / \(how)／\(info.line)")
            guard info.hasVideo else { throw ChainError.input("\(name) 里没有画面轨") }
            guard info.hasAudio else { throw ChainError.input("\(name) 里没有音轨") }

            let outDir = outputVideo.deletingLastPathComponent()
            VoiceEngine.sweepVideoTemps(dir: outDir)
            let cap = VoiceEngine.videoSecondsCap(dir: outDir, inputBytes: info.bytes)
            guard info.audioSecs <= cap else {
                throw ChainError.input(String(format: "%@ 的音轨 %.1f 分钟，这台机的盘和内存只够 %.1f 分钟"
                                                + "（中间 wav 每秒共占 72 KB，成片另算 ≈ 输入那条的 \(FileHistory.human(info.bytes))，"
                                                + "另留 1 GB 余量）⇒ 请先剪短再换声",
                                              name, info.audioSecs / 60, cap / 60))
            }
            VoiceJournal.line(String(format: "视频预算：音轨 %.1f s／画面 %.1f s／容器 %.1f s／额度 %.1f s"
                                        + "｜链子按 2.5× 实时估 ≈ %.0f s 墙钟",
                                     info.audioSecs, info.videoSecs, info.containerSecs, cap,
                                     info.audioSecs / 2.5))

            onStage("解音轨（\(String(format: "%.0f", info.audioSecs)) s）…")
            let source = try VideoClip.extractAudio(inputVideo, say: VoiceJournal.line)
            let driver = try ChainDriver(modelDir: dir)
            driver.onStage = { text in
                VoiceJournal.line(text)
                onStage(text)
            }
            let parts: ChainDriver.SampleParts
            if let s = sample {
                parts = try SampleStore.load(s)
                onStage("音色用样本「\(s.info.name)」：跳过 ①，不载 sv 图")
            } else if let r = refWav {
                let reference = try AudioProcessor.loadWAV16K(r, maxSeconds: ChainDriver.svMaxSecs)
                onStage("音色用现场参考 \(r.lastPathComponent)：读数 \(reference.count) 样本")
                parts = try driver.makeSample(reference: reference)
            } else {
                throw ChainError.input("参考没准备起来")
            }

            let base = outputVideo.deletingPathExtension().lastPathComponent
            let chainWav = outDir.appendingPathComponent(base + "_chain.wav")
            let t0 = Date()
            let writer = try AudioProcessor.WAVWriter(url: chainWav)
            let (passes, outSamples) = try VoiceEngine.runSegments(
                driver: driver, parts: parts, source: source, writer: writer,
                pitchCents: pitchCents, onStage: onStage)
            try writer.finish()
            let convSecs = Double(outSamples) / AudioProcessor.sampleRate

            // 对齐：把整条拉伸回源的长度。倍率 = 输出长 / 源长，>1 就是念得比源快 ⇒ 加快（变短）。
            var fitWav = chainWav
            var fitSecs = convSecs
            var rate = 1.0
            let want = source.count
            let skew = want > 0 ? (Double(outSamples) - Double(want)) / Double(want) : 0
            if abs(skew) > 0.0005 {
                rate = 1.0 + skew
                onStage(String(format: "对齐：链子输出比源长 %.2f%% ⇒ 整条按 %.5f 拉伸", skew * 100, rate))
                let stretched = PostProcessor.timeStretch(try AudioProcessor.loadWAV16K(chainWav), rate: rate)
                fitSecs = Double(stretched.count) / AudioProcessor.sampleRate
                fitWav = outDir.appendingPathComponent(base + "_fit.wav")
                let w2 = try AudioProcessor.WAVWriter(url: fitWav)
                // 一片一片喂进去：峰值守卫是**每片**一次的，整条一次 append 等于又变回全局长峰压小整章
                let hop = Int(VoiceEngine.convPassSeconds * AudioProcessor.sampleRate)
                var p = 0
                while p < stretched.count {
                    try w2.append(Array(stretched[p..<min(p + hop, stretched.count)]))
                    p += hop
                }
                try w2.finish()
                VoiceJournal.line(String(format: "对齐完成：%.2f s → %.2f s（源 %.2f s，倍率 %.5f，残差 %.3f s）",
                                         convSecs, fitSecs, Double(want) / AudioProcessor.sampleRate,
                                         rate, fitSecs - Double(want) / AudioProcessor.sampleRate))
            } else {
                VoiceJournal.line(String(format: "对齐跳过：链子输出与源只差 %.4f%%（阈值 0.05%%）⇒ 直接用 %@",
                                         skew * 100, chainWav.lastPathComponent))
            }

            onStage("回写画面（一个像素都不动，只换声音）…")
            // 真机上「哪一组口径配得出成片」我手上没有数：这台机器上从没让 AVAssetWriter 编过音轨，
            // 0.1/32 那一跑就死在 writer failed「Cannot Encode Media」。所以按兼容性从好到差挨个试，
            // 成哪组用哪组，每组的判决都留在日志里——下一趟就不用再猜了。
            var mux: VideoClip.MuxResult? = nil
            var landed = outputVideo
            var lastErr = ""
            for cfg in VideoClip.candidates {
                let target = cfg.ext == outputVideo.pathExtension
                    ? outputVideo
                    : outputVideo.deletingPathExtension().appendingPathExtension(cfg.ext)
                do {
                    mux = try VideoClip.mux(video: inputVideo, audioWav: fitWav,
                                            out: target, cfg: cfg, say: VoiceJournal.line)
                    landed = target
                    break
                } catch {
                    lastErr = error.localizedDescription
                    VoiceJournal.line("换口径：\(lastErr)")
                    onStage("这一组配不出来，换下一组…")
                }
            }
            guard let won = mux else {
                let tried = VideoClip.candidates.map { $0.name }.joined(separator: "、")
                throw ChainError.input("四组口径全配不出来（试过 \(tried)）｜最后一句：\(lastErr)")
            }
            if landed.path != outputVideo.path {
                try? FileManager.default.removeItem(at: outputVideo)
                VoiceJournal.line("原打算叫 \(outputVideo.lastPathComponent)，换成 \(landed.lastPathComponent)")
            }

            var temps = [chainWav]
            if fitWav.path != chainWav.path { temps.append(fitWav) }
            for t in temps {
                let sz = (try? t.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if (try? FileManager.default.removeItem(at: t)) == nil {
                    VoiceJournal.line("中间量已清 \(t.lastPathComponent) \(FileHistory.human(Int64(sz)))")
                } else {
                    VoiceJournal.line("中间量没删掉 \(t.lastPathComponent)（历史文件页还能删）")
                }
            }

            VoiceJournal.line(String(format: "视频换声完成：%d 片／转换 %.2f s／对齐 %.2f s／墙钟 %.1f s"
                                     + "／口径 \(won.cfgName) → %@ %.1f MB",
                                     passes, convSecs, fitSecs, Date().timeIntervalSince(t0),
                                     landed.lastPathComponent,
                                     Double(won.bytes) / 1_048_576))
            return VideoResult(sourceSeconds: Double(source.count) / AudioProcessor.sampleRate,
                               convertedSeconds: convSecs, fitSeconds: fitSecs, fitRate: rate,
                               passes: passes, mux: won, outURL: landed)
        }.value
    }

    // MARK: - 读小说（文本 → 系统 TTS → 现有样本链）

    /// 一次朗读的读数。`tts.line` 就是 A0 那一格的证据。
    struct NovelResult {
        var tts: SystemTTS.Report
        var passes: Int
        var convertedSeconds: Double
        var rawURL: URL
    }

    /// 一片进链的时长。按片而不是按句的理由写在下面那条注释里。
    static let novelPassSeconds: Double = 120

    /// 原声＋转换后两条 16 kHz int16 单声道，每秒音频占 32000×2 字节 ⇒ 两条 64 KB/秒。
    static let novelBytesPerSecond: Double = 64_000

    /// 上限这一格从「内存」换成了「磁盘」：流式落盘之后常驻只有当前一片（≤120 s ≈ 8 MB），
    /// 但写到一半把盘填满会更难看（半个 wav，播不了还占着）。所以开跑前照可用空间算，
    /// 留 1 GB 余量，超线照样在开跑之前一行话拒掉。
    static func novelSecondsCap(dir: URL) -> Double {
        let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let room = max(0.0, Double(free) - 1_000_000_000.0)
        return room / novelBytesPerSecond
    }

    /// 文本 → 分句系统朗读 → 按片过 ②③④ → **每片直接落盘**，最后是一个 wav（播放器只吃一个文件）。
    ///
    /// 为什么按片：ChainDriver 每段跑完就把图关掉（编码器三张 + DiT 七张 + vocos 一张
    /// ≈343 MB 的载入）。按句转换 = 每句重开一遍图，300 句就是 300 次。按片切只落在句读上
    /// ⇒ 编码器缓存清零正好赶上停顿，听不见接缝；图和样本条件整趟只载一次。
    ///
    /// 为什么落盘也按片：整章的原声和转换后都不在内存里攒了（见 `AudioProcessor.WAVWriter`），
    /// 峰值守卫跟着变成**每片**一个——一片过冲不再把整章一起压小。
    ///
    /// 音色来源和 `convert` 一样：样本优先，没样本就用现场参考；两者都空直接报错
    /// （文本没有"自转换"这一说——源是合成声，转给自己听没意义）。
    /// rawTTSWav: 系统原声也存一份，好和转换后的对着听。
    func readNovel(text: String, sample: SampleStore.Sample?, refWav: URL?,
                   outputWav: URL, rawTTSWav: URL, pitchCents: Double = 0.0,
                   voiceID: String? = nil,
                   onStage: @escaping (String) -> Void = { VoiceJournal.line($0) }) async throws -> NovelResult {
        let dir = modelDir
        return try await Task.detached(priority: .userInitiated) {
            let sents = SystemTTS.sentences(from: text)
            guard !sents.isEmpty else { throw ChainError.input("文本切完是空的（全是空白？）") }
            let est = Double(text.count) / 4.1          // PC 实测：系统 TTS 念中文 ≈4.1 字/秒
            let cap = VoiceEngine.novelSecondsCap(dir: outputWav.deletingLastPathComponent())
            guard est <= cap else {
                throw ChainError.input(String(format: "%d 字 ≈ %.0f 分钟音频，这台机剩下的盘只够 %.0f 分钟"
                                                + "（两条 wav 每秒共占 64 KB，另留 1 GB 余量）⇒ 请按章分开读",
                                              text.count, est / 60, cap / 60))
            }
            // 实测两个倍率：合成 ≈5.5× 实时、整链 ≈2.5× 实时 ⇒ 墙钟约 = 音频秒×(1/5.5+1/2.5)
            let estWall = est * (1.0 / 5.5 + 1.0 / 2.5)
            VoiceJournal.line(String(format: "读小说预算：%d 字 ≈ %.1f 分钟音频 ≈ 盘上 %.1f MB ≈ 墙钟 %.0f 分钟（盘剩 %.0f 分钟额度）",
                                     text.count, est / 60, est * VoiceEngine.novelBytesPerSecond / 1e6,
                                     estWall / 60, cap / 60))
            let voice = SystemTTS.pickVoice(identifier: voiceID)
            let how = voice.map { "语音 \($0.identifier)（\($0.language)）" } ?? "系统默认语音"
            VoiceJournal.line("读小说开跑：\(text.count) 字 → \(sents.count) 句／\(how)／装了的中文 voice \(SystemTTS.chineseVoices().count) 个／会话 \(SystemTTS.sessionLine())")
            onStage("TTS 探针：\(how)")

            let driver = try ChainDriver(modelDir: dir)
            driver.onStage = { text in
                VoiceJournal.line(text)
                onStage(text)
            }
            let parts: ChainDriver.SampleParts
            if let s = sample {
                parts = try SampleStore.load(s)
                onStage("音色用样本「\(s.info.name)」：跳过 ①，不载 sv 图")
            } else if let r = refWav {
                let reference = try AudioProcessor.loadWAV16K(r, maxSeconds: ChainDriver.svMaxSecs)
                onStage("音色用现场参考 \(r.lastPathComponent)：读数 \(reference.count) 样本")
                parts = try driver.makeSample(reference: reference)
            } else {
                throw ChainError.input("既没在清单里选样本，也没有参考音频")
            }

            let pump = TTSPump(voice: voice)
            let rawWriter = try AudioProcessor.WAVWriter(url: rawTTSWav)
            let outWriter = try AudioProcessor.WAVWriter(url: outputWav)
            var pending: [Float] = []
            var passes = 0
            var outSamples = 0
            let t0 = Date()
            for (i, s) in sents.enumerated() {
                pending.append(contentsOf: try pump.speak(s))
                let last = (i == sents.count - 1)
                if Double(pending.count) / SystemTTS.sampleRate >= VoiceEngine.novelPassSeconds || last {
                    passes += 1
                    let inSec = Double(pending.count) / SystemTTS.sampleRate
                    VoiceJournal.line(String(format: "第 %d 片：%d/%d 句，进链 %.1f s（累计音频 %.1f s）",
                                             passes, i + 1, sents.count, inSec, pump.report.seconds))
                    onStage(String(format: "第 %d 片进链（%.0f s 音频，累计 %d/%d 句）",
                                   passes, inSec, i + 1, sents.count))
                    // 一片走完「转换 → 移调 → 落盘」就全部丢掉，下一片重新分配：
                    // 常驻内存因此只有这一片，和整章多长无关。
                    let shaped = PostProcessor.pitchShift(
                        try driver.convert(source: pending, sample: parts), cents: pitchCents)
                    try outWriter.append(shaped)
                    try rawWriter.append(pending)
                    outSamples += shaped.count
                    let done = Double(outSamples) / SystemTTS.sampleRate
                    VoiceJournal.line(String(format: "第 %d 片落盘：累计输出 %.1f s／两个文件共 %.1f MB（墙钟 %.0f s）",
                                             passes, done,
                                             done * VoiceEngine.novelBytesPerSecond / 1e6,
                                             Date().timeIntervalSince(t0)))
                    onStage(String(format: "第 %d 片已落盘：累计 %.0f s 音频（%.1f MB）",
                                   passes, done, done * VoiceEngine.novelBytesPerSecond / 1e6))
                    pending.removeAll(keepingCapacity: true)
                } else if i % 10 == 9 {
                    onStage(String(format: "念到第 %d/%d 句，累计 %.0f s 音频", i + 1, sents.count, pump.report.seconds))
                }
            }
            pump.finish()
            // 先收输出那份：收尾现在能抛（seek 是 throws 的），他要听的文件先落定，
            // 免得原声那步炸了把两个都留在「头里长度还是 0」的状态。
            try outWriter.finish()
            try rawWriter.finish()

            VoiceJournal.line(pump.report.line)
            VoiceJournal.line(String(format: "读小说完成：%d 片，转换后 %.2f s，整趟墙钟 %.1f s → %@（本片最大峰值 %.3f）",
                                     passes, Double(outSamples) / SystemTTS.sampleRate,
                                     Date().timeIntervalSince(t0), outputWav.lastPathComponent,
                                     outWriter.maxPeak))
            return NovelResult(tts: pump.report, passes: passes,
                               convertedSeconds: Double(outSamples) / SystemTTS.sampleRate,
                               rawURL: rawTTSWav)
        }.value
    }
}
