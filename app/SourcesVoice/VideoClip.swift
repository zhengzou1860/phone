import Foundation
import AVFoundation
import AudioToolbox      // kAudioFormatLinearPCM / kAudioFormatMPEG4AAC 定义在这一层，不写死就赌 AVFoundation 的传递可见性
import CoreMedia

/// 视频这条线的进和出：把音轨解成链子吃的 16 kHz 单声道 Float，再把换好声的 wav 塞回原来那条画面。
///
/// 为什么画面走**透传**：这一条线一个像素都不动，只换声音 ⇒ 不解码不重编，
/// 原样把码流块交给 muxer（`outputSettings: nil` + 轨自己的 formatDescriptions 当提示）。
/// 同一棵树上的换脸线已经拿这套写法在真机把音频原样搬通过（app/SourcesSwap/SwapClip.swift:347-378），
/// 那里音频是透传、画面是重编；这里反过来。反过来这一半真机上没验过，所以不在一种口径上押死：
/// 容器（mp4／mov）× 音轨（AAC／原样 PCM）四组按兼容性从好到差挨个试，成哪组用哪组。
/// `canAdd` 只回答「加不加得进去」，配不出来是跑到一半的事 ⇒ 每组的失败都带 domain#code 进日志。
///
/// 音频读的是 `withAudioBufferList`：AVFoundation 在闭包里给一份**保证连续**的 AudioBufferList，
/// 所以不用自己碰 CMBlockBuffer 那几个 C 函数。采样率/声道也一并写进 outputSettings，
/// 降采样和解码是同一次做的 ⇒ 常驻只有 16 kHz 单声道这一份（64 KB/秒），不按原生格式摊开。
enum VideoClip {

    /// 一条视频的体检读数。选完文件就地报一遍，别等点「开始」才发现选错了东西。
    struct Info {
        var hasVideo = false
        var hasAudio = false
        var videoSecs = 0.0
        var audioSecs = 0.0
        var containerSecs = 0.0
        /// 两条轨各自在源时间轴上的起点。相差大 ⇒ 成片会带上同样的偏移（透传不改时间戳）。
        var videoStart = 0.0
        var audioStart = 0.0
        var bytes: Int64 = 0

        var playable: Bool { hasVideo && hasAudio }

        /// 界面上那一行。没有的那一条要说清缺什么，空串／「0 s」都不算回答。
        var line: String {
            if bytes == 0 && !hasVideo && !hasAudio { return "读不出内容：不像本机认得的视频" }
            let v = hasVideo ? String(format: "画面 %.2f s", videoSecs) : "没有画面轨"
            let a = hasAudio ? String(format: "音轨 %.2f s", audioSecs) : "没有音轨"
            let off = hasVideo && hasAudio
                ? (abs(videoStart - audioStart) > 0.02
                    ? String(format: "／两轨起点差 %.0f ms（成片照带）", (audioStart - videoStart) * 1000) : "")
                : ""
            return String(format: "%@／%@／容器 %.2f s／%@%@",
                          v, a, containerSecs, FileHistory.human(bytes), off)
        }
    }

    /// 只读文件头和轨道清单，不解码 ⇒ 几百毫秒，够得着按钮的置灰动画。
    static func probe(_ url: URL) -> Info {
        var i = Info()
        let asset = AVURLAsset(url: url)
        i.containerSecs = secs(asset.duration)
        if let t = asset.tracks(withMediaType: .video).first {
            i.hasVideo = true
            i.videoSecs = secs(t.timeRange.duration)
            i.videoStart = secs(t.timeRange.start)
        }
        if let t = asset.tracks(withMediaType: .audio).first {
            i.hasAudio = true
            i.audioSecs = secs(t.timeRange.duration)
            i.audioStart = secs(t.timeRange.start)
        }
        i.bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return i
    }

    /// CMTimeGetSeconds 对 invalid/null 时间给的是 NaN，直接进 %.2f 就成了 "nan"。
    private static func secs(_ t: CMTime) -> Double {
        let s = CMTimeGetSeconds(t)
        return s.isFinite ? s : 0
    }

    /// 整条音轨 → 16 kHz 单声道 Float [-1,1]，口径和 `AudioProcessor.loadWAV16K` 完全一致。
    ///
    /// 一次解到底、不在这里分段：分段是 `VoiceEngine` 的事（② 的绝对位置表只有 5000 行 ⇒ 一遍 200 s），
    /// 那一层已经会挑最安静的一格下刀，切点得在同一条连续时间轴上找。
    static func extractAudio(_ url: URL, say: (String) -> Void) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw ChainError.input("\(url.lastPathComponent) 里没有音轨")
        }
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw ChainError.input("读这条音轨的 AVAssetReader 建不起来")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioProcessor.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        // try? + if let：这个 init 在 SDK 里到底是可失败还是 IUO，两种写法都撞过编译墙，
        // 这一对组合是唯一同时成立的（同换脸线 SwapClip.swift:360 那处已上机的写法）。
        let ao = try? AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard let out = ao else {
            throw ChainError.input("16k 单声道 PCM 输出建不出来（这条音轨的编码本机解不了？）")
        }
        reader.add(out)
        guard reader.startReading() else {
            throw ChainError.input("音轨 startReading 失败：\(reader.error?.localizedDescription ?? "-")")
        }
        let est = Int(secs(track.timeRange.duration) * AudioProcessor.sampleRate)
        var buf = [Float]()
        buf.reserveCapacity(max(est, 0))
        var blocks = 0
        var empty = 0
        while let sb = out.copyNextSampleBuffer() {
            blocks += 1
            let before = buf.count
            do {
                try sb.withAudioBufferList { abl, _ in
                    for b in abl {
                        guard let raw = b.mData else { continue }
                        let base = raw.assumingMemoryBound(to: Float.self)
                        let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                        if n > 0 { buf.append(contentsOf: UnsafeBufferPointer(start: base, count: n)) }
                    }
                }
            } catch {
                throw ChainError.input("第 \(blocks) 块音频取不出样本：\(error.localizedDescription)")
            }
            if buf.count == before { empty += 1 }
        }
        if reader.status.rawValue == 4 {   // failed：只认编号，这个枚举不保证每个成员都有 Swift 名字
            throw ChainError.input("解到一半 reader 报错：\(reader.error?.localizedDescription ?? "-")")
        }
        guard !buf.isEmpty else {
            throw ChainError.input("音轨读到 \(blocks) 块，倒出来 0 样本（\(empty) 块是空的）")
        }
        say(String(format: "音轨解出 %@：%d 块 / %d 样本 = %.2f s（16k 单声道，空块 %d 个）",
                   url.lastPathComponent, blocks, buf.count,
                   Double(buf.count) / AudioProcessor.sampleRate, empty))
        return buf
    }

    // MARK: - 出：原画面透传 + 新音轨

    struct MuxResult {
        var frames = 0
        var audioBlocks = 0
        var outSeconds = 0.0
        var bytes: Int64 = 0
        var wall = 0.0
        var note = ""
        /// 成片实际是用哪一组口径配出来的（`candidates` 里那一个名字）。
        var cfgName = ""
    }

    /// 一次回写用的口径：容器 + 音轨输出设置 + 界面认得的扩展名。
    struct MuxCfg {
        let name: String
        let ext: String
        let fileType: AVFileType
        let audioSettings: [String: Any]
    }

    static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: AudioProcessor.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
    ]

    /// 不编音轨：样本原样进容器。真机上「编音轨」这一格从没通过（换脸线是原样透传旧音轨、
    /// VR 线只编画面），所以留这条退路。
    static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: AudioProcessor.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    /// 按「他拿去播的兼容性」从好到差排：mp4 在前，AAC 在前。0.1/32 那一跑死在
    /// `writer failed Cannot Encode Media`，日志分不出是容器不收这条画面码流还是音轨编码器起不来
    /// ⇒ 一趟里挨个试这四组，成哪组用哪组，每组失败的 domain#code 都留在日志里当判决。
    static let candidates: [MuxCfg] = [
        MuxCfg(name: "mp4+AAC", ext: "mp4", fileType: .mp4, audioSettings: aacSettings),
        MuxCfg(name: "mov+AAC", ext: "mov", fileType: .mov, audioSettings: aacSettings),
        MuxCfg(name: "mp4+PCM", ext: "mp4", fileType: .mp4, audioSettings: pcmSettings),
        MuxCfg(name: "mov+PCM", ext: "mov", fileType: .mov, audioSettings: pcmSettings),
    ]

    /// 把 `audioWav` 装到 `video` 原来那条画面上，落 `out`。
    ///
    /// 顺序规矩是从换脸线真机撞出来的那一条：**画面不许越过最后喂进去那块音频的起点**。
    /// muxer 按时间交错写盘，音轨前沿落到画面后头编码器就不收画面了——老写法只在 append 成功之后
    /// 才喂音频，于是不收 ⇒ 不喂 ⇒ 互等 15 秒死掉（app/SourcesSwap/SwapClip.swift:409-415 那段注释）。
    /// 所以这里每搬一块画面前先把音频往前喂 2 秒，卡在队列上也照样继续喂。
    ///
    /// `cfg` 决定容器和音轨输出口径（调用方从 `candidates` 里按顺序挑，不成换下一组）。
    static func mux(video: URL, audioWav: URL, out: URL, cfg: MuxCfg,
                    say: (String) -> Void) throws -> MuxResult {
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        let t0 = Date()

        let asset = AVURLAsset(url: video)
        guard let vt = asset.tracks(withMediaType: .video).first else {
            throw ChainError.input("\(video.lastPathComponent) 里没有画面轨")
        }
        let picSecs = secs(vt.timeRange.duration)
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw ChainError.input("读原片的 AVAssetReader 建不起来")
        }
        let vFds = vt.formatDescriptions
        // 空数组才没提示；非空时这个元素本身就是 CMFormatDescription（SDK 里 `as?` 到 CF 类型是 error：恒成立）
        let vHint: CMFormatDescription? = vFds.isEmpty ? nil : (vFds[0] as! CMFormatDescription)
        guard let hint = vHint else {
            throw ChainError.input("画面轨的 formatDescriptions 是空的（0 条）→ 透传没提示可给")
        }
        let vo = try? AVAssetReaderTrackOutput(track: vt, outputSettings: nil)
        guard let vOut = vo else {
            throw ChainError.input("画面轨的透传输出建不出来（子类型 \(fourcc(hint))）")
        }
        reader.add(vOut)

        say("回写口径 \(cfg.name)｜画面子类型 \(fourcc(hint))｜片源 \(video.lastPathComponent)")

        guard let writer = try? AVAssetWriter(outputURL: out, fileType: cfg.fileType) else {
            throw ChainError.input("AVAssetWriter 建不起来（\(out.lastPathComponent)，容器 \(cfg.fileType.rawValue)）")
        }
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        vin.expectsMediaDataInRealTime = false
        guard writer.canAdd(vin) else {
            try? fm.removeItem(at: out)
            throw ChainError.input("canAdd 为假［\(cfg.name)］：这条画面码流（\(fourcc(hint))）本机 muxer 不收"
                                   + "｜\(errText(writer.error))")
        }
        writer.add(vin)

        // 新音轨：链子写好的 wav 用第二个 reader 读回 PCM 块，writer 那条输入带 cfg 给的输出口径
        // ⇒ 重编发生在 writer 内部，这里一块样本都不用自己拼。
        let wAsset = AVURLAsset(url: audioWav)
        guard let wTrack = wAsset.tracks(withMediaType: .audio).first else {
            throw ChainError.input("换好声的 \(audioWav.lastPathComponent) 里没有音轨（wav 头没回填？）")
        }
        guard let wReader = try? AVAssetReader(asset: wAsset) else {
            throw ChainError.input("读 \(audioWav.lastPathComponent) 的 AVAssetReader 建不起来")
        }
        let wOut0 = try? AVAssetReaderTrackOutput(track: wTrack, outputSettings: nil)
        guard let aOut = wOut0 else {
            throw ChainError.input("\(audioWav.lastPathComponent) 的输出生不出来")
        }
        wReader.add(aOut)
        let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: cfg.audioSettings)
        ain.expectsMediaDataInRealTime = false
        guard writer.canAdd(ain) else {
            throw ChainError.input("canAdd 为假［\(cfg.name)］：16k 单声道这条音轨输出本机不收"
                                   + "｜\(errText(writer.error))")
        }
        writer.add(ain)

        do { try writer.startWriting() } catch {
            reader.cancelReading()
            try? fm.removeItem(at: out)
            throw ChainError.input("startWriting 抛错［\(cfg.name)］：\(errText(error))")
        }
        writer.startSession(atSourceTime: .zero)
        // 不显式开读，copyNextSampleBuffer 第一下就回 nil ⇒ 看起来「跑完了」其实 0 帧
        guard reader.startReading() else {
            writer.cancelWriting()
            try? fm.removeItem(at: out)
            throw ChainError.input("画面 startReading 失败：\(readerName(reader.status)) \(errText(reader.error))")
        }
        guard wReader.startReading() else {
            writer.cancelWriting()
            try? fm.removeItem(at: out)
            throw ChainError.input("音频 startReading 失败：\(readerName(wReader.status)) \(errText(wReader.error))")
        }
        // 死在配置阶段还是跑到一半是两回事。上一版没这一道，日志只剩一句 writer failed，
        // 于是「容器不收这条画面码流」和「音轨编码器起不来」两种可能分不开。
        guard writer.status.rawValue == 1 else {
            writer.cancelWriting()
            try? fm.removeItem(at: out)
            throw ChainError.input("开读之后 writer 就不是 writing 了［\(cfg.name)］："
                                   + "\(writerName(writer.status)) \(errText(writer.error))"
                                   + "｜音轨那份 \(audioWav.lastPathComponent)")
        }

        var frames = 0
        var aOK = 0
        var aNote = ""
        var aDone = false
        var aHaveFed = false
        var aFedTo = CMTime.zero
        var firstV = "-"
        var firstA = "-"
        // 音频往前喂的顶＝画面这条轨的长度（不是容器长度：容器常带一段比画面长的音轨尾巴，
        // 喂过它成片就变成结尾有声音没画面）
        let audioCeil = CMTimeMakeWithSeconds(max(0.0, picSecs - 0.05), preferredTimescale: 600)

        func pumpAudio(until pts: CMTime) {
            guard aNote.isEmpty, !aDone else { return }
            while writer.status.rawValue == 1 {     // 1 = writing
                if aHaveFed && CMTimeCompare(aFedTo, pts) >= 0 { return }
                if !ain.isReadyForMoreMediaData { return }
                guard let s = aOut.copyNextSampleBuffer() else {
                    if writer.status.rawValue == 1 && wReader.status.rawValue == 1 {
                        aNote = "音轨已到末尾（喂了 \(aOK) 块）"
                    } else {
                        aNote = "音轨停止：writer \(writerName(writer.status))｜reader \(readerName(wReader.status))｜喂了 \(aOK) 块"
                    }
                    // 音轨比画面短：当场关音频那条闸，不然 muxer 一直等音轨，画面最后那截永远写不进去
                    ain.markAsFinished()
                    aDone = true
                    return
                }
                let sPTS = CMSampleBufferGetPresentationTimeStamp(s)
                if !aHaveFed {
                    firstA = String(format: "%.0f", CMTimeGetSeconds(sPTS) * 1000)
                }
                aFedTo = sPTS
                aHaveFed = true
                if ain.append(s) {
                    aOK += 1
                    if aOK == 1 {
                        say("音频 头一块进去了（\(firstA) ms 处）｜画面头一块起点 \(firstV) ms"
                            + "｜两条轨都不移位，起点不同成片口型就偏")
                    }
                } else {
                    aNote = "第 \(aOK + 1) 块音频 append 被拒｜writer \(writerName(writer.status))"
                        + " \(errText(writer.error))｜这条输入 \(errText(ain.error))"
                    return
                }
            }
            if writer.status.rawValue != 1 {
                aNote = "writer 已不是 writing（\(writerName(writer.status))）\(errText(writer.error))"
                    + "｜音轨这条输入 \(errText(ain.error))"
            }
        }

        var why = ""
        while why.isEmpty {
            autoreleasepool {
                guard let sb = vOut.copyNextSampleBuffer() else { why = "片源到末尾"; return }
                guard reader.status.rawValue == 1 else {
                    why = "画面 reader 状态 \(readerName(reader.status))：\(errText(reader.error))"
                    return
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                if frames == 0 {
                    firstV = String(format: "%.0f", CMTimeGetSeconds(pts) * 1000)
                }
                // 音频往前喂 2 秒，但不越过画面轨的末尾：越过去成片就会比画面长出一截
                var ahead = CMTimeAdd(pts, CMTime(value: 2, timescale: 1))
                if CMTimeCompare(ahead, audioCeil) > 0 { ahead = audioCeil }
                pumpAudio(until: ahead)
                var spins = 0
                while !vin.isReadyForMoreMediaData {
                    spins += 1
                    if spins > 3_000 {
                        let fed = aHaveFed ? String(format: "%.3f", CMTimeGetSeconds(aFedTo)) : "-"
                        let an = aNote.isEmpty ? "" : "｜\(aNote)"
                        why = "编码器队列 15 秒不收（第 \(frames) 块画面，PTS \(String(format: "%.3f", CMTimeGetSeconds(pts))) s"
                            + "｜音频喂到 \(fed) s、\(aOK) 块\(an)）"
                        return
                    }
                    if spins % 400 == 0 {
                        say("  编码器不收第 \(frames) 块画面，已等 \(String(format: "%.1f", Double(spins) * 0.005)) s")
                    }
                    pumpAudio(until: ahead)   // 卡住的这一会儿正是该往前喂音频的时候
                    Thread.sleep(forTimeInterval: 0.005)
                }
                if writer.status.rawValue != 1 {
                    let an = aNote.isEmpty ? "" : "｜\(aNote)"
                    why = "writer 已经不是 writing（\(writerName(writer.status))）\(errText(writer.error))"
                        + "｜搬到第 \(frames) 块画面、音频 \(aOK) 块\(an)"
                    return
                }
                // 透传：块原样交出去，时间戳一个数都不改（改了成片就和原片口型对不上）。
                // 也不能 CMSampleBufferInvalidate——append 只是入队，取数据在另一条线程上。
                if !vin.append(sb) {
                    why = "第 \(frames) 块画面 append 被拒｜\(errText(writer.error))｜画面这条输入 \(errText(vin.error))"
                    return
                }
                frames += 1
                if frames % 200 == 0 {
                    say("搬到第 \(frames) 块画面｜音频 \(aOK) 块｜足迹 \(VoiceFacts.footprintMB()) MB")
                }
            }
        }

        if !aDone {
            pumpAudio(until: audioCeil)
            if aNote.isEmpty { aNote = "跟到画面末尾" }
            ain.markAsFinished()
        }
        vin.markAsFinished()
        if reader.status.rawValue == 1 { reader.cancelReading() }
        if wReader.status.rawValue == 1 { wReader.cancelReading() }
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status.rawValue == 2 else {      // 2 = completed
            try? fm.removeItem(at: out)
            throw ChainError.input("成片没收尾［\(cfg.name)］：writer \(writerName(writer.status))"
                                   + " \(errText(writer.error))｜画面 \(frames) 块／音频 \(aOK) 块"
                                   + "｜画面那条 \(errText(vin.error))｜音轨那条 \(errText(ain.error))"
                                   + "｜\(why)")
        }
        // 中途停（队列不收／append 被拒）时 finishWriting 也能 completed，但那份文件画面短了一截 ⇒ 不算成功
        if why != "片源到末尾" {
            try? fm.removeItem(at: out)
            throw ChainError.input("画面只搬了 \(frames) 块就停［\(cfg.name)］：\(why)")
        }

        let bytes = ((try? fm.attributesOfItem(atPath: out.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let wall = Date().timeIntervalSince(t0)
        let tail = aNote.isEmpty ? "" : "｜\(aNote)"
        say(String(format: "回写完成［%@］：画面 %d 块 + 音频 %d 块 → %@ %.1f MB／%.1f s"
            + "｜容器时长 %@ s｜头一块画面起点 %@ ms／音频 %@ ms",
            cfg.name, frames, aOK, out.lastPathComponent, Double(bytes) / 1_048_576, wall,
            String(format: "%.2f", secs(asset.duration)), firstV, firstA) + tail)
        return MuxResult(frames: frames, audioBlocks: aOK,
                         outSeconds: secs(asset.duration), bytes: bytes, wall: wall,
                         note: aNote, cfgName: cfg.name)
    }

    /// FourCC 打成人看的四个字符（h264／hev1／mp4a…），报「本机收不收这条编码」时得说得出是哪路。
    private static func fourcc(_ f: CMFormatDescription) -> String {
        let t = CMFormatDescriptionGetMediaSubType(f)
        let bs = [UInt8((t >> 24) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8((t >> 8) & 0xFF), UInt8(t & 0xFF)]
            .filter { $0 >= 32 && $0 < 127 }
        return String(decoding: bs, as: UTF8.self)
    }
}

// 状态词按 rawValue 翻：这些枚举在本 SDK 里不保证每个成员都有 Swift 名字
// （换脸线第 11 轮就死在 AVAssetReader.Status 没有 .paused 上）。编号是 Objective-C 定死的。
private func writerName(_ s: AVAssetWriter.Status) -> String {
    switch s.rawValue {
    case 0: return "unknown"
    case 1: return "writing"
    case 2: return "completed"
    case 3: return "failed"
    case 4: return "cancelled"
    default: return "其他(\(s.rawValue))"
    }
}

private func readerName(_ s: AVAssetReader.Status) -> String {
    switch s.rawValue {
    case 0: return "unknown"
    case 1: return "reading"
    case 2: return "completed"
    case 3: return "paused"
    case 4: return "failed"
    case 5: return "cancelled"
    default: return "其他(\(s.rawValue))"
    }
}
