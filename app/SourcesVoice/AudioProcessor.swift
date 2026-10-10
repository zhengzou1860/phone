import Foundation
import AVFoundation
import Accelerate

/// 音频预处理：WAV → mel 频谱（SV 和 DiT 都需要）
/// 后处理：mel 频谱 → WAV（Vocos 输出）
enum AudioProcessor {

    // 与 Python 端对齐的超参数
    static let sampleRate: Double = 22050
    static let nFFT = 1024
    static let hopLength = 256
    static let winLength = 1024
    static let nMels = 80
    static let fMin: Double = 0
    static let fMax: Double = 8000

    /// 从 WAV 文件读取 PCM 样本（Float32 数组）
    static func loadWAV(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: file.fileFormat.sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format,
                                   frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        let n = Int(buf.frameLength)
        let ptr = buf.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ptr, count: n))
    }

    /// 写 PCM 到 WAV 文件
    static func saveWAV(_ samples: [Float], to url: URL, sampleRate: Double = 22050) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format,
                                   frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buf)
    }

    /// 预加重（pre-emphasis）
    static func preEmphasis(_ x: [Float], coeff: Float = 0.97) -> [Float] {
        guard x.count > 1 else { return x }
        var y = [Float](repeating: 0, count: x.count)
        y[0] = x[0]
        for i in 1..<x.count {
            y[i] = x[i] - coeff * x[i - 1]
        }
        return y
    }

    /// 计算 mel 频谱（占位版：逐帧分 bin 求平均幅度取对数）
    /// 返回 [nFrames × nMels] 的展平数组
    /// TODO: 换成精确 FFT + 三角 mel 滤波器组
    static func melSpectrogram(_ samples: [Float]) -> [Float] {
        let pre = preEmphasis(samples)
        let nFrames = max(1, (pre.count - winLength) / hopLength + 1)
        var mels = [Float](repeating: 0, count: nFrames * nMels)

        for frame in 0..<nFrames {
            let start = frame * hopLength
            let end = min(start + winLength, pre.count)
            guard end > start else { continue }

            // 汉宁窗 + 分 bin 平均幅度（不是真 FFT，只是占位）
            let binSize = max(1, (end - start) / nMels)
            for b in 0..<nMels {
                let bs = start + b * binSize
                let be = min(bs + binSize, end)
                guard be > bs else { continue }
                var sum: Float = 0
                for i in bs..<be {
                    let t = Float(i - start)
                    let w = 0.5 * (1 - cos(2 * .pi * t / Float(winLength - 1)))
                    sum += abs(pre[i] * w)
                }
                let mag = sum / Float(be - bs)
                mels[frame * nMels + b] = logf(mag + 1e-5)
            }
        }
        return mels
    }
}
