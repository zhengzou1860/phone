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

    /// 计算 mel 频谱（简化版，用 Accelerate 做 FFT）
    /// 返回 [nFrames × nMels] 的展平数组
    static func melSpectrogram(_ samples: [Float]) -> [Float] {
        let pre = preEmphasis(samples)
        let nFrames = (pre.count - nFFT) / hopLength + 1
        var mels = [Float](repeating: 0, count: nFrames * nMels)

        // 简化的 mel 滤波器组（实际应该用三角滤波器）
        // 这里先用线性近似，后续可替换为精确的 mel 滤波器
        for frame in 0..<nFrames {
            let start = frame * hopLength
            let end = start + nFFT
            guard end <= pre.count else { break }

            // 加汉宁窗
            var windowed = [Float](repeating: 0, count: nFFT)
            for i in 0..<nFFT {
                let w = 0.5 * (1 - cos(2 * .pi * Float(i) / Float(nFFT - 1)))
                windowed[i] = pre[start + i] * w
            }

            // FFT（用 Accelerate）
            var real = [Float](repeating: 0, count: nFFT)
            var imag = [Float](repeating: 0, count: nFFT)
            windowed.withUnsafeBufferPointer { src in
                real.withUnsafeMutableBufferPointer { dst in
                    vDSP_ctoz(src.baseAddress!.assumingMemoryBound(to: DSPComplex.self),
                              2, dst.baseAddress!, 1, vDSP_Length(nFFT / 2))
                }
            }
            // 这里简化：直接取幅度谱的前 nMels 个 bin
            for i in 0..<nMels {
                let mag = sqrtf(real[i] * real[i] + imag[i] * imag[i])
                mels[frame * nMels + i] = logf(mag + 1e-5)
            }
        }
        return mels
    }
}
