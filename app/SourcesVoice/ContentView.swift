import SwiftUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers

/// 哪个槽在选文件。共用一个呈现，源槽和参考槽不再各挂一个 fileImporter。
/// `text` 也走这一个呈现：它选的是 .txt/.md，不是音频，但呈现器只管把文件拿进来，
/// 能不能用由我们自己验（见 `TextFile.load`）。
/// `video` 独用一个：片源在相册里，走 `VideoAlbumPickerHost`，不进这个文件选择器。
enum PickSlot: String, Identifiable {
    case source
    case ref
    case text
    case video
    /// 也借用这一个呈现：嗓音清单页（不是文件选择，见 body 里那个 if）。
    case voice
    /// 同上：历史文件清理页。
    case history
    /// 同上：⑥「和 AI 聊天」整页（局域网连电脑上那个本地模型代理）。
    case chat
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var models = ModelManager()
    @StateObject private var srcRec = AudioEngine()
    @StateObject private var refRec = AudioEngine()
    /// 「配音」那一格自己一支麦克风、自己一台画面泵：和 ①② 那两支互不相干，
    /// 那两支录的是素材，这一支录的是他对着画面念的那一条。
    @StateObject private var voRec = AudioEngine()
    @StateObject private var voPlayer = MutedVideoPlayer()
    @StateObject private var player = PlayController()
    /// 与 ⑥ 共用的链子互斥位：主页面这四条在跑时写 `main`，⑥ 念语音时写 `chat`。
    @StateObject private var chainGate = ChainGate()
    @State private var engine: VoiceEngine?
    @State private var isConverting = false
    @State private var convertStatus = ""
    @State private var outputURL: URL?          // ①「转换」的成品（④ 走 novelOutURL）
    @State private var sendStatus = ""
    @State private var isSending = false
    /// 「发到电脑」那台接收端在哪儿。以前写死在代码里，电脑 IP 一变就必然超时，
    /// 而超时恰恰是最需要看日志的时候 ⇒ 改成能在这台手机上填、填了记住。
    @State private var logEndpoint = VoiceUploader.endpoint
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
    /// 「去掉男声」开关：进链前把块内中位基频低于男声线的那些块清零。存 UserDefaults，
    /// 因为这是整段素材的性质（这条片子有男有女），重开 app 不该再翻一遍页面。
    @State private var dropMale = (UserDefaults.standard.object(forKey: "gateDropMale") as? Bool) ?? false
    /// 男声线画在哪儿（Hz）。`PitchGate.maleHz` 是这块屏幕唯一的出口：试听和真换声读同一个数。
    @State private var maleHz = PitchGate.maleHz
    /// 一条素材的音轨在内存里只存一份，「试听去男声」和「提取台词」共用：
    /// 要听的往往就是要改的那几句。`audioSrcCap` 记下这一份是按多长的上限解的。
    @State private var audioSrc: [Float] = []
    @State private var audioSrcKey = ""
    @State private var audioSrcCap = 0.0
    @State private var audioStatus = ""
    @State private var gateBusy = false
    @State private var gateNote = ""
    @State private var gateHz = ""
    @State private var gateOutURL: URL?
    @State private var showGateShare = false

    /// 「改台词重配」那一格：提取出来的台词（可编辑）、听写状态、重配状态和成片。
    @State private var videoScript = ""
    /// 每行在原片上的起点，和 `videoScript` 的**非空行**一一对应（提台词那一窗第一个字的时刻）。
    /// 他定的口径是「每行钉原起点＋超长截断」⇒ 文本他能改，位置得单独带着走，不能从字里再猜。
    @State private var scriptAnchors: [Double] = []
    @State private var asrBusy = false
    @State private var asrStatus = ""
    @State private var asrNote = ""
    @State private var dubBusy = false
    @State private var dubStatus = ""
    @State private var dubNote = ""
    /// 上一趟逐行摆位的账（起点／念了多少／截了多少／顺延），跑完摊在按钮下面。
    @State private var dubLines = ""
    @State private var dubOutURL: URL?
    @State private var showDubShare = false
    /// 「提取台词」要的整条长度上限。听写按实时喂，所以这条同时也是要等多久：
    /// 15 分钟素材 ⇒ 解音轨几秒 + 听写约 15 分钟。真机嫌慢就把这段剪短，或自己打字。
    static let asrMaxSecs = 900.0
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
    /// ④ 的成品单独一格。以前和 ① 共用 `outputURL` ⇒ 谁后跑谁把上一条的播放键顶掉，
    /// 而那一整块又在 0.1/32 被「视频换声」挤到了页面最底下，两条的播放键一起看不见了。
    @State private var novelOutURL: URL?
    /// 两个 sheet 不能共用一个开关：弹起来是哪一个全看 SwiftUI 的心情（同 `showVideoShare` 那条理由）。
    @State private var showNovelShare = false

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

    // 配音：画面静音从头放，他对着画面自己念；念完那一条录音进链换成选中样本的音色，再装回原画面。
    /// 停下来那一刻的录音。转换用的就是它（重录会另存一条，这里只指最后停下来的那条）。
    @State private var voRecURL: URL?
    /// 录音头上要补的静音＝起录音那一刻画面已经走掉的秒数（`MutedVideoPlayer.now`）。
    @State private var voLead = 0.0
    @State private var voRecNote = ""
    /// 点了「配音」但录音还没起来那一段（等画面归零、等首帧，最长几秒）。
    /// 不立这一位，这几秒里「配音」还能再点一次 ⇒ 两台画面泵叠着放，对时全乱。
    @State private var voArming = false
    @State private var voBusy = false
    @State private var voStatus = ""
    @State private var voNote = ""
    @State private var voOutURL: URL?
    @State private var showVoShare = false

    /// 历史文件清理页：Documents 根目录里留下的源/中间/成品。
    /// `wipeArmed` 是「全部删除」的第一次按下 —— 删的是他的录音，一指点没了找不回来，要连点两次。
    @State private var history: [FileHistory.Item] = []
    @State private var historyNote = ""
    @State private var wipeArmed = false

    var body: some View {
        NavigationView {
            TabView {
                soundTab
                    .tabItem { Label("声音", systemImage: "waveform") }
                videoTab
                    .tabItem { Label("视频", systemImage: "film") }
            }
            .navigationTitle("声音克隆 \(appVersion())")
            // 键盘顶上那条「完成」只挂一次，挂在两个标签的外面：
            // 一个标签挂一份 ⇒ 输入栏上可能并排出现两个「完成」（同导出面板那条理由）。
            .toolbar { keyboardDone }
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
        // 「试听去男声」那一格在两个标签里各铺一份（`paramSection`），所以它的导出面板挂在这儿、只挂一次：
        // 两份各挂一个面板 ⇒ 点「导出」时弹的是哪一份全看 SwiftUI（屏幕外那份弹出来就是点了没反应）。
        .sheet(isPresented: $showGateShare) {
            if let u = gateOutURL {
                ShareSheet(items: [u],
                           onDismiss: { showGateShare = false },
                           onPresent: {
                    VoiceJournal.line("导出面板已弹起（可「存储到“文件”」）")
                })
            } else {
                Text("试听那一条已经不在了：重跑一次「试听去男声」")
                    .padding()
                    .onAppear { showGateShare = false }
            }
        }
        // ⑥ 那一页看不见这边的 @State，所以主页面这四条一开跑就把互斥位写过去
        .onChange(of: localChainBusy) { chainGate.main = localChainBusy }
    }

    /// 链子这一头（① 转换／② 生成样本／④ 读小说／⑤ 视频／⑤ 配音／⑤ 改台词重配）在不在跑。录音不算：那条不载图。
    private var localChainBusy: Bool {
        isConverting || isMakingSample || isReading || isVideoing || dubBusy || voBusy
    }

    /// 收键盘。`TextEditor` 是多行的，回车只会换行、不会收；ScrollView 里点空白也不收
    /// （SwiftUI 没有「点外面收键盘」这一说）⇒ 必须自己给一条出路，否则输入栏一直挂在屏幕上。
    /// 走 UIResponder 链而不是 @FocusState：这一页有四个输入框分散在各自的格子里，
    /// 挨个绑焦点等于把「谁在用键盘」这件事再记一遍，记漏一个就又是一个收不掉的。
    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    /// 键盘顶上那条「完成」：不管焦点在哪个输入框都挂得上，手不用离开键盘就能收。
    @ToolbarContentBuilder
    private var keyboardDone: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("完成") { hideKeyboard() }
        }
    }

    /// 「声音」标签：模型、①② 两个槽、样本清单、旋钮、① 转换、④ 读小说、⑥ 聊天，
    /// 加上下面的历史文件／日志两格（这两格不分标签 —— 模型没下好时留下的录音照样要能删）。
    @ViewBuilder
    private var soundTab: some View {
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
                    chatSection
                }
                // 放在 if 外面：模型没下（或像 0.1/24 那样被误删）时，留下的录音照样要能删。
                historySection
                debugSection
            }
            .padding()
        }
        // 往下拖也能收键盘（⑥ 那一页同一个做法）。光靠它不够：拖不动的时候还得有「完成」。
        .scrollDismissesKeyboard(.interactively)
    }

    /// 「视频」标签：⑤ 视频换声和新的「改台词重配」都在这儿。
    /// 样本清单和那三个旋钮（音高／去男声／男声线）在这里再铺一遍 —— 换声和配音用的就是这两格里的选择，
    /// 让人在两个标签之间来回跳着找「我刚才那条线拖到哪儿了」是找不自在的。
    /// 它们是同一份 `@State`（`semitones`／`dropMale`／`maleHz`／`pickedID`），所以两边永远是一个数。
    @ViewBuilder
    private var videoTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if case .downloaded = models.state {
                    sampleList
                    paramSection
                    if !pickNote.isEmpty {
                        Text(pickNote).font(.caption).foregroundColor(.secondary)
                    }
                    videoSection
                    voiceOverSection
                    dubSection
                } else {
                    Text("模型还没下好：换声和配音都要用它。去「声音」标签第一格点「下载模型」（581 MB）。")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// 一个呈现七种内容：`.chat` 是 ⑥ 那一整页、`.voice` 是自己铺的嗓音清单、`.history` 是自己铺的历史文件清单、
    /// `.video` 是相册选片，剩下那三个槽（①②／文本）还是系统文件选择器。
    /// 分支写在带 `@ViewBuilder` 的函数里，不赌 `fullScreenCover` 那个闭包是不是 ViewBuilder。
    @ViewBuilder
    private func coverPage(_ slot: PickSlot) -> some View {
        if slot == .chat {
            ChatPage(player: player, chain: chainGate, samples: samples, pickedID: $pickedID,
                     synthesize: chatSpeak, onClose: { pickSlot = nil })
        } else if slot == .voice {
            voiceListPage
        } else if slot == .history {
            historyPage
        } else if slot == .video {
            VideoAlbumPickerHost(onPick: { url, original in
                videoURL = adoptVideo(url, from: original)
            }, onCancel: { msg in
                pickNote = "没选成：" + msg
                VoiceJournal.line("相册选视频取消／失败（\(msg)）")
            }, onDismiss: {
                pickSlot = nil
            })
        } else {
            DocumentPickerHost(onPick: { url in
                if slot == .text {
                    loadNovelFile(url)
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
                    .disabled(refURL == nil || isMakingSample || isConverting || chainGate.chat
                              || srcRec.isRecording || refRec.isRecording)
            }
            Text("样本 = 音色向量 + prompt mel，做一次反复用。参考录 6~10 秒连续干净说话最像（1.5 秒 0.64／6 秒 0.75／10.9 秒 0.76；尺：同人 0.93／两人 0.09）。")
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

            Divider()
            Button {
                dropMale.toggle()
                UserDefaults.standard.set(dropMale, forKey: "gateDropMale")
                VoiceJournal.line("「去掉男声」开关 → \(dropMale)")
            } label: {
                Label(dropMale ? "去掉男声（留女声）：开" : "去掉男声（留女声）：关",
                      systemImage: dropMale ? "checkmark.square.fill" : "square")
            }
            .buttonStyle(.bordered)
            .disabled(isConverting || isVideoing)
            Text("一个人说就不用开。逐块量基频，块内有声帧的 F0 中位数低于下面这条线判男声、就地清零（时间轴不动，⑤ 的口型不偏），和换成谁的音色无关。宁可漏男声不误删女声：低沉女声可能被删、压着嗓子的男声可能漏网。")
                .font(.caption)
                .foregroundColor(.secondary)

            // 男声线从 0.1/48 起能在手机上拖了：这条线画在哪儿本来就看素材，在电脑前猜不出来。
            HStack {
                Text(String(format: "男声线 %.0f Hz", maleHz))
                    .frame(width: 112, alignment: .leading)
                Slider(value: $maleHz, in: PitchGate.maleHzRange, step: 5) { editing in
                    if !editing { commitMaleHz() }
                }
                Button("回 120") {
                    maleHz = PitchGate.maleHzDefault
                    commitMaleHz()
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
            .disabled(isConverting || isVideoing)

            Divider()
            HStack(spacing: 12) {
                Button(gateBusy ? "判一下…" : "试听去男声") { runGatePreview() }
                    .buttonStyle(.borderedProminent)
                    .disabled(gateBusy || busyAnywhere || (videoURL == nil && sourceURL == nil))
                Spacer()
                Text(audioSrcKey.isEmpty ? "素材：还没解过（第一次要点几秒）"
                                         : "素材：\(audioSrcKey) 已存着")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text("先在「视频」标签选一段视频（没选就用「声音」标签 ① 那段音频），点这个按钮：只把原声里被判成男声的那几段抹掉，链子一步都不走 ⇒ 第一次解音轨要几秒，之后每拖一次线再点只需 1 秒以内，当场就响。听明白哪一条线刚好把男的摘干净、又没啃到女的，就点「开始换声」（视频标签）或「开始转换」（声音标签），两条用的都是屏幕上这一个数。只取前 300 秒（判定只看局部，和整条跑出来一模一样）。")
                .font(.caption)
                .foregroundColor(.secondary)
            if !audioStatus.isEmpty {
                Text(audioStatus).font(.caption).foregroundColor(.secondary)
            }
            if !gateNote.isEmpty {
                Text(gateNote).font(.caption).foregroundColor(.orange).textSelection(.enabled)
            }
            if !gateHz.isEmpty {
                Text("每块 F0 从小到大（带 * 的是这一刀切掉的）：" + gateHz)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            if let u = gateOutURL {
                playbackSlot(url: u, headline: "试听：抹掉男声之后的原声（没换音色，时间轴和画面对得上）",
                             share: $showGateShare)
            }
        }
    }

    /// 把滑块上那个数落到这台手机上。松手才写（拖的过程中每一格都写太吵），日志里也只在松手时留一行。
    private func commitMaleHz() {
        PitchGate.setMaleHz(maleHz)
        VoiceJournal.line(String(format: "男声线设成 %.0f Hz（试听和真换声都用这一个数）", maleHz))
    }

    /// 一条素材的音轨只解一次，存着给「试听去男声」和「提取台词」共用。
    /// 要的长度比存着的长 ⇒ 重解（听写要整条，试听只要前 300 s）。
    private func audioCache(url: URL, video: Bool, capSecs: Double) async throws -> [Float] {
        let key = (video ? "视频 " : "音频 ") + url.lastPathComponent
        if key == audioSrcKey, capSecs <= audioSrcCap, !audioSrc.isEmpty { return audioSrc }
        audioStatus = "解音轨（第一次，几秒）…"
        let got = try await VoiceEngine.loadAudioSource(url: url, video: video, maxSecs: capSecs)
        audioSrc = got
        audioSrcKey = key
        audioSrcCap = capSecs
        audioStatus = ""
        return got
    }

    /// 拖一次线、点一次、听一次：只跑闸门那一趟（0.2 s），不进链。
    private func runGatePreview() {
        let isVideo = videoURL != nil
        guard let input = isVideo ? videoURL : sourceURL else {
            gateNote = "没素材可判：先在「视频」标签选一段视频，或在 ① 放一段音频"
            return
        }
        let key = (isVideo ? "视频 " : "音频 ") + input.lastPathComponent
        let hz = maleHz
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        // 毫秒：连点两次落在同一秒就会撞名，那样下面那句"删掉上一条"会把刚写好的这条一起删了。
        let out = docs.appendingPathComponent(
            "gate_\(Int(Date().timeIntervalSince1970 * 1000)).wav")
        if let old = gateOutURL, old != out {
            try? FileManager.default.removeItem(at: old)
            gateOutURL = nil
        }
        gateBusy = true
        gateNote = ""
        VoiceJournal.line(String(format: "点「试听去男声」素材=%@ 男声线 %.0f Hz", key, hz))
        Task {
            do {
                let src = try await audioCache(url: input, video: isVideo,
                                               capSecs: VoiceEngine.gatePreviewMaxSecs)
                let rep = try await Task.detached(priority: .userInitiated) {
                    try VoiceEngine.gatePreview(source: src, outWav: out)
                }.value
                await MainActor.run {
                    gateOutURL = out
                    gateBusy = false
                    gateHz = rep.sortedLine
                    gateNote = String(format: "线 %.0f Hz：留 %d 块／清零 %d 块＝%.1f s｜判过的 F0 最高 %.0f／最低 %.0f Hz"
                                      + "｜素材 %@（%.0f s）｜判定 %.2f s",
                                      rep.maleHz, rep.keptPieces, rep.droppedPieces, rep.droppedSecs,
                                      rep.maxHz, rep.minHz, key, rep.sourceSecs, rep.wallSeconds)
                    history = FileHistory.scan()
                    player.play(url: out)
                }
            } catch {
                await MainActor.run {
                    gateBusy = false
                    gateNote = "没判成：\(error.localizedDescription)"
                    VoiceJournal.line("试听去男声失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 「提取台词」：整条音轨喂给系统本机听写，认出来的字进编辑器。
    ///
    /// 每次都盖掉编辑器里现在那一份 —— 改到一半重听会丢字，所以旧那一份先落在日志里（发到你电脑上），
    /// 找回来的路子是日志，不靠界面记着。
    private func runASR() {
        hideKeyboard()
        let isVideo = videoURL != nil
        guard let input = isVideo ? videoURL : sourceURL else {
            asrNote = "没素材可提：先在「视频」标签选一段视频，或在 ① 放一段音频"
            return
        }
        let key = (isVideo ? "视频 " : "音频 ") + input.lastPathComponent
        asrBusy = true
        asrNote = ""
        asrStatus = "准备听写…"
        VoiceJournal.line("点「提取台词」素材=\(key)")
        let oldScript = videoScript
        Task {
            do {
                let src = try await audioCache(url: input, video: isVideo, capSecs: ContentView.asrMaxSecs)
                let r = try await SpeechText.transcribe(samples: src) { txt in
                    DispatchQueue.main.async { asrStatus = txt }
                }
                await MainActor.run {
                    asrBusy = false
                    asrStatus = ""
                    if !oldScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VoiceJournal.line("提台词覆盖了编辑器里原来那份（\(oldScript.count) 字）：\(oldScript)")
                    }
                    videoScript = r.text
                    scriptAnchors = r.lines.map { $0.startSecs }
                    asrNote = String(format: "认出 %d 字／%d 句／源 %.0f s／墙钟 %.0f s（%@）｜下面直接改，改完点「按新词配音并回写」",
                                     r.chars, r.lines.count, r.sourceSecs, r.wallSeconds,
                                     r.onDevice ? "本机识别" : "这一趟走了需要联网那头")
                    saveScript(scriptKey(input, isVideo))
                }
            } catch {
                await MainActor.run {
                    asrBusy = false
                    asrStatus = ""
                    asrNote = "没提出来：\(error.localizedDescription)"
                    VoiceJournal.line("提取台词失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 稿子按素材名存在这台手机上：解说什么中途退出 app 不用重听一遍（听写是按实时的）。
    /// 这个键就是存进 `UserDefaults` 的那一个键，三处（存、取、配音前再存一次）必须同一个算法。
    private func scriptKey(_ url: URL, _ video: Bool) -> String {
        "dubScript:" + (video ? "v" : "a") + url.lastPathComponent
    }

    private func saveScript(_ key: String) {
        UserDefaults.standard.set(videoScript, forKey: key)
        // 锚点跟着稿子一起存：只存文本的话，退出再进来位置就全丢了 ⇒ 又变成从 0 连着念。
        UserDefaults.standard.set(scriptAnchors.map { String(format: "%.3f", $0) }.joined(separator: ","),
                                  forKey: key + ":t")
    }

    private func loadScript(_ key: String) {
        videoScript = UserDefaults.standard.string(forKey: key) ?? ""
        let raw = UserDefaults.standard.string(forKey: key + ":t") ?? ""
        scriptAnchors = raw.split(separator: ",").compactMap { Double($0) }
    }

    /// 「按新词配音并回写」：改过的字 → ④ 那条（系统朗读 → ②③④）→ 装回原来那条画面。
    private func startDub() {
        hideKeyboard()
        guard let input = videoURL else {
            dubNote = "这一条要选视频（画面照原样透传，只把声音换成念新词的那一份）"
            return
        }
        let picked = samples.first { $0.id == pickedID }
        guard picked != nil || refURL != nil else {
            dubNote = "先在样本清单点一个样本（或让 ② 有段参考音频）"
            return
        }
        let text = videoScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            dubNote = "稿子是空的：先点「提取台词」，或者自己打几句"
            return
        }
        guard let modelDir = models.modelDir else {
            dubNote = "模型还没下好（去「声音」标签第一格）"
            return
        }
        let using = picked != nil ? "样本「\(picked!.info.name)」" : "现场参考 \(refURL!.lastPathComponent)"
        // 一行一行取锚。**空行不占号**（提台词那边空窗也不占行）：占号的话删一个空行就把后面全错开。
        var dub: [VoiceEngine.DubLine] = []
        var k = 0
        var noAnchor = 0
        var prevEnd = 0.0
        for raw in videoScript.components(separatedBy: .newlines) {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            let a: Double
            if k < scriptAnchors.count {
                a = scriptAnchors[k]
            } else {
                // 他自己新加的行没有原起点 ⇒ 接在上一行大概念完之后（4.1 字/秒是 PC 实测那个数）
                a = prevEnd
                noAnchor += 1
            }
            dub.append(VoiceEngine.DubLine(startSecs: a, text: s))
            prevEnd = a + Double(s.count) / 4.1 + 0.3
            k += 1
        }
        dubBusy = true
        dubNote = ""
        dubLines = ""
        dubStatus = "念稿…"
        dubOutURL = nil
        VoiceJournal.line(String(format: "点「按新词配音并回写」片源=%@ 音色=%@ 稿子 %d 字／%d 行（%d 行没原起点，接在上一行后面）／音高 %+.0f 半音",
                                 input.lastPathComponent, using, text.count, dub.count, noAnchor, semitones))
        if engine == nil { engine = VoiceEngine(modelDir: modelDir) }
        let eng = engine!
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let output = docs.appendingPathComponent("dub_\(Int(Date().timeIntervalSince1970)).mp4")
        let key = scriptKey(input, true)
        let t0 = Date()
        saveScript(key)
        Task {
            do {
                let r = try await eng.dubVideo(inputVideo: input,
                                               lines: dub,
                                               sample: picked,
                                               refWav: picked != nil ? nil : refURL,
                                               outputVideo: output,
                                               pitchCents: semitones * 100.0,
                                               voiceID: voiceID.isEmpty ? nil : voiceID,
                                               onStage: { txt in
                    DispatchQueue.main.async { dubStatus = txt }
                })
                let wall = Date().timeIntervalSince(t0)
                await MainActor.run {
                    dubOutURL = r.outURL
                    dubBusy = false
                    history = FileHistory.scan()
                    let nPush = r.lines.filter { $0.pushed }.count
                    let nCut = r.lines.filter { $0.cutSecs > 0.05 || $0.stopped }.count
                    dubNote = String(format: "%d 字／%d 行 → 链子 %.0f s／画面到 %.0f s｜钉住 %d 行／顺延 %d 行／截断 %d 行"
                                      + "｜补静音 %.0f s／超出丢掉 %.0f s｜成片 %@（口径 \(r.mux.cfgName)／%.1f MB／墙钟 %.0f s）",
                                      r.textChars, r.lines.count, r.dubSecs, r.picEnd,
                                      r.lines.count - nPush, nPush, nCut,
                                      r.padSecs, r.overSecs, r.outURL.lastPathComponent,
                                      Double(r.mux.bytes) / 1_048_576, wall)
                    dubLines = r.lines.map { $0.line }.joined(separator: "\n")
                    dubStatus = "重配完成"
                    VoiceJournal.line("重配界面收尾：\(dubNote)")
                }
            } catch {
                await MainActor.run {
                    dubBusy = false
                    dubStatus = "失败：\(error.localizedDescription)"
                    dubNote = "没配成，原因在上面那一行。中间那两份 wav 会留在盘上，下一趟开跑先扫掉，也可以在「历史文件」页删。"
                    history = FileHistory.scan()
                    VoiceJournal.line("重配失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 开跑前把账摊在按钮旁边：画面多长、稿子几行几字、其中几行有原起点可钉。
    private var dubEstimateLine: String {
        guard let i = videoProbe else { return "还没选视频" }
        let pic = i.videoStart + i.videoSecs
        let rows = videoScript.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let n = rows.reduce(0) { $0 + $1.count }
        let pinned = min(rows.count, scriptAnchors.count)
        return String(format: "画面 %.0f s｜稿子 %d 行 %d 字 ≈ 念 %.0f s｜%d 行钉原起点",
                      pic, rows.count, n, Double(n) / 4.1, pinned)
    }

    @ViewBuilder
    private var dubSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("改台词重配（把视频里那个人说的话改成别的，每句话还在原来的位置，口型不管）").font(.headline)

            HStack(spacing: 12) {
                Button(asrBusy ? "听写中…" : "提取台词") { runASR() }
                    .buttonStyle(.bordered)
                    .disabled(asrBusy || busyAnywhere || (videoURL == nil && sourceURL == nil))
                Button("清空稿子") {
                    videoScript = ""
                    scriptAnchors = []
                    dubLines = ""
                }
                    .buttonStyle(.bordered)
                    .font(.caption)
                Spacer()
                Text(dubEstimateLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("「提取台词」走系统自带的本机听写（不下载任何模型，包一个字节都不长）：把音轨一段一段喂给它认字，按实时速度喂 ⇒ 5 分钟素材要等 5 分钟左右（喂快了会掉字，0.1/53 起不再赶）。认出来的字不一定全对（听写本来就有别字、专有名词容易错），所以下面直接改成你要说的。听写包没装／不给权限会一行话说明去哪儿开；实在不行自己打字也一样能配音。")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("一行 = 原来的一句话，行号就是它在原片上的位置：配音时每句钉回自己原来的起点（听写给了每个词的时刻，按句读和停顿切句），句与句之间没说话的空档填静音。所以不会从片头一路念到底，也不会一句早于嘴型好几秒。")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("某句改长了 ⇒ 念到下一句原来的起点为止就截断（宁可少念几个字，也不让后面每句话整体挪位）；改短了 ⇒ 后面留静音，下一句还在原处。空行不念、也不占行号。要注意：删掉整行会让后面的行号和锚点错开一位，不想念那一行就把字删空、留着那个空行。自己新加的行没有原起点，接在上一行后面。")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("改完点「按新词配音并回写」：字走 ④ 那条（系统朗读 → ②③④ 换成选中样本的音色），再装回原来那条画面（画面一个像素不动、透传）。口型不再对（字数变了，这一条你明确不要）。音色、音高、去男声用的还是上面那几格。")
                .font(.caption)
                .foregroundColor(.secondary)
            if !asrStatus.isEmpty {
                Text(asrStatus).font(.caption).foregroundColor(.secondary)
            }
            if !asrNote.isEmpty {
                Text(asrNote).font(.caption).foregroundColor(.orange).textSelection(.enabled)
            }

            // 编辑器：稿子在这儿改。切到别的标签不丢（同一个 @State），退出 app 靠下面那条存回这台手机。
            TextEditor(text: $videoScript)
                .frame(minHeight: 220)
                .font(.body)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4)))

            HStack(spacing: 12) {
                Button(dubBusy ? "重配中…" : "按新词配音并回写") { startDub() }
                    .buttonStyle(.borderedProminent)
                    .disabled(dubBusy || busyAnywhere || videoURL == nil
                              || videoScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (pickedID == nil && refURL == nil)
                              || models.modelDir == nil)
                Spacer()
                Text(videoURL == nil ? "这一条必须选视频" : "稿子改好就能点")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text("稿子按素材名记在这台手机上：中途退出再进来还在（切标签本来就不丢）。")
                .font(.caption2)
                .foregroundColor(.secondary)
            if !dubStatus.isEmpty {
                Text(dubStatus)
                    .font(.caption)
                    .foregroundColor(dubBusy ? .secondary : .accentColor)
                    .textSelection(.enabled)
            }
            if !dubNote.isEmpty {
                Text(dubNote).font(.caption).foregroundColor(.orange).textSelection(.enabled)
            }
            if !dubLines.isEmpty {
                Text("每行摆到哪儿了（截掉＝改长了没念完的那一截）：")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(dubLines)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            if let out = dubOutURL {
                HStack(spacing: 12) {
                    Button {
                        VoiceJournal.line("点「导出重配成片」 \(out.lastPathComponent)")
                        showDubShare = true
                    } label: {
                        Label("导出成片", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    Text("放不进界面里，用「导出」存进相册或「文件」")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .sheet(isPresented: $showDubShare) {
                    ShareSheet(items: [out],
                               onDismiss: { showDubShare = false },
                               onPresent: {
                        VoiceJournal.line("重配导出面板已弹起")
                    })
                }
                Text(out.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
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
        let anyRecording = srcRec.isRecording || refRec.isRecording || voRec.isRecording
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

    /// 认领相册选片器已经拷进 Documents 的那一份。拷贝在选择器回调里当场就做完了
    /// （系统给的临时文件一返回就被收走），这里只剩体检和记账。
    /// 就地读一次文件头（`VideoClip.probe`：只读头、不解码，几百毫秒），选错了东西当场就知道，不用等开跑。
    private func adoptVideo(_ dest: URL, from original: String) -> URL? {
        let info = VideoClip.probe(dest)
        videoProbe = info
        videoNote = ""
        history = FileHistory.scan()
        guard info.bytes > 0 else {
            pickNote = "这一条读不出内容：" + dest.lastPathComponent + "／" + info.line
            VoiceJournal.line("相册视频 \(original) → \(dest.lastPathComponent)：\(info.line)（当没选到）")
            return nil
        }
        // 换片就把稿子换成这一片自己那份：手上那一先按上一个片名存回去（改到一半换片不该丢），
        // 这一片以前听过写过的照原样拿回来 —— 不然每次选同一段都要重听一遍写。
        if let prev = videoURL { saveScript(scriptKey(prev, true)) }
        loadScript(scriptKey(dest, true))
        // 配音那一格跟着片源走：画面换一条，上一条的录音就不能再拿去转换了（时间轴不是同一条）。
        voPlayer.load(dest, picSecs: info.videoStart + info.videoSecs)
        voRecURL = nil
        voLead = 0
        voRecNote = ""
        voOutURL = nil
        voNote = ""
        voStatus = ""
        if !videoScript.isEmpty {
            VoiceJournal.line("这份稿子从这台手机上取回（\(videoScript.count) 字／\(scriptAnchors.count) 个起点）键=\(scriptKey(dest, true))")
        }
        pickNote = "已从相册拿进来：" + dest.lastPathComponent + "（原来叫 \(original)）／" + info.line
        VoiceJournal.line("相册视频 \(original) → \(dest.lastPathComponent)：\(info.line)")
        return dest
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
            Text("从「文件」或相册选进来的音频和视频、录的、系统原声、转换成品、换了声的成片都一直留在 app 目录里，播完不会自动删 ⇒ 「文件」app 里直接翻得到。这页逐条删、整类删、一键清空。模型目录（581 MB）、voice_log.txt、样本清单不在这页里，也删不到。")
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
        for u in [sourceURL, refURL, outputURL, novelOutURL, rawTTSURL, videoURL, videoOutURL,
                  voRecURL, voOutURL] {
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
        if let u = novelOutURL, paths.contains(u.path) { novelOutURL = nil }
        if let u = rawTTSURL, paths.contains(u.path) { rawTTSURL = nil }
        if let u = videoURL, paths.contains(u.path) {
            videoURL = nil
            videoProbe = nil      // 体检数跟着片源走：不清的话界面会拿着上一条的秒数说下一条
            voPlayer.stop()
            voRecURL = nil
            voOutURL = nil
        }
        if let u = videoOutURL, paths.contains(u.path) { videoOutURL = nil }
        if let u = voRecURL, paths.contains(u.path) { voRecURL = nil }
        if let u = voOutURL, paths.contains(u.path) { voOutURL = nil }
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
            .disabled(!canConvert || isConverting || chainGate.chat)

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
            if let url = outputURL {
                playbackSection(url: url, headline: "转换结果", share: $showShare)
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
                    .disabled(isReading || novelChars == 0 || chainGate.chat
                              || isConverting || srcRec.isRecording || refRec.isRecording)
                Spacer()
                Text(estimateLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("音色用「样本清单」里点中的那个，没点就用 ② 那段参考；嗓音从手机自带的中文语音里挑，「试听」只外放念一句、不跑链。实测链子 ≈2.5× 实时 ⇒ 6000 字一章约 12 分钟。整片过链、转完立刻写盘，所以章多长都不撑内存，上限只剩这台机剩下的盘。")
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
                        Label(isMine(raw) && player.isPlaying ? "播放中" : "播系统原声",
                              systemImage: isMine(raw) && player.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isMine(raw) && player.isPlaying)
                    Text(raw.lastPathComponent)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if let url = novelOutURL {
                playbackSection(url: url, headline: "朗读结果", share: $showNovelShare)
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
        novelOutURL = nil
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
                    novelOutURL = output
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
    /// ⑥ 在念回答也算一条 —— 它用的是同一套图。
    private var busyAnywhere: Bool {
        isConverting || isReading || isVideoing || isMakingSample || chainGate.chat
            || srcRec.isRecording || refRec.isRecording || voRec.isRecording
            || gateBusy || asrBusy || dubBusy || voBusy || voArming
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
                Text("空的。点「选视频」从相册里挑一段。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if pickedID == nil && refURL == nil {
                Text("没选样本、② 也空的 ⇒ 这一格不给按：视频里那个人本来就有的嗓子就是「自转换」，转给自己听没意义。")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Text("音轨解出来走的就是上面 ①②③④ 那条链，音高那格同样生效。实测单价 ≈2.5× 实时 ⇒ 60 秒视频约 24 秒链子＋几秒回写。画面走透传（不解码不重编、时间戳一个数都不改），所以口型不漂；成片体积 ≈ 输入那条另加音频。开跑前先按盘和内存（≈33 分钟）算一遍，不够就一行话拒掉。")
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
        guard let i = videoProbe else { return "还没选视频" }
        guard i.audioSecs > 0 else { return "这一条没有音轨 ⇒ 没东西可换，重选一段有声音的" }
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
        VoiceJournal.line(String(format: "点「开始换声」片源=%@ 音色=%@ 音高 %+.0f 半音／去掉男声=%@（线 %.0f Hz）",
                                 input.lastPathComponent, using, semitones,
                                 dropMale ? "开" : "关", PitchGate.maleHz))
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
                                                   dropMale: dropMale,
                                                   onStage: { txt in
                    DispatchQueue.main.async { videoStatus = txt }
                })
                let wall = Date().timeIntervalSince(t0)
                await MainActor.run {
                    videoOutURL = r.outURL
                    isVideoing = false
                    history = FileHistory.scan()
                    videoNote = String(format: "换完：%d 片／音轨 %.1f s → 链子 %.1f s → 对齐 %.1f s（倍率 %.5f）"
                                       + "｜成片 \(r.mux.cfgName)：画面 %d 块＋音频 %d 块／%.1f MB／墙钟 %.0f s／去男声 %.1f s",
                                       r.passes, r.sourceSeconds, r.convertedSeconds, r.fitSeconds,
                                       r.fitRate, r.mux.frames, r.mux.audioBlocks,
                                       Double(r.mux.bytes) / 1_048_576, wall, r.gateSeconds)
                    videoStatus = "换声完成（\(r.mux.cfgName)）｜音轨 \(r.mux.note)"
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

    // MARK: - ⑤b 配音（对着静音画面自己念 → 换声 → 装回原画面）

    @ViewBuilder
    private var voiceOverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("配音（画面静音播放，你对着画面念；念完换成选中样本的音色）").font(.headline)

            HStack(spacing: 12) {
                Button(voRec.isRecording ? "录音中…" : "配音") { startVoiceOver() }
                    .buttonStyle(.borderedProminent)
                    .disabled(videoURL == nil || voArming || busyAnywhere)
                Button("停止") { stopVoiceOver() }
                    .buttonStyle(.bordered)
                    .disabled(!voRec.isRecording)
                Button(voBusy ? "转换中…" : "转换") { convertVoiceOver() }
                    .buttonStyle(.borderedProminent)
                    .disabled(voRecURL == nil || videoURL == nil || busyAnywhere
                              || (pickedID == nil && refURL == nil))
                Spacer()
            }

            if videoURL != nil {
                MutedVideoView(player: voPlayer.player)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 14) {
                    Text(String(format: "画面 %.1f s", voPlayer.seconds))
                    if voRec.isRecording {
                        Text(String(format: "已录 %.1f s", max(0, voPlayer.seconds - voLead)))
                            .foregroundColor(.red)
                    }
                    if !voPlayer.status.isEmpty {
                        Text(voPlayer.status)
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundColor(.secondary)
            } else {
                Text("先在上面「选视频」挑一段，画面就铺在这儿（不出声）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("点「配音」：画面从头开始放、一个声音都不出（片子里原来那条音轨整个不要），麦克风同时开始录。你看着画面里那个人的嘴，用自己的话跟着念 —— 口型由你自己对，程序不再猜时间。念完点「停止」（画面放完也会自己停）。")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("画面先起、录音跟着起，中间差的那零点几秒会自动补在录音头上（日志里「配音对时」那行就是它），所以录音和画面是同一条时间轴。再点「转换」：录音走上面 ①②③④ 那条链换成选中样本的音色，音高那格同样生效，然后装回原来那条画面（一个像素不动）。这一条不做整条拉伸 —— 你自己对好的位置不能再被推走。")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("录音比画面长 ⇒ 多出来的尾巴丢掉；比画面短 ⇒ 结尾补静音。念错了就「停止」再「配音」重录一遍：重录另存一条，转换用的是最后停下来的那条，旧的在「历史文件」页删。麦克风有没有真录到声音，日志里「录音实测」那行写着峰值和 rms（基本全零就是宿主没把麦克风给过来）。")
                .font(.caption)
                .foregroundColor(.secondary)

            if let u = voRecURL {
                HStack(spacing: 12) {
                    Button(isMine(u) && player.isPlaying ? "停止试听" : "试听配音") {
                        if isMine(u) && player.isPlaying { player.stop() } else { player.play(url: u) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(voRec.isRecording || voBusy)
                    Text(voRecNote)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            if pickedID == nil && refURL == nil {
                Text("没选样本、② 也空的 ⇒ 「转换」不给按：换成谁的音色得先有个目标。")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            if voBusy || !voStatus.isEmpty {
                Text(voStatus)
                    .font(.caption)
                    .foregroundColor(voBusy ? .secondary : .accentColor)
                    .textSelection(.enabled)
            }
            if !voNote.isEmpty {
                Text(voNote).font(.caption).foregroundColor(.orange).textSelection(.enabled)
            }

            if let out = voOutURL {
                HStack(spacing: 12) {
                    Button {
                        VoiceJournal.line("点「导出配音成片」 \(out.lastPathComponent)")
                        showVoShare = true
                    } label: {
                        Label("导出成片", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    Text("放不进界面里，用「导出」存进相册或「文件」")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .sheet(isPresented: $showVoShare) {
                    ShareSheet(items: [out],
                               onDismiss: { showVoShare = false },
                               onPresent: {
                        VoiceJournal.line("配音导出面板已弹起（可「存储到“文件”」／存到相册）")
                    })
                }
                Text(out.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// 点「配音」：画面从头静音放，麦克风跟着起。
    ///
    /// 顺序是**画面先、录音后**，而且等画面真在走了才起录音。反过来（录音先起）那一段差值
    /// 只能拿墙钟猜，而会话激活和首帧解码各花多久在这台机上都没准数；画面自己的时钟是唯一
    /// 的准绳 ⇒ 起录音那一刻它走到哪儿，录音头上就补多少静音（`voLead`）。
    @MainActor
    private func startVoiceOver() {
        hideKeyboard()
        guard !voArming, !voRec.isRecording else { return }
        guard let input = videoURL else {
            voNote = "先在上面「选视频」挑一段"
            return
        }
        player.stop()                       // 试听那条先把音频会话让出来
        if !voPlayer.holds(input) {
            let i = videoProbe ?? VideoClip.probe(input)
            voPlayer.load(input, picSecs: i.videoStart + i.videoSecs)
        }
        voPlayer.onEnd = { stopVoiceOver() }
        voArming = true
        voNote = ""
        voStatus = ""
        voRecURL = nil
        voRecNote = ""
        voOutURL = nil
        VoiceJournal.line("点「配音」片源=\(input.lastPathComponent)（画面静音从头放，麦克风跟着起）")
        Task { @MainActor in
            await voPlayer.playFromStart()
            // 片子太短的话，等画面起这几秒里它可能已经放完了 ⇒ 别对着一张停住的画面录。
            guard voPlayer.isPlaying else {
                voArming = false
                voNote = "画面已经放完了（这一段太短，或者起播等太久）：再点一次「配音」。"
                VoiceJournal.line("配音：画面在起录音之前就放完了，这一趟不录")
                return
            }
            voRec.startRecording()
            voLead = voPlayer.now
            voArming = false
            if voRec.isRecording {
                voRecNote = String(format: "头上补静音 %.2f s（起录音时画面已走这么多）", voLead)
                VoiceJournal.line(String(format: "配音对时：起录音那一刻画面在 %.3f s ⇒ 录音头上补这么多静音", voLead))
            } else {
                voPlayer.stop()
                voLead = 0
                voNote = "麦克风没起来（日志里「录音启动失败」那行有原因）。装机在 LiveContainer 里，麦克风权限归宿主：去 设置 → LiveContainer 看麦克风给没给。"
                VoiceJournal.line("配音：录音没起来，画面已停")
            }
        }
    }

    /// 点「停止」（画面放完也走这儿）：两台泵一起停，录音落到 `voRecURL`，转换用的就是它。
    @MainActor
    private func stopVoiceOver() {
        let wasRecording = voRec.isRecording
        voRec.stopRecording()
        voPlayer.stop()
        guard wasRecording, let u = voRec.recordedURL else { return }
        voRecURL = u
        history = FileHistory.scan()
        let secs = probeSeconds(u)
        voRecNote = String(format: "%@／%.1f s／头上补静音 %.2f s", u.lastPathComponent, secs, voLead)
        VoiceJournal.line(String(format: "配音停下来：录音 %@ %.2f s ＋ 补头 %.3f s ＝ %.2f s（画面到 %.1f s）",
                                 u.lastPathComponent, secs, voLead, secs + voLead,
                                 (videoProbe?.videoStart ?? 0) + (videoProbe?.videoSecs ?? 0)))
        if secs < 0.3 {
            voNote = "这一条不到 0.3 秒，太短了：重录一遍。"
        }
    }

    /// 一条 wav 有多长（只读文件头，不解码）。读不出来就是 0，界面上照实显示。
    private func probeSeconds(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    /// 点「转换」：录的那一条 → 选中样本那条链 → 装回原来那条画面。
    @MainActor
    private func convertVoiceOver() {
        hideKeyboard()
        guard let input = videoURL, let rec = voRecURL else {
            voNote = "先「配音」录一段，再点「转换」"
            return
        }
        let picked = samples.first { $0.id == pickedID }
        guard picked != nil || refURL != nil else {
            voNote = "先在样本清单点一个样本（或让 ② 有段参考音频）"
            return
        }
        guard let modelDir = models.modelDir else {
            voNote = "模型还没下好（去「声音」标签第一格）"
            return
        }
        player.stop()
        voBusy = true
        voStatus = "读录音…"
        voNote = ""
        voOutURL = nil
        let using = picked != nil ? "样本「\(picked!.info.name)」" : "现场参考 \(refURL!.lastPathComponent)"
        VoiceJournal.line(String(format: "点「配音转换」片源=%@ 录音=%@ 补头 %.3f s 音色=%@ 音高 %+.0f 半音",
                                 input.lastPathComponent, rec.lastPathComponent, voLead, using, semitones))
        if engine == nil { engine = VoiceEngine(modelDir: modelDir) }
        let eng = engine!
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        // 前缀照 ⑤ 那套（video_）：中间那两份 wav 崩在半路时，下一趟开跑的 sweepVideoTemps 认得出来，
        // 「历史文件」页也归在「视频（成品与中间）」那一格。
        let output = docs.appendingPathComponent("video_\(Int(Date().timeIntervalSince1970))_vo.mp4")
        let lead = voLead
        let t0 = Date()
        Task { @MainActor in
            do {
                let r = try await eng.voiceOverVideo(inputVideo: input,
                                                     recordedWav: rec,
                                                     leadSecs: lead,
                                                     sample: picked,
                                                     refWav: picked != nil ? nil : refURL,
                                                     outputVideo: output,
                                                     pitchCents: semitones * 100.0,
                                                     onStage: { txt in
                    DispatchQueue.main.async { voStatus = txt }
                })
                let wall = Date().timeIntervalSince(t0)
                voOutURL = r.outURL
                voBusy = false
                history = FileHistory.scan()
                voNote = String(format: "配完：录音 %.1f s＋补头 %.2f s → 链子 %.1f s（%d 片，不拉伸）／画面到 %.1f s"
                                  + "｜补静音 %.1f s／超出丢掉 %.1f s｜成片 %@（口径 \(r.mux.cfgName)／%.1f MB／墙钟 %.0f s）",
                                  r.recordedSeconds, r.leadSeconds, r.convertedSeconds, r.passes, r.picEnd,
                                  r.padSecs, r.overSecs, r.outURL.lastPathComponent,
                                  Double(r.mux.bytes) / 1_048_576, wall)
                voStatus = "配音完成（\(r.mux.cfgName)）｜音轨 \(r.mux.note)"
                VoiceJournal.line("配音界面收尾：\(voNote)")
            } catch {
                voBusy = false
                voStatus = "失败：\(error.localizedDescription)"
                voNote = "没配成，原因在上面那一行。中间那份 wav 会留在盘上，下一趟开跑先扫掉，也可以在「历史文件」页删。"
                history = FileHistory.scan()
                VoiceJournal.line("配音转换失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - ⑥ 和 AI 聊天（局域网连电脑上那个本地模型代理）

    @ViewBuilder
    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("和 AI 聊天（打字问它，回答用选中样本的音色念出来）").font(.headline)

            HStack(spacing: 12) {
                Button("打开聊天页") {
                    VoiceJournal.line("点「打开聊天页」槽=chat")
                    pickSlot = .chat
                }
                .buttonStyle(.borderedProminent)
                // 念到一半把页面关掉、又开一份新的：两份 ChatPage 会各写各的 chat_feed.json，
                // 后写的那份把前一份整段盖掉 ⇒ 正在念的时候不给再开。
                .disabled(chainGate.chat)
                Spacer()
                Text(chainGate.chat ? "正在念上一条回答…" : chatServerLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("问话走局域网到电脑上那个「AI Local Model Manager」代理（它再转给本机 llama-server）：手机不装语言模型，也不往云上发一个字节。页面和电脑上那个聊天页一样，多的只有「音色」和「语音回复」；念回答走的就是 ④ 那条链，所以 ⑥ 在念时上面四条不给按，反过来也一样。")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("先决条件：手机和电脑在同一个局域网，电脑上那个代理起着（start.bat，端口 8000），聊天页第一行把地址填成 http://<电脑IP>:8000 再点「测试」。第一次连会问「允许访问本地网络吗」，点允许；不让就去 设置 → 隐私与安全性 → 本地网络 里把 LiveContainer 打开。地址、模型、音色、语音回复都记在这台手机上，下次不用重填。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var chatServerLine: String {
        let s = UserDefaults.standard.string(forKey: "aiServerURL") ?? ""
        return s.isEmpty ? "电脑地址还没填" : ChatNet.normalized(s)
    }

    /// ⑥ 的「念出来」：和 ④ 同一条链，只是成品叫 chat_，中间那份系统原声跑成即删
    /// （④ 留着它是为了对着听噪音，⑥ 没有第二个入口会用到）。
    @MainActor
    private func chatSpeak(_ text: String, _ sample: SampleStore.Sample?,
                           _ onStage: @escaping (String) -> Void) async throws -> URL {
        guard let modelDir = models.modelDir else {
            throw ChatNet.Failure(text: "模型还没下好（回主页面看第一格的状态）")
        }
        guard let sample = sample else {
            throw ChatNet.Failure(text: "没挑音色：文本这条路没有自转换")
        }
        if engine == nil { engine = VoiceEngine(modelDir: modelDir) }
        let eng = engine!
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let stamp = Int(Date().timeIntervalSince1970)
        let output = docs.appendingPathComponent("chat_\(stamp).wav")
        let raw = docs.appendingPathComponent("chat_raw_\(stamp).wav")
        let voice = voiceID.isEmpty ? nil : voiceID
        let t0 = Date()
        VoiceJournal.line("聊天念出来开跑：\(text.count) 字／音色=样本「\(sample.info.name)」"
                          + "／音高 \(String(format: "%+.0f", semitones)) 半音／嗓音 \(voice ?? "默认")")
        let r = try await eng.readNovel(text: text,
                                       sample: sample,
                                       refWav: nil,
                                       outputWav: output,
                                       rawTTSWav: raw,
                                       pitchCents: semitones * 100.0,
                                       voiceID: voice,
                                       onStage: onStage)
        try? FileManager.default.removeItem(at: raw)
        history = FileHistory.scan()
        VoiceJournal.line(String(format: "聊天念出来完成：%d 句合成 %.0f s → %d 片转换出 %.0f s，墙钟 %.0f s → %@",
                                 r.tts.sentences, r.tts.seconds, r.passes, r.convertedSeconds,
                                 Date().timeIntervalSince(t0), output.lastPathComponent))
        return output
    }

    /// 一条成品wav的四件套：语速 / 播放 / 停止 / 导出。①「转换」和 ④「读小说」各挂一份在自己的格子里，
    /// 共用一个 PlayController，所以「播放中」只点亮正在响的那一行。
    @ViewBuilder
    private func playbackSection(url: URL, headline: String, share: Binding<Bool>) -> some View {
        playbackBody(url: url, headline: headline, share: share)
            .sheet(isPresented: share) {
                // LiveContainer 里 UIActivityViewController 没实测过；起不来就是这一片空白，
                // 日志里那句「导出面板已弹起」不出现即是证据，兜底是路径本身就在屏幕上。
                ShareSheet(items: [url],
                           onDismiss: { share.wrappedValue = false },
                           onPresent: {
                    VoiceJournal.line("导出面板已弹起（可「存储到“文件”」）")
                })
            }
    }

    /// 同一份四件套，但**不挂**导出面板：面板挂在页面顶层只挂一次（见 body 里那条）。
    /// 理由是 0.1/50 的分标签：「试听去男声」那一格现在两个标签各铺一份，
    /// 两份各自挂 `.sheet($showGateShare)` ⇒ 一点「导出」两个呈现器同时被置位，
    /// 弹出来的可能是屏幕外那一份（TabView 不在屏幕上的那一页照样在视图树里）⇒ 点了没反应。
    @ViewBuilder
    private func playbackSlot(url: URL, headline: String, share: Binding<Bool>) -> some View {
        playbackBody(url: url, headline: headline, share: share)
    }

    @ViewBuilder
    private func playbackBody(url: URL, headline: String, share: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(headline)
                .font(.headline)

            // 语速这一档苹果自己的播放控件没给（AVAudioPlayer 那个 rate 是变调的快进，1.5× 等于抬 7 个半音，
            // 对着一版「音调必须对上」的 app 不能用）。这里走 TimePitch：只有时长变，音高钉死。
            // 两条格子共用同一个值：① 和 ④ 用的是同一个 controller，调一次两条都跟着。
            HStack(spacing: 10) {
                Text(String(format: "语速 %.2f×", player.rate))
                    .font(.caption)
                    .frame(width: 92, alignment: .leading)
                Slider(value: $player.rate, in: 0.5...2.0, step: 0.05)
                    .frame(maxWidth: 240)
                Button("原速") { player.rate = 1.0 }
                    .buttonStyle(.bordered)
                    .font(.caption)
            }

            HStack(spacing: 15) {
                Button {
                    player.play(url: url)
                } label: {
                    Label(isMine(url) && player.isPlaying ? "播放中" : "播放",
                          systemImage: isMine(url) && player.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(isMine(url) && player.isPlaying)

                Button {
                    player.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!isMine(url) || !player.isPlaying)

                Button {
                    VoiceJournal.line("点「导出\(headline)」 \(url.lastPathComponent)")
                    share.wrappedValue = true
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }

            if isMine(url), !player.status.isEmpty {
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

    /// 正在响的到底是不是这一行。
    private func isMine(_ url: URL) -> Bool { player.playingURL == url }

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
        VoiceJournal.line(String(format: "开始转换 源=%@ 音色=%@ 音高 %+.0f 半音／去掉男声=%@（线 %.0f Hz）",
                                 inputURL.lastPathComponent, using, semitones,
                                 dropMale ? "开" : "关", PitchGate.maleHz))
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
                                      dropMale: dropMale,
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
            HStack(spacing: 6) {
                Text("接收端地址")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("http://<电脑IP>:8715/report", text: $logEndpoint)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .onSubmit { saveLogEndpoint() }
                Button("存") { saveLogEndpoint() }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
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

    private func saveLogEndpoint() {
        let trimmed = logEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^https?://"#, options: .regularExpression) != nil else {
            sendStatus = "接收端地址得带 http://（现在填的是「\(trimmed)」，没存）"
            VoiceJournal.line("存接收端地址被拒：\(trimmed)")
            return
        }
        VoiceUploader.endpoint = trimmed
        sendStatus = "已存：\(trimmed)"
        VoiceJournal.line("接收端地址 → \(trimmed)")
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
            + "\n\n—— 磁盘日志最近 400 行 ——\n" + VoiceJournal.tail(400)
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
