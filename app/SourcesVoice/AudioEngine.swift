import Foundation
import AVFoundation

@MainActor
final class AudioEngine: ObservableObject {
    @Published var isRecording = false
    @Published var recordedURL: URL?

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?

    func startRecording() {
        guard !isRecording else { return }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("record_\(Int(Date().timeIntervalSince1970)).wav")
        recordedURL = url

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        do {
            audioFile = try AVAudioFile(forWriting: url,
                                        settings: format.settings,
                                        commonFormat: .pcmFormatFloat32,
                                        interleaved: false)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self = self, let file = self.audioFile else { return }
                try? file.write(from: buffer)
            }

            try engine.start()
            isRecording = true
        } catch {
            print("录音启动失败: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        isRecording = false
    }
}
