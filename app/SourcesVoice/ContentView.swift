import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// 哪个槽在选文件。共用一个呈现，源槽和参考槽不再各挂一个 fileImporter。
enum PickSlot: String, Identifiable {
    case source
    case ref
    var id: String { rawValue }
}

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

    // 两个音频槽：源（要转换的那段）和参考（目标音色）。各自要么录一段、要么从「文件」里选一个。
    @State private var sourceURL: URL?
    @State private var refURL: URL?
    @State private var pickSlot: PickSlot?
    @State private var pickNote = ""

    // 样本清单
    @State private var samples: [SampleStore.Sample] = []
    @State private var pickedID: String?
    @State private var sampleName = ""
    @State private var isMakingSample = false
    @State private var makeNote = ""
    @State private var renamingID: String?
    @State private var renameDraft = ""

    // 链外旋钮：只要音高（语速不做——播放软件都有）
    @State private var semitones: Double = 0
    @State private var showShare = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    modelSection
                    if case .downloaded = models.state {
                        audioSlot("① 源音频（要转换的那段）", rec: srcRec,
                                  url: $sourceURL, slot: .source)
                        refSlot
                        sampleList
                        paramSection
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
                samples = SampleStore.list()
                models.check()
            }
        }
        // 一个呈现给两个槽。fileImporter 换成自己包的 picker：
        // 同视图挂两个 fileImporter 只有一个生效（① 点了没反应），且 [.audio,…] 的
        // 类型过滤在这环境下把列表全刷灰（② 进了目录选不了文件）。
        .fullScreenCover(item: $pickSlot) { slot in
            DocumentPickerHost(onPick: { url in
                let got = copyIn(url)
                if slot == .source { sourceURL = got } else { refURL = got }
            }, onCancel: { msg in
                pickNote = "没选成：" + msg
                VoiceJournal.line("选文件取消（槽=\(slot.rawValue)）：\(msg)")
            }, onDismiss: {
                pickSlot = nil
            })
        }
    }

    // MARK: - ② 参考槽（多一个「生成样本」的动作）

    @ViewBuilder
    private var refSlot: some View {
        VStack(alignment: .leading, spacing: 10) {
            audioSlotBody("② 参考音频（目标音色；不选也不选样本就自转换）", rec: refRec,
                          url: $refURL, slot: .ref)
            HStack(spacing: 12) {
                TextField("样本名字（留空＝按时间）", text: $sampleName)
                    .textFieldStyle(.roundedBorder)
                Button(isMakingSample ? "生成中…" : "生成样本") { makeSampleFromRef() }
                    .buttonStyle(.bordered)
                    .disabled(refURL == nil || isMakingSample || isConverting || srcRec.isRecording || refRec.isRecording)
            }
            Text("样本 = 音色向量 1 KB + 150 帧 prompt mel 47 KB，做一次反复用。参考音频硬下限 1.5 s（DiT 的 prompts 钉死 150 帧），但 PC 实测像不像随样本长度单调涨：1.5 s→0.636、3 s→0.705、6 s→0.748、10.9 s→0.759（尺：同人 0.928／两人 0.089）⇒ 录 6~10 s 连续干净说话，别只录一两个字。")
                .font(.caption)
                .foregroundColor(.secondary)
            if !makeNote.isEmpty {
                Text(makeNote).font(.caption).foregroundColor(.orange)
            }
        }
    }

    // MARK: - 样本清单

    @ViewBuilder
    private var sampleList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("样本清单（转换时用哪个音色）")
                .font(.headline)
            if samples.isEmpty {
                Text("空的。在 ② 录一段或选一个文件，然后点「生成样本」。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ForEach(samples) { s in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Button {
                            pickedID = (pickedID == s.id) ? nil : s.id
                            VoiceJournal.line("选样本 \(s.info.name)（\(s.id)）")
                        } label: {
                            Image(systemName: pickedID == s.id ? "largecircle.fill.circle" : "circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(pickedID == s.id ? .accentColor : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.info.name)
                            Text(String(format: "%@　%.1f s%@　%@",
                                        s.info.created, s.info.seconds,
                                        s.info.seconds < 6.0 ? "（偏短）" : "", s.id))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("改名") {
                            renamingID = s.id
                            renameDraft = s.info.name
                        }
                        .buttonStyle(.bordered)
                        Button("删") {
                            deleteSample(s)
                        }
                        .buttonStyle(.bordered)
                    }
                    if renamingID == s.id {
                        HStack(spacing: 10) {
                            TextField("新名字", text: $renameDraft).textFieldStyle(.roundedBorder)
                            Button("保存") { commitRename(s) }.buttonStyle(.borderedProminent)
                            Button("取消") { renamingID = nil }.buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 链外旋钮：音高

    @ViewBuilder
    private var paramSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("音高").font(.headline)
            HStack {
                Text(String(format: "%+.0f 半音", semitones))
                    .frame(width: 80, alignment: .leading)
                Slider(value: $semitones, in: -12...12, step: 1)
            }
            Button("归零") { semitones = 0 }
                .buttonStyle(.bordered)
            Text("加在④声码之后的波形上（链外移调，官方模型自己没这个参数）：只动音高不动时长。男声转女声一般抬 +2 ~ +5。语速不做——播放器都有。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 两个音频槽的公共部分

    @ViewBuilder
    private func audioSlot(_ title: String, rec: AudioEngine,
                           url: Binding<URL?>, slot: PickSlot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            audioSlotBody(title, rec: rec, url: url, slot: slot)
        }
    }

    @ViewBuilder
    private func audioSlotBody(_ title: String, rec: AudioEngine,
                               url: Binding<URL?>, slot: PickSlot) -> some View {
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

                Button("选文件") {
                    VoiceJournal.line("点「选文件」槽=\(slot.rawValue)")
                    pickSlot = slot
                }
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
            Text(slot == .source
                 ? "源：输出和源一样长。实测 12 s 源 → 峰值足迹 242 MB、墙钟 4.3 s（2.8× 实时），内存和时间都按长度线性涨 ⇒ 1 分钟素材约 11 s。硬门：文件解开来超 512 MB 会直接报错（48 kHz 立体声约 13 分钟、16 kHz 单声道约 44 分钟），不会撑爆闪退。"
                 : "参考：只有前 20 s 参与算音色（① 的内存随参考长度平方涨，40.6 s 实测顶到 1749 MB，前台水位线约 2040 MB）⇒ 长文件也只读前 20 s，音色尺 6 s 就基本平了。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// asCopy:true 给的 URL 已经在沙盒临时区、当场可读，但那个区随时会被清 ⇒ 立刻拷进 Documents 固化。
    /// 顺手就地开一次：能开就报真实格式读数，开不了就是"这不是能播的音频"，别等到转换才炸。
    private func copyIn(_ src: URL) -> URL? {
        let ext = src.pathExtension.isEmpty ? "wav" : src.pathExtension
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dest = docs.appendingPathComponent("pick_\(Int(Date().timeIntervalSince1970)).\(ext)")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: src, to: dest)
            let size = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? 0
            let probe = probeAudio(dest)
            pickNote = "已拷进 app：" + dest.lastPathComponent + "（\(size / 1024) KB）" + probe
            VoiceJournal.line("选文件 \(src.lastPathComponent) → \(dest.lastPathComponent) \(size / 1024) KB，\(probe)")
            return dest
        } catch {
            pickNote = "拷进来失败：" + error.localizedDescription
            VoiceJournal.line("拷选中的文件失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 就地开一次 AVAudioFile，读真实格式；打不开就退回"不是能播的音频"这句话。
    /// 这一步只读文件头，不解码，几百微秒，不影响按钮的置灰动画。
    private func probeAudio(_ url: URL) -> String {
        guard let f = try? AVAudioFile(forReading: url) else {
            return "／ 打不开：不像音频文件"
        }
        let fmt = f.processingFormat
        let frames = Int(f.length)
        return String(format: "／ %d 帧 / %d Hz / %d 声道 / %.2f s",
                      frames, Int(fmt.sampleRate), Int(fmt.channelCount),
                      Double(frames) / fmt.sampleRate)
    }

    // MARK: - 样本动作

    private func makeSampleFromRef() {
        guard let ref = refURL, let modelDir = models.modelDir else { return }
        let name = sampleName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "样本 " + Self.dayStamp() : sampleName
        isMakingSample = true
        makeNote = "生成中…这一步要载 sv 图（实测约 4 s）"
        VoiceJournal.line("点「生成样本」名字=\(name) 参考=\(ref.lastPathComponent)")
        if engine == nil { engine = VoiceEngine(modelDir: modelDir) }
        let eng = engine!
        Task {
            do {
                let s = try await eng.makeSample(fromWav: ref, name: name)
                await MainActor.run {
                    samples = SampleStore.list()
                    pickedID = s.id
                    isMakingSample = false
                    if s.info.seconds < 6.0 {
                        makeNote = String(format: "已生成「%@」，但参考只有 %.1f s（实测 6 s 才饱和）⇒ 大概率不够像，重录一段 6~10 s 的",
                                          s.info.name, s.info.seconds)
                        VoiceJournal.line("样本偏短 \(s.info.name) \(String(format: "%.1f", s.info.seconds)) s")
                    } else {
                        makeNote = "已生成「\(s.info.name)」，已选中"
                    }
                    sampleName = ""
                }
            } catch {
                await MainActor.run {
                    isMakingSample = false
                    makeNote = "生成失败：" + error.localizedDescription
                    VoiceJournal.line("生成样本失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func commitRename(_ s: SampleStore.Sample) {
        let name = renameDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { renamingID = nil; return }
        do {
            let updated = try SampleStore.rename(s, to: name)
            if let i = samples.firstIndex(where: { $0.id == s.id }) { samples[i] = updated }
            renamingID = nil
        } catch {
            pickNote = "改名失败：" + error.localizedDescription
            renamingID = nil
        }
    }

    private func deleteSample(_ s: SampleStore.Sample) {
        SampleStore.delete(s)
        if pickedID == s.id { pickedID = nil }
        samples = SampleStore.list()
    }

    private static func dayStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date())
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
                    Text("模型未下载（下载 581 MB，解压后占 700 MB）")
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

            Button(isConverting ? "转换中…" : "开始转换") {
                startConversion()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canConvert || isConverting)

            if sourceURL == nil {
                Text("先在 ① 录一段或选一个音频文件")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if pickedID == nil && refURL == nil {
                Text("没选样本、② 也空的 ⇒ 这次是自转换（音色还是你自己的）")
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

    private var canConvert: Bool {
        sourceURL != nil && !srcRec.isRecording && !refRec.isRecording
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

                Button {
                    VoiceJournal.line("点「导出」 \(url.lastPathComponent)")
                    showShare = true
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            .sheet(isPresented: $showShare) {
                // LiveContainer 里 UIActivityViewController 没实测过；起不来就是这一片空白，
                // 日志里那句「导出面板已弹起」不出现即是证据，兜底是路径本身就在屏幕上。
                ShareSheet(items: [url],
                           onDismiss: { showShare = false },
                           onPresent: {
                    VoiceJournal.line("导出面板已弹起（可「存储到“文件”」）")
                })
            }

            if !player.status.isEmpty {
                Text(player.status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(url.path)
                .font(.caption2)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }

    private func startConversion() {
        guard let modelDir = models.modelDir, let inputURL = sourceURL else { return }
        let picked = samples.first { $0.id == pickedID }
        let using: String
        if let p = picked {
            using = "样本「\(p.info.name)」"
        } else if let r = refURL {
            using = "现场参考 \(r.lastPathComponent)"
        } else {
            using = "自转换（源自己当参考）"
        }

        isConverting = true
        convertStatus = "加载模型…"
        VoiceJournal.line(String(format: "开始转换 源=%@ 音色=%@ 音高 %+.0f 半音",
                                 inputURL.lastPathComponent, using, semitones))
        if engine == nil {
            engine = VoiceEngine(modelDir: modelDir)
        }
        let eng = engine!
        // 选了样本就不必给参考；没样本时用 ②；② 也空 ⇒ 拿源自己当参考（自转换）
        let refForJob: URL? = picked != nil ? nil : (refURL ?? inputURL)

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let output = docs.appendingPathComponent("output_\(Int(Date().timeIntervalSince1970)).wav")

        Task {
            do {
                convertStatus = "提取音色特征…"
                try await eng.convert(inputWav: inputURL,
                                      sample: picked,
                                      refWav: refForJob,
                                      outputWav: output,
                                      pitchCents: semitones * 100.0,
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
        let names = samples.isEmpty ? "（样本清单空）" :
            samples.map { $0.info.name }.joined(separator: "、")
        let text = "—— 现场读数 ——\n" + facts
            + "\n\n—— 前端自检 ——\n" + fe
            + "\n\n—— 模型状态 ——\n" + models.progressText
            + "\n\n—— 样本清单 ——\n" + names
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
