import Foundation
import AVFoundation

/// MeanVC 推理管线：SV 嵌入 → DiT 去噪 → Vocos 声码器
/// 当前是骨架，等 ONNX Runtime iOS 集成后填入真实推理。
final class VoiceEngine {
    let modelDir: URL

    init(modelDir: URL) {
        self.modelDir = modelDir
    }

    /// inputWav: 用户录的源语音
    /// refWav: 目标音色的参考语音（当前版本先用同一段，后续加参考选择）
    /// outputWav: 转换后的输出路径
    func convert(inputWav: URL, refWav: URL, outputWav: URL) async throws {
        // TODO: 加载 ONNX Runtime session
        // 1. SV 提取 refWav 的 speaker embedding
        // 2. DiT 以 embedding 为条件对 inputWav 做去噪（7 步，每步一个 state 文件）
        // 3. Vocos 把去噪结果解码成波形
        // 4. 写入 outputWav

        throw NSError(domain: "VoiceEngine", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "推理尚未实现，等 ONNX Runtime 集成"])
    }
}
