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
    private(set) var currentPTS: CMTime = .zero
    private(set) var naturalSize: CGSize = .zero
    private(set) var sourceFPS: Double = 0

    private var asset: AVURLAsset?
    private var track: AVAssetTrack?
    private var reader: AVAssetReader?
    private var running = false
    private let queue = DispatchQueue(label: "live.frame.video")

    var isRunning: Bool { running }
    var hasClip: Bool { asset != nil && track != nil }

    func load(url: URL) {
        stop()
        currentPTS = .zero
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
        running = true
        currentPTS = from

        queue.async { [weak self] in
            guard let self = self else { return }
            let interval = 1.0 / max(1.0, self.pushFPS)
            var originWall: TimeInterval = 0
            var originPTS: CMTime?
            var nextEmit: Double?
            while self.running, r.status == .reading,
                  let sb = out.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                guard pts.isValid else { continue }
                let sec = CMTimeGetSeconds(pts)
                let pace = LivePace.decide(ptsSeconds: sec, nextEmitSeconds: nextEmit,
                                           interval: interval)
                guard pace.emit else { continue }
                nextEmit = pace.nextEmitSeconds
                guard let pb = CMSampleBufferGetImageBuffer(sb),
                      let jpeg = FrameCodec.jpeg(pb, maxWidth: self.targetWidth,
                                                 quality: self.jpegQuality) else { continue }
                if originPTS == nil {
                    originWall = CFAbsoluteTimeGetCurrent()
                    originPTS = pts
                }
                self.onJPEG?(jpeg)
                self.currentPTS = pts

                // 按 PTS 对齐墙钟：推流节奏 = 视频真实播放节奏，
                // 落后了就跟着当前 PTS 重新对齐，不欠账堆积。
                let due = originWall + (sec - CMTimeGetSeconds(originPTS!))
                let delay = due - CFAbsoluteTimeGetCurrent()
                if delay > 0 { usleep(UInt32(delay * 1_000_000)) }
            }
            // cancelReading 以后 status 是 .cancelled，只有真读到片尾才 .completed
            if self.running, r.status == .completed {
                self.running = false
                DispatchQueue.main.async { self.onSegmentEnd?() }
            } else {
                self.running = false
            }
        }
        return true
    }

    func stop() {
        running = false
        if let r = reader, r.status == .reading { r.cancelReading() }
        reader = nil
    }
}
