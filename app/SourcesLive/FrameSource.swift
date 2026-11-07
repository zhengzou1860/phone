//
//  FrameSource.swift
//  手机侧出帧：相册视频用 AVAssetReader 硬解（kCVPixelFormatType_32BGRA 输出即走
//  VideoToolbox），缩放用 vImage、编码用 ImageIO，产出 JPEG 交给 SwapClient.push。
//
//  为什么在手机解码而不是上传文件：MP4 的 moov 常在文件尾，PC 没收完整片就解不开，
//  「先传完再处理」那一段首帧等待就省不掉。手机解完只推 640 宽的 JPEG。
//
//  这个文件不碰 UIKit（SwiftUI/PHPicker 在 PageViewController.swift 里），
//  所以 CI 能在 mac 上直接把它 swiftc 进自测跑一遍真编码。
//

import AVFoundation
import Accelerate
import CoreGraphics
import ImageIO

// MARK: - 像素缓冲 → JPEG

enum FrameCodec {
    /// BGRA pixel buffer 缩到 maxWidth 宽再编码成 JPEG。
    /// 不用 UIImageJPEGRepresentation：A13 上它慢到能拖垮帧率。
    static func jpeg(_ pb: CVPixelBuffer, maxWidth: Int, quality: CGFloat) -> Data? {
        let srcW = CVPixelBufferGetWidth(pb)
        let srcH = CVPixelBufferGetHeight(pb)
        guard srcW > 0, srcH > 0, maxWidth > 1 else { return nil }
        let dstW = max(2, min(srcW, maxWidth))
        let dstH = max(2, Int(Double(srcH) * Double(dstW) / Double(srcW)))

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let srcBase = CVPixelBufferGetBaseAddress(pb) else { return nil }

        var src = vImage_Buffer(data: srcBase,
                                height: vImagePixelCount(srcH),
                                width: vImagePixelCount(srcW),
                                rowBytes: CVPixelBufferGetBytesPerRow(pb))
        var dst = vImage_Buffer()
        guard vImageBuffer_Init(&dst, vImagePixelCount(dstH), vImagePixelCount(dstW),
                                32, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        guard let dstBase = dst.data else { return nil }

        let scaleErr = vImageScale_ARGB8888(&src, &dst, nil,
                                            vImage_Flags(kvImageHighQualityResampling))
        if scaleErr != kvImageNoError {
            free(dstBase)
            return nil
        }
        // vImage_Buffer 的字段叫 rowBytes（不是 bytesPerRow）；它可能比 dstW*4 大，
        // 后面建 CGImage 必须用同一个数，不然每行错位、图像斜掉。
        let rowBytes = Int(dst.rowBytes)
        let length = rowBytes * Int(dst.height)
        // 拷一份而不是 bytesNoCopy 接管：所有权只有一条路，免得 Data 和 free 抢同一块内存。
        // 一帧 640×360 是 0.9MB，15fps 拷 13MB/s，跟解码编码本身的开销比可以忽略。
        let bytes = Data(bytes: dstBase, count: length)
        free(dstBase)

        guard let provider = CGDataProvider(data: bytes as CFData),
              let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let img = CGImage(width: dstW, height: dstH,
                                bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: rowBytes,
                                space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue:
                                    CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out,
                                                          "public.jpeg" as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, img, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// 解回来验尺寸，自测用它判「编码通路真的通了」。
    /// 直接解成 CGImage 读宽高，不走属性字典：CFDictionary 桥回 Swift 是 [String: Any]，
    /// 当 [CFString: Any] 取键一只拿不到，判据就变成假的 nil（CI 第一轮就是这么报的）。
    static func decodedSize(_ jpeg: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return CGSize(width: img.width, height: img.height)
    }
}

// MARK: - 相册视频出帧

final class VideoFrameSource {
    var targetWidth = LiveConfig.fallbackMaxWidth
    var jpegQuality: CGFloat = LiveConfig.jpegQuality
    /// 推送节奏。源帧率高于它时按 PTS 抽帧，不靠 sleep 硬压。
    var pushFPS: Double = LiveConfig.pushFPS

    var onJPEG: ((Data) -> Void)?
    /// 读到片尾回调（被 stop() 打断则不回调）。
    var onSegmentEnd: (() -> Void)?
    /// 失败要说得出原因：装机的手机在几百公里外，回一句「起不来」等于没报。
    var onError: ((String) -> Void)?

    private(set) var duration: CMTime = .zero
    private(set) var naturalSize: CGSize = .zero
    private(set) var sourceFPS: Double = 0

    private var asset: AVURLAsset?
    private var track: AVAssetTrack?
    private var reader: AVAssetReader?
    private let queue = DispatchQueue(label: "live.frame.video")

    /// 读线程写、主线程每秒读：CMTime 不是原子类型，裸读写属于数据竞争（真机上偶发崩溃）。
    /// running 同理，stop() 在主线程写、reader 循环在后台读。
    private let stateLock = NSLock()
    private var _currentPTS = CMTime.zero
    /// 每一轮 reader 一个代数。stop() 只把代数往前推，不碰 AVAssetReader：
    /// cancelReading() 和后台 copyNextSampleBuffer() 并发是未定义行为，实测会 SIGSEGV
    /// （日志里点停止后只写出「用户点了停止」就断线）。旧循环下一圈发现代数变了就自己退出，
    /// 退出前也不会再把旧帧发出去。
    private var _generation: UInt64 = 0
    private var _running = false

    var currentPTS: CMTime {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentPTS
    }

    private var running: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _running
    }

    private func setPTS(_ pts: CMTime) {
        stateLock.lock()
        _currentPTS = pts
        stateLock.unlock()
    }

    /// 作废当前这一轮读线程，返回新代数。只在主线程调用。
    private func invalidateGeneration() -> UInt64 {
        stateLock.lock()
        _generation &+= 1
        _running = false
        let g = _generation
        stateLock.unlock()
        return g
    }

    /// 启动新代数。读线程每圈都用这个数问自己还算不算数。
    private func beginGeneration() -> UInt64 {
        stateLock.lock()
        _generation &+= 1
        _running = true
        let g = _generation
        stateLock.unlock()
        return g
    }

    private func isCurrent(_ gen: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _running && _generation == gen
    }

    private func endGeneration(_ gen: UInt64) {
        stateLock.lock()
        if _generation == gen { _running = false }
        stateLock.unlock()
    }

    /// 分段睡，每 20ms 回来看一眼代数：停止/跳转不用等满一整个抽帧间隔。
    private func sleepPacing(_ seconds: Double, gen: UInt64) -> Bool {
        var remain = seconds
        while remain > 0 {
            guard isCurrent(gen) else { return false }
            let slice = min(remain, 0.02)
            usleep(useconds_t(slice * 1_000_000))
            remain -= slice
        }
        return isCurrent(gen)
    }

    // 出帧账目：读线程写、主线程每 10 秒取一次，中间必须加锁。
    private let statLock = NSLock()
    private var costSumMs: Double = 0
    private var costCount = 0
    private var gapMaxMs: Double = 0
    private var lastEmitWall: TimeInterval = 0
    private var encodeFailures = 0

    var isRunning: Bool { running }
    var hasClip: Bool { asset != nil && track != nil }

    /// 取走一个窗口的出帧账目（取完清零，看的是这 10 秒而不是整段）。
    /// 编码耗时只算 FrameCodec 本身，间隔算两次编码完成之间——用户看到的卡顿
    /// 就落在这两个数上：编码慢会顶高耗时，节奏断会顶高间隔。
    func takeSendStats() -> (costMs: Double, gapMs: Double) {
        statLock.lock()
        let cost = costCount > 0 ? costSumMs / Double(costCount) : 0
        let gap = gapMaxMs
        costSumMs = 0
        costCount = 0
        gapMaxMs = 0
        statLock.unlock()
        return (cost, gap)
    }

    /// 编码失败是「画面卡住但链路没断」的一条隐藏原因：失败不报错，只是那一帧没发。
    func takeEncodeFailures() -> Int {
        statLock.lock()
        defer { statLock.unlock() }
        let n = encodeFailures
        encodeFailures = 0
        return n
    }

    private func noteEncode(costMs: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        statLock.lock()
        costSumMs += costMs
        costCount += 1
        if lastEmitWall > 0 {
            let gap = (now - lastEmitWall) * 1000
            if gap > gapMaxMs { gapMaxMs = gap }
        }
        lastEmitWall = now
        statLock.unlock()
    }

    private func resetStats() {
        statLock.lock()
        costSumMs = 0
        costCount = 0
        gapMaxMs = 0
        lastEmitWall = 0
        encodeFailures = 0
        statLock.unlock()
    }

    func load(url: URL) {
        stop()
        setPTS(.zero)
        let a = AVURLAsset(url: url)
        guard let t = a.tracks(withMediaType: .video).first else {
            onError?("这个文件里没有视频轨")
            return
        }
        asset = a
        track = t
        duration = a.duration
        naturalSize = t.naturalSize
        sourceFPS = Double(t.nominalFrameRate)
    }

    /// AVAssetReader 开始读以后不能 seek，只能换 timeRange 重建——手机上跳转就走这条路。
    @discardableResult
    func start(from: CMTime = .zero) -> Bool {
        stop()
        guard let asset = asset, let track = track else {
            onError?("还没选视频")
            return false
        }
        let r: AVAssetReader
        do {
            r = try AVAssetReader(asset: asset)
        } catch {
            onError?("解不开这个文件：\(error.localizedDescription)")
            return false
        }
        // 只有真跳转时才设 timeRange：AVURLAsset.duration 在部分文件上是 indefinite，
        // 硬算 end 会让 reader 起不来。
        let fromSec = CMTimeGetSeconds(from)
        let durSec = CMTimeGetSeconds(duration)
        if duration.isValid, durSec.isFinite, fromSec > 0, durSec > fromSec {
            r.timeRange = CMTimeRange(start: from, end: duration)
        }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        guard r.canAdd(out) else {
            onError?("这台手机解不了这条片子的编码")
            return false
        }
        r.add(out)
        guard r.startReading() else {
            onError?("读帧失败：\((r.error?.localizedDescription) ?? "未知")")
            return false
        }
        reader = r
        let gen = beginGeneration()
        setPTS(from)
        resetStats()
        AppLog.shared.log("frame", "出帧起：代数 \(gen) 从 "
                          + String(format: "%.3f", max(0, CMTimeGetSeconds(from))) + "s")

        queue.async { [weak self] in
            guard let self = self else { return }
            var originWall: TimeInterval = 0
            var originPTS: CMTime?
            var nextEmit: Double?
            var emitted = 0
            var reanchors = 0
            while self.isCurrent(gen), r.status == .reading,
                  let sb = out.copyNextSampleBuffer() {
                // copyNextSampleBuffer 可能刚跨过一次 stop：先认代数，旧帧一律不发。
                guard self.isCurrent(gen) else { break }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                guard pts.isValid else { continue }
                let sec = CMTimeGetSeconds(pts)
                // 间隔每圈现取：跳转后重建 reader 时配置可能刚改过，用旧值会多推/少推。
                // 头 6 帧按 1/3 速走（0.28 起播缓发）：PC 冷启动那一秒正被入口队列丢帧顶着。
                let interval = LivePace.interval(full: 1.0 / max(1.0, self.pushFPS),
                                                 emitted: emitted)
                let pace = LivePace.decide(ptsSeconds: sec, nextEmitSeconds: nextEmit,
                                           interval: interval)
                guard pace.emit else { continue }
                nextEmit = pace.nextEmitSeconds
                // ImageIO/CGImage 在同一轮里会挂一批 autorelease 对象；这条队列没有
                // 系统自动池，不显式兜住会一路涨到被系统杀掉（看起来就是闪退）。
                let jpeg: Data? = autoreleasepool {
                    let encodeStart = CFAbsoluteTimeGetCurrent()
                    guard let pb = CMSampleBufferGetImageBuffer(sb),
                          let out = FrameCodec.jpeg(pb, maxWidth: self.targetWidth,
                                                    quality: self.jpegQuality) else { return nil }
                    self.noteEncode(costMs: (CFAbsoluteTimeGetCurrent() - encodeStart) * 1000)
                    return out
                }
                guard self.isCurrent(gen) else { break }
                guard let jpeg = jpeg else {
                    self.statLock.lock()
                    self.encodeFailures += 1
                    self.statLock.unlock()
                    continue
                }
                if originPTS == nil {
                    originWall = CFAbsoluteTimeGetCurrent()
                    originPTS = pts
                }
                self.onJPEG?(jpeg)
                if emitted == LiveConfig.rampFrames {
                    AppLog.shared.log("frame", "起播缓发结束：前 \(LiveConfig.rampFrames) 帧按 "
                                      + String(format: "%.0f", self.pushFPS / Double(LiveConfig.rampDivisor))
                                      + "fps，之后回 " + String(format: "%.0f", self.pushFPS) + "fps")
                }
                emitted += 1
                guard self.isCurrent(gen) else { break }
                self.setPTS(pts)

                // 按 PTS 对齐墙钟：推流节奏 = 视频真实播放节奏。
                // 早了就 sleep 等到位；落后超过一帧就搬锚点、欠的不补发（0.28 前是「不 sleep 连着追」，
                // 那一追就是 4–5 帧同一瞬间砸到 PC 的 2 格入口）。
                let start = originPTS ?? pts
                let due = originWall + (sec - CMTimeGetSeconds(start))
                let delay = due - CFAbsoluteTimeGetCurrent()
                if LivePace.shouldReanchor(delay: delay, interval: interval) {
                    // 欠得超过一帧：把锚点搬到当下，欠的那几帧就当没它们——不补发。
                    originWall = CFAbsoluteTimeGetCurrent()
                    originPTS = pts
                    reanchors += 1
                    if reanchors == 1 {
                        AppLog.shared.log("frame", "墙钟重对齐：欠 "
                                          + String(format: "%.2f", -delay)
                                          + "s 的帧不补发（补发就是往 PC 那 2 格里一次砸好几帧）")
                    }
                } else if delay.isFinite, delay > 0 {
                    // 源时间戳偶尔会给出半个世纪这种值：直接 UInt32 会在真机上 trap。
                    guard self.sleepPacing(min(delay, 0.5), gen: gen) else { break }
                }
            }
            let completed = (r.status == .completed)
            let stillCurrent = self.isCurrent(gen)
            if stillCurrent { self.endGeneration(gen) }
            AppLog.shared.log("frame", "读线程退出：代数 \(gen) status=\(r.status.rawValue)"
                              + " 当前=\(stillCurrent ? "是" : "否")"
                              + " 发出 \(emitted) 帧·墙钟重对齐 \(reanchors) 次")
            // 只有自然读到片尾、且这一轮没被停/跳转作废，才算「这一段推完了」
            if stillCurrent && completed {
                DispatchQueue.main.async { self.onSegmentEnd?() }
            }
        }
        return true
    }

    func stop() {
        // 不在这里 cancelReading：那是主线程对后台正在读的 AVAssetReader 动手，
        // 正是两次 SIGSEGV 的现场。作废代数后，读线程会在 20ms 内自己退出，
        // 退出时由它自己释放 reader（等价于取消），不会再碰旧画面。
        let gen = invalidateGeneration()
        reader = nil
        AppLog.shared.log("frame", "出帧停：代数 \(gen)")
    }
}
