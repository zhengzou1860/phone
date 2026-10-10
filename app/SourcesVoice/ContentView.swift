import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var models = ModelManager()
    @StateObject private var audio = AudioEngine()
    @State private var engine: VoiceEngine?
    @State private var isConverting = false
    @State private var convertStatus = ""
    @State private var outputURL: URL?
    @State private var isPlaying = false
    @State private var player: AVAudioPlayer?
    @State private var sendStatus = ""
    @State private var isSending = false
    @State private var feReport = ""
    @State private var isRunningFE = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    modelSection
                    if case .downloaded = models.state {
                        recordSection
                        convertSection
                        if let url = outputURL {
                            playbackSection(url: url)
                        }
                    }
                    debugSection
                }
                .padding()
            }
            .navigationTitle("声音克隆")
            .onAppear {
                VoiceJournal.line("ContentView.onAppear")
                models.check()
            }
        }
    }

    @ViewBuilder
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("诊断")
                .font(.headline)
            Text("版本 \(appVersion())　\(VoiceFacts.lines()[2])")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(isRunningFE ? "自检跑着…" : "跑前端自检") {
                runFrontEndSelfTest()
            }
            .buttonStyle(.bordered)
            .disabled(isRunningFE)
            if !feReport.isEmpty {
                Text(feReport)
                    .font(.caption)
                    .textSelection(.enabled)
            }

            Button(isSending ? "发送中…" : "发到电脑") {
                sendReport()
            }
            .buttonStyle(.bordered)
            .disabled(isSending)
            if !sendStatus.isEmpty {
                Text(sendStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func appVersion() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] ?? "-") (\(info["CFBundleVersion"] ?? "-"))"
    }

    /// 前端自检拿包里的合成 fixture 对拍，逐元素量 max_abs。
    /// 跑在后台线程：1 s 音频 98 帧 FFT，手机上也就几十毫秒，别卡住按钮的置灰动画。
    private func runFrontEndSelfTest() {
        isRunningFE = true
        feReport = "算着…"
        Task.detached {
            let text = MelFrontEnd.selfTest()
            VoiceJournal.line("前端自检：\(text.replacingOccurrences(of: "\n", with: " ／ "))")
            await MainActor.run {
                feReport = text
                isRunningFE = false
            }
        }
    }

    private func sendReport() {
        isSending = true
        sendStatus = ""
        let facts = VoiceFacts.lines().joined(separator: "\n")
        let fe = feReport.isEmpty ? "（自检还没跑过——先点「跑前端自检」）" : feReport
        let text = "—— 现场读数 ——\n" + facts
            + "\n\n—— 前端自检 ——\n" + fe
            + "\n\n—— 模型状态 ——\n" + models.progressText
            + "\n\n—— 磁盘日志最近 200 行 ——\n" + VoiceJournal.tail(200)
        // ContentView 是 struct，不能 [weak self]；@State 的 setter 是 nonmutating，
        // 闭包里捕获的 struct 副本写回去仍然是同一块存储。
        Task.detached {
            let r = VoiceUploader.send(text)
            await MainActor.run {
                sendStatus = r
                isSending = false
                VoiceJournal.line("发到电脑：\(r)")
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
                    Text("模型未下载（下载 581 MB，解压后占 726 MB）")
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
                .disabled(audio.isRecording || isConverting)

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
                startConversion()
            }
            .buttonStyle(.borderedProminent)
            .disabled(audio.recordedURL == nil || isConverting)

            if isConverting {
                Text(convertStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func playbackSection(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("转换结果")
                .font(.headline)

            HStack(spacing: 15) {
                Button {
                    play(url: url)
                } label: {
                    Label(isPlaying ? "播放中" : "播放",
                          systemImage: isPlaying ? "speaker.wave.2.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(isPlaying)

                Button {
                    stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!isPlaying)
            }

            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func startConversion() {
        guard let modelDir = models.modelDir,
              let inputURL = audio.recordedURL else { return }

        isConverting = true
        convertStatus = "加载模型…"

        // 初始化引擎
        if engine == nil {
            engine = VoiceEngine(modelDir: modelDir)
        }

        // 输出文件路径
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let output = docs.appendingPathComponent("output_\(Int(Date().timeIntervalSince1970)).wav")

        Task {
            do {
                convertStatus = "提取音色特征…"
                try await engine?.convert(inputWav: inputURL,
                                          refWav: inputURL,  // 当前版本用同一段音频
                                          outputWav: output)
                await MainActor.run {
                    outputURL = output
                    isConverting = false
                    convertStatus = "转换完成"
                }
            } catch {
                await MainActor.run {
                    isConverting = false
                    convertStatus = "失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func play(url: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
            isPlaying = true
        } catch {
            print("播放失败：\(error)")
        }
    }

    private func stop() {
        player?.stop()
        isPlaying = false
    }
}
