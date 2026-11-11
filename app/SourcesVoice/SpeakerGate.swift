import Foundation

/// 「只留一个人」：源音频里凡是听不出选定音色那个人的块，就地清零；时间轴一个样本都不动。
///
/// 为什么判「是不是她」而不是「是男是女」：F0 那两条区间（男 85~180 Hz、女 165~255 Hz）本来就
/// 重叠，低沉的女声、亮嗓的男声、小孩声一律判反；而这条链的 ① 本来就在机器里，样本库还存着
/// 每个人一条 `spk` 向量 ⇒ 判据只剩一句点积，一克新权重、一个新模型都不用加。
///
/// 为什么清零而不是删掉：⑤ 视频换声的口型靠「链子输出和源逐片对齐」，删掉一块会把后面整体
/// 前移，越到片尾偏得越多。清零留下一条纹丝不动的时间轴，而静音本来就没有口型可丢。代价照实
/// 说：被清零的块照样进链（②③④ 不知道那儿没人说话），所以省不下链子的时间，只多出一趟 ①。
///
/// 三个判据（块长 / 刀口 / 门限）都在 PC 上拿出厂那张 int8 sv 图——`tools/_ship2/
/// sv_dynamic_len.onnx`，和手机上是同一份——用真素材拼的男女轮流说过一遍，理由写在各自那条
/// 注释里。真机日志里「闸门逐块 cos」那一行是给门限回账用的：合不合适，看他那一趟的分布。
///
/// 多花多少时间：PC 上同一张图、4 线程、无缓存，2.5 s 一块实测 0.5~0.6 秒 ⇒ 每源秒 ≈0.23 秒，
/// 每源分钟 ≈15 秒（链子自己 ≈24 秒／源分钟 ⇒ 大约多一半）。真机的 ① 和 PC 同量级，不是一个
/// 数量级的事：13.4 s 参考 真机 4.1 s／PC 3.8 s，40.6 s 参考 真机 18.0 s／PC 17.5 s。
/// 另加 sv 图那一次载入（只载一次，和判定分开记在 `Report` 里）。
enum SpeakerGate {

    /// 一块标称多长。① 的耗时还带随长度的平方项，2.5 s 是「够判」和「少算」中间那一格：
    /// PC 上 1.5~3 s 的纯净块余弦已经分得很开（同人 0.80~0.92／异人 0.15~0.31），
    /// 再短就要靠门限赌了。
    static let maxPieceSecs = 2.5

    /// 两块刀口之间最少这么多。比这短的块自己判不准（PC：1.0 s 的边际能把同人和异人盖过去）。
    static let minPieceSecs = 1.0

    /// 刀口可以在标称位置前后这么宽的范围内找。±0.5 s 够躲过一次换口，又不会把两块挤得太近。
    static let cutSearchSecs = 0.5

    /// 余弦门限。PC 上拿真素材拼的轮流说过一遍（40 组配置，逐块记账，见 `probe_gate_v8`）。
    /// 音色真的不同时分得很开：男↔女 同人 0.75~0.94／对方 0.03~0.28 ⇒ 0.45 落在空档正中。
    /// 但两个像的同声线贴得没有空档：女×女、真女声×女声 TTS 的**对方**块能到 0.40~0.67，
    /// 而同人块最低 0.57 ⇒ 这一档压根画不出干净刀口，只能选错的方向：
    /// 0.45 偏「留人」，整条扫下来误删选定那个人自己的只占 2% 的源秒数，漏删（同声线那种）56%。
    /// 宁可多留一块（顶多那一句是别人的嗓子），也不要误删一句她说的话。
    /// 同一趟里横跨两个人的混块落在 0.31~0.64 这一带＝判哪一边都可能，
    /// 所以刀口要尽量躲开它们，理由见 `pieces`。
    static let threshold = 0.45

    /// 能量格子。和 `VoiceEngine.quietCut` 同一口径（50 ms 一格、每格隔 8 个样本取一个）。
    static let cellSecs = 0.05

    struct Report {
        var sourceSecs: Double
        var pieces: Int
        var keptPieces: Int
        var droppedPieces: Int
        var droppedSecs: Double
        var maxPieceSecs: Double
        var minCos: Double
        var maxCos: Double
        /// 逐块判定的墙钟，**不含** ① 那张图的载入（两条加起来才是「开这个开关多花了几秒」）。
        var wallSeconds: Double
        /// 判过的那几块：块头秒数 + 余弦。门限那 0.45 合不合适，就看这一串的分布。
        var cosines: [(sec: Double, cos: Double)]
        /// sv 图那一次载入花了多少。开关打开才会载，所以关掉时这一个数压根不存在。
        var loadSeconds: Double = 0

        /// 「开这个开关多花了几秒」＝判定 + 载入。
        var addedSeconds: Double { wallSeconds + loadSeconds }

        /// 一行给磁盘日志：切了几块、留了几块、删了几秒、墙钟多少。
        var line: String {
            String(format: "闸门：源 %.1f s ⇒ %d 块（标称 %.1f s／块，刀口躲能量低谷）"
                   + "｜留 %d 块／清零 %d 块＝%.1f s｜cos 最好 %.2f 最差 %.2f（门限 %.2f）"
                   + "｜墙钟 判定 %.1f s＋图载入 %.1f s＝多花 %.1f s",
                   sourceSecs, pieces, maxPieceSecs, keptPieces, droppedPieces, droppedSecs,
                   minCos, maxCos, SpeakerGate.threshold, wallSeconds, loadSeconds, addedSeconds)
        }

        /// 逐块余弦，块头秒数一起给：只知道"有一块 0.31"没用，得知道它在片子的第几秒——
        /// 那儿往往是背景里另一个人，或者一句没换气的接力。
        var cosineLine: String {
            let cap = 400
            let body = cosines.prefix(cap).map { String(format: "%.1f:%.2f", $0.sec, $0.cos) }
                                .joined(separator: " ")
            let tail = cosines.count > cap
                ? String(format: "…（只列前 %d 块，共 %d 块）", cap, cosines.count) : ""
            return "闸门逐块 cos（门限 \(String(format: "%.2f", SpeakerGate.threshold))）：" + body + tail
        }
    }

    /// 跑一趟判定，**原地**改 `source`。不复制整条：长素材那一份就是几百 MB，
    /// 而这一趟头顶上正压着 386 MB 的 sv 图，两份并一份都嫌。
    ///
    /// `embed` 是把一块 PCM 换成说话人向量的那一步——真机上是 ① 那张图（`ChainDriver`
    /// 给的，整趟只载一次），对拍时可以塞一个假的，所以这文件本身不碰 ORT。
    static func run(_ source: inout [Float], refSpk: [Float],
                    onProgress: (Int, Int) -> Void = { _, _ in },
                    embed: ([Float]) throws -> [Float]) throws -> Report {
        let t0 = Date()
        let sr = AudioProcessor.sampleRate
        let ps = pieces(source)
        var keep = [Bool](repeating: true, count: ps.count)
        var cos: [(sec: Double, cos: Double)] = []

        var dimsChecked = false
        for k in 0..<ps.count {
            let one = ps[k]
            let e = try embed(Array(source[one.start..<one.end]))
            if !dimsChecked {
                guard e.count == refSpk.count else {
                    throw ChainError.shape("闸门：① 这一块吐 \(e.count) 个数，样本里的 spk 是 "
                                           + "\(refSpk.count) 个——两张图不是同一种音色向量，没法比")
                }
                dimsChecked = true
            }
            let c = cosine(e, refSpk)
            cos.append((Double(one.start) / sr, c))
            keep[k] = c >= threshold
            if (k + 1) % 8 == 0 { onProgress(k + 1, ps.count) }
        }

        var dropped = 0
        var droppedSecs = 0.0
        for k in 0..<ps.count where !keep[k] {
            dropped += 1
            droppedSecs += Double(ps[k].end - ps[k].start) / sr
        }
        // 一块都没留下＝这条片子里根本没有选定那个人（或者门限太紧）。
        // 这时候把整条清零交出去，界面上只看得见"换完了但一句声音都没有"，得听完整条才知道坏了；
        // 所以在原地动刀之前先一句话说明白。
        if ps.count > 0, dropped == ps.count {
            let worst = cos.map { $0.cos }.max() ?? 0
            throw ChainError.input(String(format: "闸门：判过的 %d 块没有一块像这个音色（最像的一块只有 %.2f，"
                                           + "门限 %.2f）⇒ 要么样本选错了，要么门限太紧。"
                                           + "源没动，请换一个样本或者关掉「只留一个人」再来一遍",
                                           ps.count, worst, threshold))
        }
        for k in 0..<ps.count where !keep[k] {
            var i = ps[k].start
            while i < ps[k].end {
                source[i] = 0
                i += 1
            }
        }

        var lo = 1.0, hi = -1.0
        for one in cos {
            if one.cos < lo { lo = one.cos }
            if one.cos > hi { hi = one.cos }
        }
        return Report(sourceSecs: Double(source.count) / sr, pieces: ps.count,
                      keptPieces: ps.count - dropped, droppedPieces: dropped,
                      droppedSecs: droppedSecs, maxPieceSecs: maxPieceSecs,
                      minCos: cos.isEmpty ? 0 : lo, maxCos: cos.isEmpty ? 0 : hi,
                      wallSeconds: Date().timeIntervalSince(t0), cosines: cos)
    }

    // MARK: - 切块

    /// 一刀一刀的落点：标称每 `maxPieceSecs` 一块，每一刀在这一格前后 ±`cutSearchSecs` 里找
    /// 能量最低的那一格下刀——两个人换口的地方多半就是一个低谷，躲得开就躲开，块里就只剩一个人。
    /// 两刀之间最少隔 `minPieceSecs`，尾巴不足这个数的并进前面那一块。
    ///
    /// 为什么不做「静音块跳过」：试过，而且是错的那一侧。跳过的块等于原封不动过了链，
    /// 别人声音只要比整条轻一些（女声大嗓、男声压着说）就整片漏网；而判一块静音再清零，
    /// 一个耳朵都听不出来。所以整条都判，能量只用来决定刀口往哪儿挪。
    static func pieces(_ src: [Float]) -> [(start: Int, end: Int)] {
        let cell = Int((cellSecs * AudioProcessor.sampleRate).rounded())
        let n = src.count
        guard cell > 0, n > cell else { return [] }
        let nCells = (n + cell - 1) / cell
        let maxCells = max(2, Int((maxPieceSecs * AudioProcessor.sampleRate).rounded()) / cell)
        let minCells = max(1, Int((minPieceSecs * AudioProcessor.sampleRate).rounded()) / cell)
        let lookCells = max(0, Int((cutSearchSecs * AudioProcessor.sampleRate).rounded()) / cell)

        var cellRms = [Double](repeating: 0, count: nCells)
        for c in 0..<nCells {
            cellRms[c] = rms(src, c * cell, min((c + 1) * cell, n))
        }

        var out: [(start: Int, end: Int)] = []
        var a = 0
        while a < nCells {
            if nCells - a <= maxCells {                     // 最后一块：一直到结尾
                out.append((a * cell, n))
                break
            }
            var cut = a + maxCells
            let lo = a + minCells
            let hi = min(nCells - 1, a + maxCells + lookCells)
            if hi > lo {                                    // 刀口挪到附近最安静的那一格
                var bestV = Double.greatestFiniteMagnitude
                var k = lo
                while k <= hi {
                    if cellRms[k] < bestV {
                        bestV = cellRms[k]
                        cut = k
                    }
                    k += 1
                }
            }
            out.append((a * cell, cut * cell))
            a = cut
        }
        if out.count > 1 {
            let last = out.count - 1
            if out[last].end - out[last].start < minCells * cell {
                out[last - 1].end = n                       // 太短的尾巴：并进前面那一块
                out.removeLast()
            }
        }
        return out
    }

    // MARK: - 两把尺

    /// 一段样本的均方根。隔 8 个取一个，和 `VoiceEngine.quietCut` 同一口径
    /// （16 kHz 下等于拿 2 kHz 看音量，找低谷够用，整条扫一遍也不花钱）。
    static func rms(_ src: [Float], _ from: Int, _ to: Int) -> Double {
        var s = 0.0
        var counted = 0
        var i = from
        while i < to {
            let v = Double(src[i])
            s += v * v
            counted += 1
            i += 8
        }
        return counted > 0 ? (s / Double(counted)).squareRoot() : 0.0
    }

    /// 两条说话人向量的余弦。全零（参考没解出来）按 0 给，不炸也不给一个假的高分。
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let m = min(a.count, b.count)
        guard m > 0 else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        var i = 0
        while i < m {
            let x = Double(a[i])
            let y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
            i += 1
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
