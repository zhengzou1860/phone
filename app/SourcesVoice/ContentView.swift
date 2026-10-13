import SwiftUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers

/// 哪个槽在选文件。共用一个呈现，源槽和参考槽不再各挂一个 fileImporter。
/// `text` 和 `video` 也走这一个呈现：一个选的是 .txt/.md，一个选的是视频，都不是音频，
/// 但呈现器只管把文件拿进来，能不能用由我们自己验（见 `TextFile.load`、`VideoClip.probe`）。
enum PickSlot: String, Identifiable {
    case source
    case ref
    case text
    case video
    /// 也借用这一个呈现：嗓音清单页（不是文件选择，见 body 里那个 if）。
    case voice
    /// 同上：历史文件清理页。
    case history
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

    // 读小说：文本 → 系统 TTS → 现有样本那条链（②③④）。音色仍然来自上面选中的样本。
    @State private var novelText = ""
    /// 「文件模式」：选了 txt 就用这份全文，界面不再把它塞进编辑器（几十万字塞进去滚动会卡）。
    @State private var novelFileURL: URL?
    @State private var novelFileText = ""
    @State private var novelFileEnc = ""
    /// 选中的嗓音。空 = 没选过，交给 `SystemTTS.pickVoice` 的排名（普通话 → 质量档高 → 男声）。
    /// 存在 UserDefaults 里：重开 app 不用重挑，也不必每章都试听一遍。
    @State private var voiceID = UserDefaults.standard.string(forKey: "novelVoiceID") ?? ""
    @State private var voiceRows: [SystemTTS.VoiceRow] = []
    @State private var isReading = false
    @State private var readStatus = ""
    @State private var readNote = ""
    @State private var rawTTSURL: URL?

    // 视频换声：一段视频 → 解出音轨 → 现有样本那条链 → 装回原来那条画面（一个像素不动）。
    // 音色来源和读小说一样：要么清单里点中的样本，要么 ② 那段参考。
    @State private var videoURL: URL?
    /// 选完就地读一次文件头（`VideoClip.probe`），所以这里存的是体检数本身，界面上那行和开跑前的预算都从它算。
    @State private var videoProbe: VideoClip.Info?
    @State private var videoOutURL: URL?
    @State private var isVideoing = false
    @State private var videoStatus = ""
    @State private var videoNote = ""
    /// 和音频那条的 `showShare` 分开：一个开关同时挂两个 sheet，弹起来的是哪一个全看 SwiftUI 的心情。
    @State private var showVideoShare = false

    /// 历史文件清理页：Documents 根目录里留下的源/中间/成品。
    /// `wipeArmed` 是「全部删除」的第一次按下 —— 删的是他的录音，一指点没了找不回来，要连点两次。
    @State private var history: [FileHistory.Item] = []
    @State private var historyNote = ""
    @State private var wipeArmed = false

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
                        novelSection
                        videoSection
                        if let url = outputURL {
                            playbackSection(url: url)
                        }
                    }
                    // 放在 if 外面：模型没下（或像 0.1/24 那样被误删）时，留下的录音照样要能删。
                    historySection
                    debugSection
                }
                .padding()
            }
            .navigationTitle("声音克隆 \(appVersion())")
            .onAppear {
                VoiceJournal.line("ContentView.onAppear")
                samples = SampleStore.list()
                history = FileHistory.scan()
                voiceRows = SystemTTS.voiceRows()
                logVoiceRows()
                models.check()
            }
        }
        // 一个呈现给三个槽。fileImporter 换成自己包的 picker：
        // 同视图挂两个 fileImporter 只有一个生效（① 点了没反应），且 [.audio,…] 的
        // 类型过滤在这环境下把列表全刷灰（② 进了目录选不了文件）。
        .fullScreenCover(item: $pickSlot) { slot in
            coverPage(slot)
        }
    }

    /// 一个呈现六种内容：`.voice` 是自己铺的嗓音清单、`.history` 是自己铺的历史文件清单，
    /// 其余四个槽（①②／文本／视频）还是系统文件选择器。
    /// 分支写在带 `@ViewBuilder` 的函数里，不赌 `fullScreenCover` 那个闭包是不是 ViewBuilder。
    @ViewBuilder
    private func coverPage(_ slot: PickSlot) -> some View {
        if slot == .voice {
            voiceListPage
        } else if slot == .history {
            historyPage
        } else {
            DocumentPickerHost(onPick: { url in
                if slot == .text {
                    loadNovelFile(url)
                } else if slot == .video {
                    videoURL = copyInVideo(url)
                } else {
                    let got = copyIn(url)
                    if slot == .source { sourceURL = got } else { refURL = got }
                }
            }, onCancel: { msg in
                pickNote = "没选成：" + msg
                VoiceJournal.line("选文件取消（槽=\(slot.rawValue)）：\(msg)")
            }, onDismiss: {
                pickSlot = nil
            })
        }
    }

    /// 把这台机装的中文语音整份报回电脑：男/女/未标各几个 + 每一行的 label。
    /// 「哪个嗓音低、哪个温柔」最终是他耳朵定的，但候选名单和 identifier 得先看得见。
    private func logVoiceRows() {
        let males = voiceRows.filter { $0.gender == "男" }.count
        let females = voiceRows.filter { $0.gender == "女" }.count
        VoiceJournal.line("本机中文 voice \(voiceRows.count) 个（男 \(males)／女 \(females)／未标 \(voiceRows.count - males - females)）")
        var i = 0
        while i < voiceRows.count {
            let chunk = voiceRows[i..<min(i + 6, voiceRows.count)].map { $0.label }.joined(separator: " ;; ")
            VoiceJournal.line("嗓音 [\(i + 1)…] \(chunk)")
            i += 6
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
                    history = FileHistory.scan()
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
                 ? "源：输出和源一样长。实测 12 s 源 → 峰值足迹 242 MB、墙钟 4.3 s（2.8× 实时），内存和时间都按长度线性涨 ⇒ 1 分钟素材约 11 s。硬门：文件解开来超 512 MB 会直接报错（48 kHz 立体声约 22 分钟、16 kHz 单声道约 2 小时 13 分），不会撑爆闪退。"
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
            history = FileHistory.scan()
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

    /// 视频的固化副本。和音频一样必须先拷进 Documents：asCopy 给的临时区随时会被清，
    /// 而这条线要把同一个文件读两遍（解音轨一遍、回写画面一遍），中间隔着几分钟的链子。
    /// 拷完就地读一次文件头（只读头、不解码，几百毫秒），选错了东西当场就知道，不用等开跑。
    private func copyInVideo(_ src: URL) -> URL? {
        let ext = src.pathExtension.isEmpty ? "mp4" : src.pathExtension
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dest = docs.appendingPathComponent("pick_\(Int(Date().timeIntervalSince1970)).\(ext)")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: src, to: dest)
            let info = VideoClip.probe(dest)
            videoProbe = info
            videoNote = ""
            pickNote = "已拷进 app：" + dest.lastPathComponent + "／" + info.line
            history = FileHistory.scan()
            VoiceJournal.line("选视频 \(src.lastPathComponent) → \(dest.lastPathComponent)：\(info.line)")
            return dest
        } catch {
            pickNote = "拷视频失败：" + error.localizedDescription
            videoProbe = nil
            VoiceJournal.line("拷选中的视频失败：\(error.localizedDescription)")
            return nil
        }
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

    // MARK: - 历史文件（Documents 根目录里留下的源 / 中间 / 成品）

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("历史文件（源 / 中间 / 成品）").font(.headline)
            Button {
                history = FileHistory.scan()
                wipeArmed = false
                historyNote = ""
                VoiceJournal.line("打开历史文件页：\(history.count) 个 / "
                                  + FileHistory.human(FileHistory.total(history)))
                pickSlot = .history
            } label: {
                Text(history.isEmpty ? "查看并清空（app 目录里没有留下的文件）"
                                     : "查看并清空（\(history.count) 个 / \(FileHistory.human(FileHistory.total(history)))）")
            }
            .buttonStyle(.bordered)
            Text("「选文件」拷进来的音频和视频、录的、系统原声、转换成品、换了声的成片都一直留在 app 目录里，播完不会自动删 ⇒ 「文件」app 里直接翻得到。这页逐条删、整类删、一键清空。模型目录（581 MB）、voice_log.txt、样本清单不在这页里，也删不到。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// 清理页：一行一个文件各带一个「删」，每类头上一个「删本类」，最上面「全部删除」连点两次才动手。
    /// 和嗓音清单同一个做法——自己铺行，不用 `List`/`.onDelete`、也不用 navigationLink
    /// （ScrollView 里的系统控件在这台机上有 8/8 闪退的记录）。
    @ViewBuilder
    private var historyPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("历史文件 \(history.count) 个 / \(FileHistory.human(FileHistory.total(history)))")
                    .font(.headline)

                Button(wipeArmed ? "再点一次：确认删掉这 \(history.count) 个" : "全部删除") {
                    wipeAll()
                }
                .buttonStyle(.bordered)
                .disabled(history.isEmpty)

                if wipeArmed {
                    Text("第二次按下就真删，删完找不回来。").font(.caption).foregroundColor(.red)
                }

                ForEach(FileHistory.Kind.allCases) { k in
                    historyGroup(k)
                }
                if history.isEmpty {
                    Text("空的：app 目录里没有留下的文件。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !historyNote.isEmpty {
                    Text(historyNote).font(.caption).foregroundColor(.orange)
                }

                HStack(spacing: 12) {
                    Button("刷新") {
                        history = FileHistory.scan()
                        wipeArmed = false
                    }
                    .buttonStyle(.bordered)
                    Button("关闭") { pickSlot = nil }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func historyGroup(_ k: FileHistory.Kind) -> some View {
        let rows = history.filter { $0.kind == k }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("\(k.rawValue) \(rows.count) 个 / \(FileHistory.human(FileHistory.total(rows)))")
                        .font(.subheadline)
                    Spacer(minLength: 6)
                    Button("删本类") { deleteFiles(rows, what: "已删这一类「\(k.rawValue)」") }
                        .buttonStyle(.bordered)
                }
                ForEach(rows) { it in
                    historyLine(it)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func historyLine(_ it: FileHistory.Item) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(it.name).font(.caption)
                Text(FileHistory.human(it.bytes) + (currentPaths.contains(it.id) ? "　这一格正在用" : ""))
                    .font(.caption2)
                    .foregroundColor(currentPaths.contains(it.id) ? .accentColor : .secondary)
            }
            Spacer(minLength: 6)
            Button("删") { deleteFiles([it], what: "已删 \(it.name)") }
                .buttonStyle(.bordered)
        }
    }

    /// 界面上这些槽现在指着哪些文件（删掉时要一起清引用，清单里也要标出来）。
    private var currentPaths: Set<String> {
        var s = Set<String>()
        for u in [sourceURL, refURL, outputURL, rawTTSURL, videoURL, videoOutURL] {
            if let u = u { s.insert(u.path) }
        }
        return s
    }

    /// 「全部删除」两道：第一次只把按钮改文案、把待确认这件事写进日志，第二次才动 `removeItem`。
    private func wipeAll() {
        guard !history.isEmpty else { return }
        if wipeArmed {
            deleteFiles(history, what: "全部删除")
            return
        }
        wipeArmed = true
        historyNote = "再点一次「全部删除」就真删这 \(history.count) 个"
        VoiceJournal.line("历史文件「全部删除」第一次按下（待第二次确认）")
    }

    private func deleteFiles(_ items: [FileHistory.Item], what: String) {
        let r = FileHistory.deleteAll(items)
        clearReferences(of: items.map { $0.url })
        history = FileHistory.scan()
        wipeArmed = false
        historyNote = what + "：删掉 \(r.deleted) 个、拿回 \(FileHistory.human(r.freed))"
            + (r.failed > 0 ? "／\(r.failed) 个删不掉（逐条原因在日志）" : "")
    }

    /// 删掉的正好是界面上现在指着的那一格 ⇒ 引用一起清掉。
    /// 不清的话「当前：pick_x.wav」还挂着，要等下一次点转换才在读文件那步报找不到，绕一圈。
    private func clearReferences(of urls: [URL]) {
        let paths = Set(urls.map { $0.path })
        if let u = sourceURL, paths.contains(u.path) { sourceURL = nil }
        if let u = refURL, paths.contains(u.path) { refURL = nil }
        if let u = outputURL, paths.contains(u.path) { outputURL = nil }
        if let u = rawTTSURL, paths.contains(u.path) { rawTTSURL = nil }
        if let u = videoURL, paths.contains(u.path) {
            videoURL = nil
            videoProbe = nil      // 体检数跟着片源走：不清的话界面会拿着上一条的秒数说下一条
        }
        if let u = videoOutURL, paths.contains(u.path) { videoOutURL = nil }
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

    // MARK: - 读小说（文本 → 系统 TTS → 现有样本链）

    @ViewBuilder
    private var novelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("读小说（文本 → 系统朗读 → 上面那个样本的音色）").font(.headline)

            voiceRow

            textSource

            HStack(spacing: 12) {
                Button("选文件") {
                    VoiceJournal.line("点「选文件」槽=text")
                    pickSlot = .text
                }
                .buttonStyle(.bordered)
                .disabled(isReading)

                Button("粘贴") {
                    let s = UIPasteboard.general.string ?? ""
                    if s.isEmpty {
                        readNote = "剪贴板里没有文字"
                    } else {
                        novelFileURL = nil        // 粘进来就退回手打模式：两种来源不许混着读
                        novelText = s
                        readNote = "粘进来 \(s.count) 字"
                        VoiceJournal.line("粘进文本 \(s.count) 字")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isReading)

                Button("清空") {
                    novelText = ""; novelFileURL = nil; novelFileText = ""
                    readNote = ""
                    VoiceJournal.line("清空朗读文本")
                }
                .buttonStyle(.bordered)
                .disabled(isReading || novelChars == 0)

                Button(isReading ? "读着…" : "读给我听") { startReading() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isReading || novelChars == 0
                              || isConverting || srcRec.isRecording || refRec.isRecording)
                Spacer()
                Text(estimateLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("音色就用在「样本清单」里点中的那个样本（现在：\(pickedSampleNote)）；没点样本就用 ② 那段参考。嗓音是从手机自带的中文语音里挑，「试听」只外放念一句、不跑链（挑嗓音几十秒就够，别拿整章去试）。实测：系统念中文 ≈4.1 字/秒（≈5.5× 实时），链子 ≈2.5× 实时 ⇒ 6000 字一章约 25 分钟音频、整趟约 12 分钟。念满 120 秒就整片过链子、**转完立刻写盘**，常驻内存只有那一片，所以整章多长都不会撑；上限不再是 30 分钟而变成这台机剩下的盘（两条 wav 每秒共占 64 KB，另留 1 GB 余量），不够会一行话告诉你，不闪退。")
                .font(.caption)
                .foregroundColor(.secondary)

            if isReading || !readStatus.isEmpty {
                Text(readStatus)
                    .font(.caption)
                    .foregroundColor(isReading ? .secondary : .accentColor)
                    .textSelection(.enabled)
            }
            if !readNote.isEmpty {
                Text(readNote).font(.caption).foregroundColor(.orange)
            }

            if let raw = rawTTSURL {
                HStack(spacing: 12) {
                    Button {
                        player.play(url: raw)
                    } label: {
                        Label(player.isPlaying ? "播放中" : "播系统原声",
                              systemImage: player.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(player.isPlaying)
                    Text(raw.lastPathComponent)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// 嗓音一行：只显示当前选中的那个，点开才列全 24 个。
    /// 上一版是 `Picker(...).pickerStyle(.navigationLink)`，真机八次改嗓音八次闪退
    /// （`选嗓音：…` 那行日志之后同一秒就 `ContentView.onAppear`），改成按钮 + 自己铺的清单页。
    @ViewBuilder
    private var voiceRow: some View {
        HStack(spacing: 10) {
            Button { pickSlot = .voice } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("朗读嗓音（点开换，共 \(voiceRows.count) 个可选）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(currentVoiceLabel)
                        .font(.body)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isReading)

            Button("试听") {
                Audition.shared.play(identifier: voiceID.isEmpty ? nil : voiceID)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isReading || isConverting)
        }
    }

    /// 当前嗓音在界面上怎么说。名单里没有（系统换掉了、或换了一台机）要说得出来，
    /// 不能只显示一个空串让他以为没选。
    private var currentVoiceLabel: String {
        if voiceID.isEmpty { return "默认（本机最高档的普通话嗓子）" }
        if let r = voiceRows.first(where: { $0.identifier == voiceID }) { return r.label }
        return "存的这个本机没有 ⇒ 请用「默认」"
    }

    /// 清单页：一行一个嗓音，右边各带一个试听（比嗓音就是要来回切着听，不必每切一个先关页面）。
    /// 点行=选定并收起；试听=当场外放一句，不跑链、不落盘。
    @ViewBuilder
    private var voiceListPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("本机中文语音 \(voiceRows.count) 个（\(rosterCountLine)）")
                    .font(.headline)
                Text("「试听」当场外放念一句，不跑链子；点整行就选定这个并收页面。"
                     + "名单里没有性别标注的那些是系统自带的角色嗓（爷爷／奶奶／小子…），"
                     + "音高往往和正经播报嗓差很多——低、温柔这类只能靠你耳朵在这页比。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                voiceLine(title: "默认（本机最高档的普通话嗓子）", id: "")
                ForEach(voiceRows) { r in
                    voiceLine(title: r.label, id: r.identifier)
                }

                Button("关闭") { pickSlot = nil }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
        .onDisappear { Audition.shared.stop() }
    }

    private var rosterCountLine: String {
        let males = voiceRows.filter { $0.gender == "男" }.count
        let females = voiceRows.filter { $0.gender == "女" }.count
        return "男 \(males)／女 \(females)／未标 \(voiceRows.count - males - females)"
    }

    @ViewBuilder
    private func voiceLine(title: String, id: String) -> some View {
        HStack(spacing: 8) {
            Button { chooseVoice(id) } label: {
                HStack {
                    Text(title)
                        .font(.body)
                    Spacer(minLength: 6)
                    if voiceID == id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)

            Button("试听") {
                Audition.shared.play(identifier: id.isEmpty ? nil : id)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// 选定：写内存状态 + 立刻落 UserDefaults（不靠 onChange），然后收起清单页。
    private func chooseVoice(_ id: String) {
        voiceID = id
        UserDefaults.standard.set(id, forKey: "novelVoiceID")
        VoiceJournal.line("选嗓音：\(id.isEmpty ? "默认" : id)")
        pickSlot = nil
    }

    /// 文本来源：选了文件就显示那张卡——几十万字塞进 TextEditor 会把界面滚出卡顿，
    /// 而且文件模式本来就是「整篇读、不改字」，给个编辑器反而误导。手打/粘贴照旧走编辑器。
    @ViewBuilder
    private var textSource: some View {
        if let f = novelFileURL {
            VStack(alignment: .leading, spacing: 6) {
                Text("文件：\(f.lastPathComponent)／\(novelFileText.count) 字／编码 \(novelFileEnc)")
                    .font(.subheadline)
                Text("开头：" + String(novelFileText.prefix(60).replacingOccurrences(of: "\n", with: " ")))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("改用手动输入") {
                    novelFileURL = nil; novelFileText = ""
                    VoiceJournal.line("退出文件模式，回到手打")
                }
                .buttonStyle(.bordered)
                .disabled(isReading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.5)))
        } else {
            TextEditor(text: $novelText)
                .font(.body)
                .frame(height: 170)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.35)))
                .disabled(isReading)
        }
    }

    private var novelChars: Int {
        novelFileURL != nil ? novelFileText.count
                            : novelText.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    /// 开跑前就把账摊在界面上：字数 → 音频分钟 → 整趟分钟。
    /// 三个系数全是真机量的（念字 4.1 字/秒、合成 5.5× 实时、整链 2.5× 实时），不是估的。
    private var estimateLine: String {
        let n = novelChars
        let secs = Double(n) / 4.1
        let wall = secs * (1.0 / 5.5 + 1.0 / 2.5)
        return String(format: "%d 字 ≈ %.0f 分钟音频 ≈ %.0f 分钟整趟", n, secs / 60, wall / 60)
    }

    /// 选完就地解出来验一遍：读不出字就当场说，别等点「读给我听」才发现选错了文件。
    /// 编码是 `TextFile` 自己试出来的（UTF-8/UTF-16/GB18030/Big5），报回来是为了「字看着不对」
    /// 这种投诉能立刻分清是解错了还是本来就错。
    private func loadNovelFile(_ url: URL) {
        do {
            let got = try TextFile.load(url)
            let text = got.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                readNote = "\(url.lastPathComponent) 读出来是空的（按 \(got.encoding) 解的）"
                VoiceJournal.line("选文本文件 \(url.lastPathComponent) ⇒ 空（\(got.encoding)）")
                return
            }
            novelFileText = text
            novelFileEnc = got.encoding
            novelFileURL = url
            novelText = ""
            readNote = "读了 \(text.count) 字（\(got.encoding)）"
            VoiceJournal.line(String(format: "选文本文件 %@ → %d 字／编码 %@／开头「%@」",
                                     url.lastPathComponent, text.count, got.encoding,
                                     String(text.prefix(24))))
        } catch {
            readNote = "这个文件读不出来：\(error.localizedDescription)"
            VoiceJournal.line("选文本文件失败 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    private var pickedSampleNote: String {
        if let p = samples.first(where: { $0.id == pickedID }) { return "样本「\(p.info.name)」" }
        if refURL != nil { return "② 那段参考" }
        return "还没选"
    }

    private func startReading() {
        guard let modelDir = models.modelDir else { return }
        let fromFile = novelFileURL != nil
        let text = fromFile ? novelFileText : novelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let picked = samples.first { $0.id == pickedID }
        guard picked != nil || refURL != nil else {
            readNote = "先在「样本清单」点一个样本（或让 ② 有段参考音频）——文本这条路没有自转换"
            VoiceJournal.line("点「读给我听」但没选样本/参考")
            return
        }
        isReading = true
        readStatus = "分句、合成中…"
        readNote = ""
        outputURL = nil
        rawTTSURL = nil
        VoiceJournal.line(String(format: "点「读给我听」%d 字（%@）音色=%@ 音高 %+.0f 半音 嗓音=%@",
                                 text.count,
                                 fromFile ? "文件 \(novelFileURL!.lastPathComponent)/\(novelFileEnc)" : "手打",
                                 picked != nil ? "样本「\(picked!.info.name)」" : "现场参考",
                                 semitones,
                                 voiceID.isEmpty ? "默认" : voiceID))
        if engine == nil { engine = VoiceEngine(modelDir: modelDir) }
        let eng = engine!
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let stamp = Int(Date().timeIntervalSince1970)
        let output = docs.appendingPathComponent("novel_\(stamp).wav")
        let raw = docs.appendingPathComponent("tts_raw_\(stamp).wav")
        let t0 = Date()

        Task {
            do {
                let r = try await eng.readNovel(text: text,
                                               sample: picked,
                                               refWav: picked != nil ? nil : refURL,
                                               outputWav: output,
                                               rawTTSWav: raw,
                                               pitchCents: semitones * 100.0,
                                               voiceID: voiceID.isEmpty ? nil : voiceID,
                                               onStage: { txt in
                    DispatchQueue.main.async { readStatus = txt }
                })
                let wall = Date().timeIntervalSince(t0)
                await MainActor.run {
                    outputURL = output
                    rawTTSURL = raw
                    isReading = false
                    history = FileHistory.scan()
                    readStatus = r.tts.line
                    readNote = String(format: "读完：%d 句合成 %.0f s → %d 片转换出 %.0f s，整趟墙钟 %.0f s（合成占 %.0f s）",
                                      r.tts.sentences, r.tts.seconds, r.passes, r.convertedSeconds,
                                      wall, r.tts.wall)
                    VoiceJournal.line("读小说界面收尾：\(readNote)")
                }
            } catch {
                await MainActor.run {
                    isReading = false
                    readStatus = "失败：\(error.localizedDescription)"
                    readNote = "没读成，原因在上面那一行。"
                    history = FileHistory.scan()
                    VoiceJournal.line("读小说失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - ⑤ 视频换声（画面不动，只换音轨）

    /// 六条动作共用的互斥位：任何一条在跑就不许再起点别的（手机上链子一次只吃得起一个）。
    private var busyAnywhere: Bool {
        isConverting || isReading || isVideoing || isMakingSample
            || srcRec.isRecording || refRec.isRecording
    }

    @ViewBuilder
    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("视频换声（画面一个像素不动，只把音轨换成选中样本的音色）").font(.headline)

            HStack(spacing: 12) {
                Button("选视频") {
                    VoiceJournal.line("点「选视频」槽=video")
                    pickSlot = .video
                }
                .buttonStyle(.bordered)
                .disabled(busyAnywhere)

                Button(isVideoing ? "换声中…" : "开始换声") { startVideo() }
                    .buttonStyle(.borderedProminent)
                    .disabled(videoURL == nil || busyAnywhere || (pickedID == nil && refURL == nil))
                Spacer()
                Text(videoEstimateLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let u = videoURL {
                let line = videoProbe?.line ?? "体检数没读到（重选一次）"
                Text("当前：" + u.lastPathComponent + "／" + line)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("空的。点「选视频」从「文件」app 里挑一段。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if pickedID == nil && refURL == nil {
                Text("没选样本、② 也空的 ⇒ 这一格不给按：视频里那个人本来就有的嗓子就是「自转换」，转给自己听没意义。")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Text("音轨解出来进的就是上面 ①②③④ 那条链，和「转换」「读小说」同一套分段规矩（一遍 ≤150 s，切在最小声的一格）；音高那格同样生效。实测单价：链子 ≈2.5× 实时 ⇒ 60 s 视频约 24 s 链子＋几秒回写。画面走**透传**：不解码不重编，时间戳一个数都不改，所以口型不会漂；成片体积 ≈ 输入那条另加每秒 8 KB 的新 AAC。链子的输出比源长 +0.15%（PC 试点量的），所以后面有一步「整条拉回源长」，40 s 以上的片子不拉就会累积漂 0.06 s。上限取盘和内存更紧的一条（中间 wav 每秒共占 72 KB、另留 1 GB 余量，内存那条 ≈33 分钟），不够会开跑之前一行话拒掉，不写一半把盘填满。中间那两份 wav 跑成即删；成品留在 app 目录（「文件」app 的 Voice 里点开就能看），要收进相册就用「导出」。")
                .font(.caption)
                .foregroundColor(.secondary)

            if isVideoing || !videoStatus.isEmpty {
                Text(videoStatus)
                    .font(.caption)
                    .foregroundColor(isVideoing ? .secondary : .accentColor)
                    .textSelection(.enabled)
            }
            if !videoNote.isEmpty {
                Text(videoNote).font(.caption).foregroundColor(.orange)
            }

            if let out = videoOutURL {
                HStack(spacing: 12) {
                    Button {
                        VoiceJournal.line("点「导出成片」 \(out.lastPathComponent)")
                        showVideoShare = true
                    } label: {
                        Label("导出成片", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    Text("放不进界面里，用「导出」存进相册或「文件」")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .sheet(isPresented: $showVideoShare) {
                    ShareSheet(items: [out],
                               onDismiss: { showVideoShare = false },
                               onPresent: {
                        VoiceJournal.line("视频导出面板已弹起（可「存储到“文件”」／存到相册）")
                    })
                }
                Text(out.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// 开跑前把账摊在按钮旁边：音轨多长、链子大概要多久。系数是真机量的，不是估的。
    private var videoEstimateLine: String {
        guard let i = videoProbe, i.audioSecs > 0 else { return "还没选视频" }
        return String(format: "%.0f s 音轨 ≈ %.1f 分钟链子", i.audioSecs, i.audioSecs / 2.5 / 60)
    }

    private func startVideo() {
        guard let modelDir = models.modelDir, let input = videoURL else { return }
        let picked = samples.first { $0.id == pickedID }
        guard picked != nil || refURL != nil else {
            videoNote = "先在「样本清单」点一个样本（或让 ② 有段参考音频）"
            VoiceJournal.line("点「开始换声」但没选样本/参考")
            return
        }
        isVideoing = true
        videoStatus = "读文件头…"
        videoNote = ""
        videoOutURL = nil
        let using: String
        if let p = picked {
            using = "样本「\(p.info.name)」"
        } else {
            using = "现场参考 \(refURL!.lastPathComponent)"
        }
        VoiceJournal.line(String(format: "点「开始换声」片源=%@ 音色=%@ 音高 %+.0f 半音",
                                 input.lastPathComponent, using, semitones))
        if engine == nil { engine = VoiceEngine(modelDir: modelDir) }
        let eng = engine!
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let output = docs.appendingPathComponent("video_\(Int(Date().timeIntervalSince1970)).mp4")
        let t0 = Date()

        Task {
            do {
                let r = try await eng.processVideo(inputVideo: input,
                                                   sample: picked,
                                                   refWav: picked != nil ? nil : refURL,
                                                   outputVideo: output,
                                                   pitchCents: semitones * 100.0,
                                                   onStage: { txt in
                    DispatchQueue.main.async { videoStatus = txt }
                })
                let wall = Date().timeIntervalSince(t0)
                await MainActor.run {
                    videoOutURL = output
                    isVideoing = false
                    history = FileHistory.scan()
                    videoNote = String(format: "换完：%d 片／音轨 %.1f s → 链子 %.1f s → 对齐 %.1f s（倍率 %.5f）｜成片画面 %d 块＋音频 %d 块／%.1f MB｜墙钟 %.0f s",
                                       r.passes, r.sourceSeconds, r.convertedSeconds, r.fitSeconds,
                                       r.fitRate, r.mux.frames, r.mux.audioBlocks,
                                       Double(r.mux.bytes) / 1_048_576, wall)
                    videoStatus = r.mux.note.isEmpty ? "换声完成" : "音轨收尾：" + r.mux.note
                    VoiceJournal.line("视频换声界面收尾：\(videoNote)")
                }
            } catch {
                await MainActor.run {
                    isVideoing = false
                    videoStatus = "失败：\(error.localizedDescription)"
                    videoNote = "没换成，原因在上面那一行。中间那两份 wav 会留在盘上，下一趟开跑先扫掉，也可以在「历史文件」页删。"
                    history = FileHistory.scan()
                    VoiceJournal.line("视频换声失败：\(error.localizedDescription)")
                }
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
                    history = FileHistory.scan()
                }
            } catch {
                await MainActor.run {
                    isConverting = false
                    convertStatus = "失败：\(error.localizedDescription)"
                    history = FileHistory.scan()
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
