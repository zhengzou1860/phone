import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var models = ModelManager()
    @StateObject private var audio = AudioEngine()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    modelSection
                    if case .downloaded = models.state {
                        recordSection
                        convertSection
                    }
                }
                .padding()
            }
            .navigationTitle("声音克隆")
            .onAppear {
                models.check()
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("模型状态")
                .font(.headline)

            switch models.state {
            case .checking:
                Text("检查中…")
                    .foregroundColor(.secondary)
            case .notDownloaded:
                VStack(alignment: .leading, spacing: 8) {
                    Text("模型未下载（约 750 MB）")
                        .foregroundColor(.secondary)
                    Button("下载模型") {
                        models.download()
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .downloading:
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: models.progress)
                    Text(models.progressText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            case .downloaded:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(models.progressText)
                }
            case .failed(let msg):
                VStack(alignment: .leading, spacing: 8) {
                    Text("失败: \(msg)")
                        .foregroundColor(.red)
                    Button("重试") {
                        models.check()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("录音")
                .font(.headline)

            HStack(spacing: 15) {
                Button {
                    audio.startRecording()
                } label: {
                    Label("录音", systemImage: "mic.fill")
                }
                .buttonStyle(.bordered)
                .disabled(audio.isRecording)

                Button {
                    audio.stopRecording()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!audio.isRecording)
            }

            if let url = audio.recordedURL {
                Text("已录制: \(url.lastPathComponent)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var convertSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("转换")
                .font(.headline)

            Button("开始转换") {
                // TODO: 调用 VoiceEngine
            }
            .buttonStyle(.borderedProminent)
            .disabled(audio.recordedURL == nil)
        }
    }
}
