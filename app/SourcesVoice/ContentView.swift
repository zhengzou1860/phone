import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var models = ModelManager()
    @StateObject private var srcRec = AudioEngine()
    @StateObject private var refRec = AudioEngine()
    @StateObject private var player = PlayController()
    @State private var engine: VoiceEngine?
    @State private var isConverting = false
    @State private var convertStatus = ""
    @State private var outputURL: URL?
    @State private var sendStatus = ""
    @State private var isSending = false
    @State private var feReport = ""
    @State private var isRunningFE = false

    // 两个槽：源（要转换的那段）和参考（目标音色）。各自要么录一段、要么从「文件」里选一个。
    @State private var sourceURL: URL?
    @State private var refURL: URL?
    @State private var pickingSource = false
    @State private var pickingRef = false
    @State private var pickNote = ""

    /// public.audio 是个大类，wav/m4a/mp3/aiff 全在里面；列出来只是让「文件」里默认看得见它们。
    private let pickTypes: [UTType] = [.audio, .wav, .mpeg4Audio, .mp3, .aiff]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    modelSection
                    if case .downloaded = models.state {
                        audioSlot("① 源音频（要转换的那段）", rec: srcRec,
                                  url: $sourceURL, picking: $pickingSource)
                        audioSlot("② 参考音频（目标音色；不选就是自转换）", rec: refRec,
                                  url: $refURL, picking: $pickingRef)
                        if !pickNote.isEmpty {
                            Text(pickNote).font(.caption).foregroundColor(.secondary)
                        }
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
        .fileImporter(isPresented: $pickingSource, allowedContentTypes: pickTypes) { result in
            sourceURL = adopt(result)
        }
        .fileImporter(isPresented: $pickingRef, allowedContentTypes: pickTypes) { result in
            refURL = adopt(result)
        }
    }

    // MARK: - 两个音频槽

    @ViewBuilder
    private func audioSlot(_ title: String, rec: AudioEngine,
                           url: Binding<URL?>, picking: Binding<Bool>) -> some View {
        let anyRecording = srcRec.isRecording || refRec.isRecording
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            HStack(spacing: 12) {
                Button(rec.isRecording ? "录制中…" : "录一段") {
                    rec.startRecording()
                }
                .buttonStyle(.bordered)
                .disabled(anyRecording || isConverting)

                Button("停止") {
                    rec.stopRecording()
                    url.wrappedValue = rec.recordedURL
                }
                .buttonStyle(.bordered)
                .disabled(!rec.isRecording)

                Button("选文件") { picking.wrappedValue = true }
                    .buttonStyle(.bordered)
                    .disabled(isConverting)
            }
            if let u = url.wrappedValue {
                Text("当前：" + u.lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("空的")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// fileImporter 给的是安全作用域 URL，回调一返回就失效 ⇒ 当场拷进 Documents 再用。
    /// 不拷的话就是手机上那一类「文件明明在，读的时候说不存在」。
    private func adopt(_ result: Result<[URL], Error>) -> URL? {
        switch result {
        case .failure(let err):
            pickNote = "选文件失败：" + err.localizedDescription
            VoiceJournal.line("选文件失败：\(err.localizedDescription)")
            return nil
        case .success(let urls):
            guard let src = urls.first else {
                pickNote = "没选中文件"
                return nil
            }
            let granted = src.startAccessingSecurityScopedResource()
            defer { if granted { src.stopAccessingSecurityScopedResource() } }
            let ext = src.pathExtension.isEmpty ? "wav" : src.pathExtension
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let dest = docs.appendingPathComponent("pick_\(Int(Date().timeIntervalSince1970)).\(ext)")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: src, to: dest)
                let size = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? 0
                pickNote = "已拷进 app：" + dest.lastPathComponent + "（\(size / 1024) KB）"
                VoiceJournal.line("选文件 \(src.lastPathComponent) → \(dest.lastPathComponent) \(size / 1024) KB，授权=\(granted)")
                return dest
            } catch {
                pickNote = "拷进来失败：" + error.localizedDescription
                VoiceJournal.line("拷选中的文件失败：\(error.localizedDescription)")
                return nil
            }
        }
    }

    // MARK: - 模型状态

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

    // MARK: - 转换

    @ViewBuilder
    private var convertSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("转换")
                .font(.headline)

            Button("开始转换") {
                startConversion()
            }
            .buttonStyle(.borderedProminent)
            .disabled(sourceURL == nil || isConverting || srcRec.isRecording || refRec.isRecording)

            if sourceURL == nil {
                Text("先在 ① 录一段或选一个音频文件")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if refURL == nil {
                Text("② 空的 ⇒ 这次是自转换（音色还是你自己的）")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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
                    player.play(url: url)
                } label: {
                    Label(player.isPlaying ? "播放中" : "播放",
                          systemImage: player.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(player.isPlaying)

                Button {
                    player.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!player.isPlaying)
            }

            if !player.status.isEmpty {
                Text(player.status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func startConversion() {
        guard let modelDir = models.modelDir,
              let inputURL = sourceURL else { return }
        // ② 没填就退回源自己 —— 和上一版行为一致，界面上也已经写了「这次是自转换」
        let refInput = refURL ?? inputURL

        isConverting = true
        convertStatus = "加载模型…"
        VoiceJournal.line("开始转换 源=\(inputURL.lastPathComponent) 参考=\(refInput.lastPathComponent)")

        if engine == nil {
            engine = VoiceEngine(modelDir: modelDir)
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let output = docs.appendingPathComponent("output_\(Int(Date().timeIntervalSince1970)).wav")

        Task {
            do {
                convertStatus = "提取音色特征…"
                try await engine?.convert(inputWav: inputURL,
                                          refWav: refInput,
                                          outputWav: output,
                                          onStage: { text in
                    // 推理线程回调 → 跳回主线程改文案（ContentView 是 struct，
                    // @State 的 setter 是 nonmutating，闭包里捕获的副本写回同一块存储）。
                    DispatchQueue.main.async { convertStatus = text }
                })
                await MainActor.run {
                    outputURL = output
                    isConverting = false
                    convertStatus = "转换完成"
                }
            } catch {
                await MainActor.run {
                    isConverting = false
                    convertStatus = "失败：\(error.localizedDescription)"
                    VoiceJournal.line("转换失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 诊断

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
}
