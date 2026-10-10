import Foundation
import AVFoundation
import onnxruntime_objc

/// MeanVC 推理管线：SV 嵌入 → DiT 去噪 → Vocos 声码器
final class VoiceEngine {
    let modelDir: URL
    var env: ORTEnv?
    var svSession: ORTSession?
    var ditSessions: [ORTSession] = []
    var vocosSession: ORTSession?

    init(modelDir: URL) {
        self.modelDir = modelDir
    }

    /// 加载所有模型（首次调用时）
    func loadModels() throws {
        let env = try ORTEnv()
        self.env = env

        // 加载 SV 模型
        let svURL = modelDir.appendingPathComponent("sv_dynamic_len.onnx")
        svSession = try ORTSession(env: env, modelURL: svURL)

        // 加载 DiT 7 个状态文件
        for i in 0..<7 {
            let ditURL = modelDir.appendingPathComponent("dit_state_\(i).onnx")
            let session = try ORTSession(env: env, modelURL: ditURL)
            ditSessions.append(session)
        }

        // 加载 Vocos 声码器
        let vocosURL = modelDir.appendingPathComponent("vocos.onnx")
        vocosSession = try ORTSession(env: env, modelURL: vocosURL)
    }

    /// 从参考音频提取 speaker embedding（192 维）
    func extractEmbedding(refWav: URL) throws -> [Float] {
        guard let session = svSession else {
            throw NSError(domain: "VoiceEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "SV 模型未加载"])
        }

        // 加载音频并计算 mel 频谱
        let samples = try AudioProcessor.loadWAV(refWav)
        let mel = AudioProcessor.melSpectrogram(samples)

        // 准备输入：[1, nMels, nFrames]
        let nFrames = mel.count / AudioProcessor.nMels
        let inputShape: [Int] = [1, AudioProcessor.nMels, nFrames]

        // 创建 ORTValue
        let inputValue = try ORTValue.tensor(with: mel, shape: inputShape)

        // 运行推理
        let outputs = try session.run(inputNames: ["mel"],
                                      inputValues: [inputValue],
                                      outputNames: ["embedding"])

        // 提取 embedding（192 维）
        guard let output = outputs.first else {
            throw NSError(domain: "VoiceEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "SV 输出为空"])
        }
        let embedding = try output.tensorData() as! [Float]
        return embedding
    }

    /// DiT 去噪（7 步，每步一个 state 文件）
    func denoise(inputMel: [Float], embedding: [Float]) throws -> [Float] {
        var currentMel = inputMel

        for (step, session) in ditSessions.enumerated() {
            // 准备输入
            let nFrames = currentMel.count / AudioProcessor.nMels
            let melShape: [Int] = [1, AudioProcessor.nMels, nFrames]
            let embShape: [Int] = [1, 192]

            let melValue = try ORTValue.tensor(with: currentMel, shape: melShape)
            let embValue = try ORTValue.tensor(with: embedding, shape: embShape)

            // 运行推理
            let outputs = try session.run(inputNames: ["mel", "embedding"],
                                          inputValues: [melValue, embValue],
                                          outputNames: ["denoised_mel"])

            // 更新 mel
            guard let output = outputs.first else {
                throw NSError(domain: "VoiceEngine", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "DiT 步骤 \(step) 输出为空"])
            }
            currentMel = try output.tensorData() as! [Float]
        }

        return currentMel
    }

    /// Vocos 声码器：mel → 波形
    func vocode(mel: [Float]) throws -> [Float] {
        guard let session = vocosSession else {
            throw NSError(domain: "VoiceEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Vocos 模型未加载"])
        }

        let nFrames = mel.count / AudioProcessor.nMels
        let melShape: [Int] = [1, AudioProcessor.nMels, nFrames]
        let melValue = try ORTValue.tensor(with: mel, shape: melShape)

        let outputs = try session.run(inputNames: ["mel"],
                                      inputValues: [melValue],
                                      outputNames: ["waveform"])

        guard let output = outputs.first else {
            throw NSError(domain: "VoiceEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Vocos 输出为空"])
        }
        let waveform = try output.tensorData() as! [Float]
        return waveform
    }

    /// 完整的语音转换流程
    func convert(inputWav: URL, refWav: URL, outputWav: URL) async throws {
        // 加载模型（如果还没加载）
        if svSession == nil {
            try loadModels()
        }

        // 1. 提取参考音频的 speaker embedding
        let embedding = try extractEmbedding(refWav: refWav)

        // 2. 加载输入音频并计算 mel 频谱
        let inputSamples = try AudioProcessor.loadWAV(inputWav)
        let inputMel = AudioProcessor.melSpectrogram(inputSamples)

        // 3. DiT 去噪（7 步）
        let denoisedMel = try denoise(inputMel: inputMel, embedding: embedding)

        // 4. Vocos 解码成波形
        let waveform = try vocode(mel: denoisedMel)

        // 5. 保存为 WAV 文件
        try AudioProcessor.saveWAV(waveform, to: outputWav)
    }
}
