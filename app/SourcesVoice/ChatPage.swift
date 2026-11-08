import Foundation
import SwiftUI
import UIKit
import Combine          // ObservableObject / @Published / Timer.publish().autoconnect() 都在这一层，不赌传递可见性

/// 链子一次只吃得起一条：⑥ 念语音和 ①④⑤ 用的是同一套 ONNX 图（载一次 ≈343 MB），
/// 两边同时开就是 jetsam。ContentView 的 `busyAnywhere` 只读自己的 @State、看不见别的页面，
/// 所以这一格单独拿一个对象出来，两条路都往里面写：`main` 是主页面那四条，`chat` 是 ⑥ 正在念。
@MainActor
final class ChainGate: ObservableObject {
    @Published var chat = false
    @Published var main = false
}

/// 一条消息。存盘那份的形状照网页 `localStorage` 里那条（role/text/think/sources/err），
/// 多两个字段：念出来的 wav 文件名、语音那一行的读数。
struct ChatRecord: Codable, Identifiable {
    var id: Int
    var role: String              // user / assistant / system
    var text = ""
    var think = ""
    var sources: [ChatNet.Src] = []
    var err = false
    var wav: String? = nil
    var voiceNote = ""
    /// 附件是消息本身的一部分，所以长在气泡里（网页 renderUser，index.html:816）。
    var imgs: [ChatAttach] = []
    var files: [ChatAttach] = []
    // 下面三个只在这次屏幕上活着（存盘也带上，读回来一律清掉）
    var waiting = ""
    var searching = ""
    var live = false

    enum CodingKeys: String, CodingKey {
        case id, role, text, think, sources, err, wav, voiceNote, imgs, files, waiting, searching, live
    }

    init(id: Int, role: String, text: String = "") {
        self.id = id
        self.role = role
        self.text = text
    }

    /// 缺字段一律退回默认，不让一份半截文件把整页变成空的（样本清单那边同一条理由）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        role = (try? c.decode(String.self, forKey: .role)) ?? "system"
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        think = (try? c.decode(String.self, forKey: .think)) ?? ""
        sources = (try? c.decode([ChatNet.Src].self, forKey: .sources)) ?? []
        err = (try? c.decode(Bool.self, forKey: .err)) ?? false
        wav = try? c.decodeIfPresent(String.self, forKey: .wav)
        voiceNote = (try? c.decode(String.self, forKey: .voiceNote)) ?? ""
        imgs = (try? c.decode([ChatAttach].self, forKey: .imgs)) ?? []
        files = (try? c.decode([ChatAttach].self, forKey: .files)) ?? []
        waiting = ""
        searching = ""
        live = false
    }
}

struct ChatBook: Codable {
    var v = 1
    var feed: [ChatRecord] = []
}

/// 输入栏第一行是网页的 flex-wrap：放不下就换行，不许挤成一条读不了的窄字。
struct WrapRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255.0,
                  green: Double((hex >> 8) & 0xff) / 255.0,
                  blue: Double(hex & 0xff) / 255.0,
                  opacity: 1)
    }
}

/// ⑥「念出来」那个入口的形状，存一份在这儿：属性位和 init 参数位必须一字不差，写两遍早晚要漂。
///
/// 内嵌那层回调的 `@escaping` 不能省：函数类型里再套一层函数参数时，Swift 默认按 non-escaping 算
/// （属性位也一样，0.1/40 头两轮 CI 就是分别红在这两处），而 ContentView 那头 `chatSpeak` 的 onStage
/// 要转交 readNovel（@escaping）。函数子类型对参数是逆变的 ⇒ 少标一处就报
/// 「converting non-escaping value … may allow it to escape」／「cannot assign value of type …」。
///
/// 标 @MainActor：那一头要读 ContentView 的 @State（模型目录、音高、嗓音），不许跑到别的线程上读。
typealias ChatSynth = @MainActor (String, SampleStore.Sample?, @escaping (String) -> Void) async throws -> URL

/// ⑥「和 AI 聊天」那一整页。
///
/// 版式逐条对着电脑上那个 `AI local model manager` 的聊天页搬（`index.html:252-294` + `:75-92`）：
/// 同一套深色变量、你发的在右边蓝气泡、AI 在左边灰气泡、橙字排队、蓝字联网、
/// 思考那段左边 2 px 竖线、下面「复制 / 复制思考」、输入栏第一行还是
/// 模型 + Stream + 思考 + 🔍 联网 + ＋ 新开会话，第二行「发送消息...」+ 发送。
///
/// 只多两样：网页和代理在同一台电脑上，手机得自己填地址；以及这一页的正事 ——
/// 「AI 用哪个音色回话」+ 把回答念出来（走 ④ 那条现成的链，不新增模型）。
struct ChatPage: View {
    @ObservedObject var player: PlayController
    @ObservedObject var chain: ChainGate
    var samples: [SampleStore.Sample]
    @Binding var pickedID: String?
    /// 文本 + 音色 → 一个能播的 wav。模型目录、链子、系统嗓音都在 ContentView 那边。
    let synthesize: ChatSynth
    let onClose: () -> Void

    /// 显式给一份入口：调用方只该看见这六样，下面那堆私有状态和配色不进参数表。
    init(player: PlayController, chain: ChainGate, samples: [SampleStore.Sample],
         pickedID: Binding<String?>,
         synthesize: @escaping ChatSynth,
         onClose: @escaping () -> Void) {
        self.player = player
        self.chain = chain
        self.samples = samples
        self._pickedID = pickedID
        self.synthesize = synthesize
        self.onClose = onClose
    }

    // 网页 :root 里那十个变量，一个数都没换
    private let bg = Color(hex: 0x0d1117)
    private let surface = Color(hex: 0x161b22)
    private let edge = Color(hex: 0x30363d)
    private let fg = Color(hex: 0xe6edf3)
    private let muted = Color(hex: 0x8b949e)
    private let accent = Color(hex: 0x58a6ff)
    private let green = Color(hex: 0x3fb950)
    private let red = Color(hex: 0xf85149)
    private let orange = Color(hex: 0xd29922)
    private let userFill = Color(hex: 0x1f6feb)
    private let userEdge = Color(hex: 0x388bfd)

    @State private var feed: [ChatRecord] = []
    @State private var draft = ""
    /// 还没发出去的附件（网页那个 PEND 数组）。发的时候整份并进那条用户消息。
    @State private var pend: [ChatAttach] = []
    @State private var attachPick: AttachPick?
    @State private var busy = false
    @State private var speakingID: Int?
    @State private var models: [ChatNet.ModelRow] = []
    @State private var model = UserDefaults.standard.string(forKey: "aiModelName") ?? ""
    @State private var streamOn = true
    @State private var thinkOn = false
    @State private var webOn = false
    @State private var voiceOn = (UserDefaults.standard.object(forKey: "chatVoiceOn") as? Bool) ?? true
    @State private var server = UserDefaults.standard.string(forKey: "aiServerURL") ?? "http://192.168.31.99:8000"
    @State private var netNote = ""
    @State private var confirmNew = false
    @State private var showSamples = false
    @State private var copied: [String: String] = [:]
    @State private var thinkOpen: Set<Int> = []
    @State private var scrollTick = 0
    @State private var tickGen = 0
    @State private var loaded = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                ScrollViewReader { sc in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if feed.isEmpty {
                                Text("打字问它。回答会用你挑的那条音色念出来。")
                                    .font(.system(size: 12))
                                    .italic()
                                    .foregroundColor(muted)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 40)
                            }
                            ForEach(feed) { it in
                                bubble(it, maxW: max(120, (geo.size.width - 40) * 0.8))
                                    .id(it.id)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                    .onAppear { sc.scrollTo(feed.last?.id, anchor: .bottom) }
                    .onChange(of: scrollTick) { sc.scrollTo(feed.last?.id, anchor: .bottom) }
                }
                inputBar
            }
            .background(bg.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if !loaded {
                loaded = true
                load()
                VoiceJournal.line("聊天页已打开：地址 \(server)／音色 \(sampleName)／语音回复 \(voiceOn)")
            }
            Task { await reloadModels() }
        }
        // 网页是 20 s 轮一次模型清单：后端加载好了、或者换了个模型，这边不用重开页面
        .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { _ in
            if !busy { Task { await reloadModels() } }
        }
        .sheet(isPresented: $showSamples) { sampleSheet }
        .fullScreenCover(item: $attachPick) { attachPage($0) }
        .confirmationDialog(newSessionText, isPresented: $confirmNew, titleVisibility: .visible) {
            Button("清掉，新开会话", role: .destructive) { newSession() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 头

    private var header: some View {
        HStack(spacing: 8) {
            Text("🤖 和 AI 聊天")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(fg)
            Spacer(minLength: 8)
            Circle()
                .fill(models.isEmpty ? red : green)
                .frame(width: 8, height: 8)
            Text(server.isEmpty ? "没填地址" : ChatNet.normalized(server))
                .font(.system(size: 12))
                .foregroundColor(muted)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .trailing)
            Button("关闭") { onClose() }
                .font(.system(size: 13))
                .foregroundColor(accent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(surface)
        .overlay(alignment: .bottom) { Rectangle().fill(edge).frame(height: 1) }
    }

    // MARK: - 气泡

    @ViewBuilder
    private func bubble(_ it: ChatRecord, maxW: CGFloat) -> some View {
        if it.role == "user" {
            let has = !it.imgs.isEmpty || !it.files.isEmpty
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 6) {
                    // 附件是消息本身的一部分，直接长在气泡里，不做成外面一条附件栏（网页 renderUser）
                    if has {
                        WrapRow(spacing: 8) {
                            ForEach(it.imgs) { a in
                                if a.dataUrl.isEmpty {
                                    fileChip(a, note: "图太大，副本里只留了名字")
                                } else {
                                    AttachThumb(attach: a)
                                }
                            }
                            ForEach(it.files) { a in fileChip(a) }
                        }
                    }
                    Text(it.text.isEmpty ? (has ? "（仅附件）" : "（空）") : it.text)
                        .font(.system(size: 14))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(userFill)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(userEdge, lineWidth: 1))
                .frame(maxWidth: maxW)
            }
        } else if it.role == "system" {
            Text(it.text)
                .font(.system(size: 12))
                .italic()
                .foregroundColor(muted)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if it.err {
            Text(it.text.isEmpty ? "[Request failed]" : it.text)
                .font(.system(size: 14))
                .lineSpacing(5)
                .textSelection(.enabled)
                .foregroundColor(red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(red.opacity(0.1))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(red, lineWidth: 1))
                .frame(maxWidth: maxW * 1.125)
        } else {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    if !it.waiting.isEmpty { waitingRow(it.waiting) }
                    if !it.searching.isEmpty {
                        Text(it.searching)
                            .font(.system(size: 12))
                            .foregroundColor(accent)
                            .textSelection(.enabled)
                    }
                    if !it.think.isEmpty { thinkRow(it) }
                    Text(it.text)
                        .font(.system(size: 14))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !it.sources.isEmpty { sourcesRow(it) }
                    if !it.live { actsRow(it) }
                    if !it.live { voiceRow(it) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(surface)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(edge, lineWidth: 1))
                .frame(maxWidth: maxW)
                Spacer(minLength: 0)
            }
        }
    }

    /// 橙字那一行排队。网页是 `::before` 一个呼吸的 ●，这里用 TimelineView 自己呼吸，
    /// 不额外挂一个 Timer 去改 @State（每秒钟把整页重画一遍不值）。
    private func waitingRow(_ s: String) -> some View {
        TimelineView(.periodic(from: .now, by: 0.6)) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("●")
                    .font(.system(size: 12))
                    .foregroundColor(orange)
                    .opacity(phase < 0.5 ? 1.0 : 0.25)
                Text(s)
                    .font(.system(size: 12))
                    .foregroundColor(orange)
            }
        }
    }

    private func thinkRow(_ it: ChatRecord) -> some View {
        let open = thinkOpen.contains(it.id)
        return VStack(alignment: .leading, spacing: 4) {
            Text(it.think)
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundColor(muted)
                .textSelection(.enabled)
                .lineLimit(open ? nil : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(open ? "收起思考" : "展开全部思考") {
                if open { thinkOpen.remove(it.id) } else { thinkOpen.insert(it.id) }
            }
            .font(.system(size: 11))
            .foregroundColor(muted)
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Rectangle().fill(edge).frame(width: 2) }
    }

    private func sourcesRow(_ it: ChatRecord) -> some View {
        let list = deduped(it.sources)
        let queries = Set(list.map { $0.query }).count
        return VStack(alignment: .leading, spacing: 3) {
            DashLine()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundColor(edge)
                .frame(height: 1)
                .padding(.top, 6)
            Text("联网来源（\(queries) 次查询 · \(list.count) 条链接）")
                .font(.system(size: 12))
                .foregroundColor(muted)
            ForEach(Array(list.enumerated()), id: \.offset) { _, s in
                Button {
                    if let u = URL(string: s.url), s.url.hasPrefix("http") { openURL(u) }
                } label: {
                    Text("[\(s.rank)] \(String((s.title.isEmpty ? s.url : s.title).prefix(90)))")
                        .font(.system(size: 12))
                        .foregroundColor(s.url.hasPrefix("http") ? accent : muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func actsRow(_ it: ChatRecord) -> some View {
        HStack(spacing: 8) {
            if !it.text.isEmpty { act("复制", key: "\(it.id)|text", text: it.text) }
            if !it.think.isEmpty { act("复制思考", key: "\(it.id)|think", text: it.think) }
            Spacer(minLength: 0)
        }
    }

    private func act(_ label: String, key: String, text: String) -> some View {
        let done = copied[key]
        return Button {
            UIPasteboard.general.string = text
            copied[key] = "已复制"
            VoiceJournal.line("聊天复制 \(key)（\(text.count) 字）")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                copied[key] = nil
            }
        } label: {
            Text(done ?? label)
                .font(.system(size: 11))
                .foregroundColor(done == nil ? muted : green)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(done == nil ? edge : green.opacity(0.4), lineWidth: 1))
    }

    /// 网页没有的那一行：这条回答念出来没有 / 念到哪了 / 念好了能重播。
    @ViewBuilder
    private func voiceRow(_ it: ChatRecord) -> some View {
        if it.text.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if speakingID == it.id {
                        Text("念出来中…")
                            .font(.system(size: 11))
                            .foregroundColor(orange)
                    } else if let name = it.wav, let url = wavURL(name),
                              FileManager.default.fileExists(atPath: url.path) {
                        Button {
                            player.play(url: url)
                        } label: {
                            Text(player.playingURL == url && player.isPlaying ? "播放中" : "播放")
                                .font(.system(size: 11))
                                .foregroundColor(accent)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(edge, lineWidth: 1))

                        Button {
                            player.stop()
                        } label: {
                            Text("停止")
                                .font(.system(size: 11))
                                .foregroundColor(muted)
                        }
                        .buttonStyle(.plain)
                        .disabled(!(player.playingURL == url && player.isPlaying))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(edge, lineWidth: 1))

                        Text(name)
                            .font(.system(size: 10))
                            .foregroundColor(muted)
                    } else {
                        Button {
                            speak(it.id, it.text, samples.first { $0.id == pickedID })
                        } label: {
                            Text(it.wav == nil ? "念出来" : "重念（原文件没了）")
                                .font(.system(size: 11))
                                .foregroundColor(accent)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(edge, lineWidth: 1))
                    }
                    Spacer(minLength: 0)
                }
                if !it.voiceNote.isEmpty {
                    Text(it.voiceNote)
                        .font(.system(size: 11))
                        .foregroundColor(muted)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: - 输入栏

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 网页和代理在同一台电脑上，所以那边没有这一行；手机必须自己说电脑在哪
            HStack(spacing: 8) {
                Text("电脑")
                    .font(.system(size: 12))
                    .foregroundColor(muted)
                TextField("http://192.168.31.99:8000", text: $server)
                    .font(.system(size: 13))
                    .foregroundColor(fg)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(bg)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(edge, lineWidth: 1))
                    .onChange(of: server) {
                        UserDefaults.standard.set(server, forKey: "aiServerURL")
                    }
                Button("测试") { Task { await reloadModels() } }
                    .font(.system(size: 13))
                    .foregroundColor(accent)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(edge, lineWidth: 1))
            }

            WrapRow(spacing: 8) {
                Menu {
                    ForEach(Array(models.enumerated()), id: \.offset) { _, m in
                        Button(m.name + m.tag) { pickModel(m.name) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(modelLabel)
                            .font(.system(size: 13))
                            .foregroundColor(fg)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(muted)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(bg)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(edge, lineWidth: 1))
                }
                check("Stream", on: streamOn) { streamOn.toggle() }
                check("思考", on: thinkOn) { thinkOn.toggle() }
                check("🔍 联网", on: webOn) { webOn.toggle() }
                pickBtn("📎 附件") { attachPick = .files }
                pickBtn("🖼 相册") { attachPick = .album }
                pickBtn("粘贴") { pasteAttach() }
                Button {
                    showSamples = true
                } label: {
                    Text("音色：\(sampleName)")
                        .font(.system(size: 13))
                        .foregroundColor(pickedID == nil ? orange : muted)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundColor(pickedID == nil ? orange : edge))
                check("语音回复", on: voiceOn) {
                    voiceOn.toggle()
                    UserDefaults.standard.set(voiceOn, forKey: "chatVoiceOn")
                    VoiceJournal.line("语音回复开关 → \(voiceOn)")
                }
                Button("＋ 新开会话") {
                    if feed.contains(where: { $0.role == "user" }) || !pend.isEmpty { confirmNew = true } else { newSession() }
                }
                .font(.system(size: 13))
                .foregroundColor(muted)
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundColor(edge))
            }

            // 待发附件条（网页 attachRow）：图 64 pt 缩略图带 ✕，文件一格名字＋大小＋字数
            if !pend.isEmpty {
                WrapRow(spacing: 8) {
                    ForEach(Array(pend.enumerated()), id: \.element.id) { i, a in
                        if a.kind == "image" {
                            imageChip(a) { dropPending(i) }
                        } else {
                            fileChip(a) { dropPending(i) }
                        }
                    }
                }
            }

            if webOn {
                Text("联网：查不查由模型决定 · 一次回答最多 3 个回合，每次搜索后重新排队 · 结果来自必应中文网页")
                    .font(.system(size: 11))
                    .foregroundColor(muted)
            }
            if pend.contains(where: { $0.kind == "image" }), let v = visionNote {
                Text(v)
                    .font(.system(size: 11))
                    .foregroundColor(orange)
            }
            if voiceOn && pickedID == nil {
                Text("语音回复开着，但音色还没挑 ⇒ 回答只出文字。点上面「音色」挑一条样本。")
                    .font(.system(size: 11))
                    .foregroundColor(orange)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("发送消息...", text: $draft, axis: .vertical)
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .foregroundColor(fg)
                    .padding(10)
                    .frame(minHeight: 44, maxHeight: 160)
                    .background(bg)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(edge, lineWidth: 1))
                    .submitLabel(.send)
                    .onSubmit { send() }
                Button(busy ? "回答中…" : "发送") { send() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(accent.opacity(busy ? 0.4 : 1))
                    .cornerRadius(8)
                    .disabled(busy || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pend.isEmpty))
            }

            if !netNote.isEmpty {
                Text(netNote)
                    .font(.system(size: 11))
                    .foregroundColor(models.isEmpty ? orange : muted)
                    .textSelection(.enabled)
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Text("附件：「📎 附件」什么文件都能选（一次可多选），「🖼 相册」直接挑照片（不用先存到「文件」），「粘贴」接住截图。图片按 base64 随消息发出（OpenAI 的 image_url 多模态格式）；文本、代码、日志、CSV 这类读成字符串，以围栏代码块并进同一条消息，模型看到的就是一段文字。判断不了是不是文本的（开头有 0 字节、或解不出 UTF-8）直接拒收，不做半截注入。")
                    Text("附件只在这台手机上被读：不往电脑那台机器写任何文件，代理只看到多出来的那段 prompt。落盘只有会话副本 chat_feed.json 这一份。")
                    Text("代价：单文件最多读 200 KB、注入 4 万字符，一条消息里的文件合计最多 20 万字符，超出就在格子上标「截断」。图这边另加两条网页没有的上限：一张最多 8 MB、一条消息最多 4 张 —— 这台机内存就这么大，超了明说拒收，不悄悄缩图。塞太满会被后端一句 exceed_context_size_error 拒掉。")
                    Text("读图：只有加载了投影器（--mmproj）的模型能读图，发给不支持的会被后端拒绝；上面挂着图时会按代理报的 vision 先提醒一句。一张全屏截图约值 1.5–2.5K prompt token。")
                    Text("回答下面「复制」拿的是原始文字（不含排队提示和来源链接），开了思考的多一个「复制思考」。")
                    Text("会话连同附件正文存在这台手机的 Documents/chat_feed.json 里，重开 app 接着问；副本太大时图片只留名字和大小（那种图重开后发不出去，气泡上会写明）。「＋ 新开会话」把消息、待发附件、已经念出来的语音文件和这份副本一起清掉，不可恢复。")
                    Text("语音这一头走的就是 ④ 那条链：系统朗读 → ②③④ 换成你挑的音色。所以一条回答念出来要等它载图（几十秒），长答复按片落盘、边转边写；系统嗓音和音高两个旋钮和 ④ 共用。")
                    Text("勾「🔍 联网」只影响这一条请求：代理把一个 web_search 工具交给模型，查不查、查什么词都由模型自己决定。一次回答最多 3 个模型回合，回合之间要重新排队，所以比纯本地慢几十秒。")
                }
                .font(.system(size: 11))
                .foregroundColor(muted)
                .padding(.top, 6)
            } label: {
                Text("附件 · 复制 · 会话 · 语音 · 联网说明")
                    .font(.system(size: 12))
                    .foregroundColor(muted)
            }
            .tint(muted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(surface)
        .overlay(alignment: .top) { Rectangle().fill(edge).frame(height: 1) }
    }

    private func check(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                Text(label)
            }
            .font(.system(size: 13))
            .foregroundColor(on ? accent : muted)
        }
        .buttonStyle(.plain)
    }

    /// 网页 `.pick-btn`：13 号灰字、虚线框（📎 附件那一类）。
    private func pickBtn(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 13)).foregroundColor(muted)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundColor(edge))
    }

    // MARK: - 附件

    /// 待发那张图：64 pt 高、最宽 150，右上 ✕、底下一条名字＋大小（网页 .thumb）。
    private func imageChip(_ a: ChatAttach, _ remove: @escaping () -> Void) -> some View {
        AttachThumb(attach: a)
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Text("✕").font(.system(size: 12)).foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .background(Color.black.opacity(0.55))
                .cornerRadius(4)
                .padding(2)
            }
            .overlay(alignment: .bottom) {
                Text("\(a.name) · \(ChatAttachIO.fmtSize(a.size))")
                    .font(.system(size: 10))
                    .foregroundColor(muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.55))
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(edge, lineWidth: 1))
            .cornerRadius(6)
    }

    /// 文件那一格（网页 .fchip）：名字＋大小＋字数＋截断标记；待发时右边多一个 ✕。
    /// `note` 非空时替掉字数那一截 —— 副本里丢了 base64 的图也走这一格。
    private func fileChip(_ a: ChatAttach, note: String = "", remove: (() -> Void)? = nil) -> some View {
        let sub = note.isEmpty
            ? "\(ChatAttachIO.fmtSize(a.size)) · \(a.chars.formatted(.number)) 字\(a.truncated ? " ·截断" : "")"
            : "\(ChatAttachIO.fmtSize(a.size)) · \(note)"
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sub).font(.system(size: 10)).foregroundColor(muted)
            }
            if let remove = remove {
                Button(action: remove) {
                    Text("✕").font(.system(size: 11)).foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .background(Color.black.opacity(0.55))
                .cornerRadius(4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 300)
        .background(bg)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(edge, lineWidth: 1))
    }

    /// 挂着图、而选中的模型明确报了「不支持读图」时先说一句（网页 Models 页那行 vision 的读数）。
    /// nil = 后端没上报模态，那种情况不拦也不瞎猜。
    private var visionNote: String? {
        guard let m = models.first(where: { $0.name == model }) else { return nil }
        if m.vision == false { return "「\(m.name)」没加载投影器（--mmproj）⇒ 图发过去会被后端拒。换个能读图的模型，或把图减掉。" }
        return nil
    }

    /// 一个呈现给两种选择器。收场由回调自己做（这环境下 cover 不会自己消失）。
    @ViewBuilder
    private func attachPage(_ which: AttachPick) -> some View {
        if which == .album {
            ImageAlbumPickerHost(onPick: { data, name, mime in
                take(ChatAttachIO.fromImage(data, name: name, mime: mime, pending: pend))
            }, onCancel: { msg in
                addNote("附件：" + msg)
                VoiceJournal.line("相册选图取消／失败（\(msg)）")
            }, onDismiss: {
                attachPick = nil
            })
        } else {
            DocumentPickerHost(onPick: { url in
                // 附件要的是字节本身，读完就丢：不往 Documents 拷副本（拷了就是残料，历史页还得替它擦）
                take(ChatAttachIO.fromFile(url, pending: pend))
            }, onCancel: { msg in
                addNote("附件：" + msg)
                VoiceJournal.line("选附件取消（\(msg)）")
            }, onDismiss: {
                attachPick = nil
            }, multiple: true)
        }
    }

    private func take(_ got: (ChatAttach?, String)) {
        if let a = got.0 { pend.append(a) }
        if !got.1.isEmpty { addNote("附件：" + got.1) }
    }

    private func dropPending(_ i: Int) {
        guard pend.indices.contains(i) else { return }
        let a = pend.remove(at: i)
        VoiceJournal.line("附件移除 \(a.name)")
    }

    /// 网页是 Ctrl+V：有图当附件、纯文字照旧进输入框。手机没有光标位置可插，文字接在草稿末尾。
    private func pasteAttach() {
        let (a, note, text) = ChatAttachIO.fromPasteboard(pending: pend)
        if let a = a { pend.append(a) }
        if !note.isEmpty { addNote("附件：" + note) }
        if !text.isEmpty {
            draft += text
            VoiceJournal.line("剪贴板文字进草稿（\(text.count) 字）")
        }
        if a == nil && note.isEmpty && text.isEmpty { addNote("附件：剪贴板里既没有图也没有文字") }
    }

    /// 拒收原因走一条居中的灰字（网页 addSystem）。不进上下文，也不单独存盘。
    private func addNote(_ text: String) {
        feed.append(ChatRecord(id: nextID(), role: "system", text: text))
        scrollTick += 1
    }

    private var modelLabel: String {
        if model.isEmpty { return models.isEmpty ? "(no models)" : "选一个模型" }
        if let m = models.first(where: { $0.name == model }) { return model + m.tag }
        return model
    }

    private var sampleName: String {
        if let s = samples.first(where: { $0.id == pickedID }) { return s.info.name }
        return "没挑"
    }

    // MARK: - 音色那一页

    private var sampleSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI 用哪个音色回话")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(fg)
                Spacer()
                Button("关闭") { showSamples = false }
                    .font(.system(size: 13))
                    .foregroundColor(accent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(surface)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if samples.isEmpty {
                        Text("样本清单是空的：先回主页面 ② 录一段（6~10 s 连续干净说话），点「生成样本」。")
                            .font(.system(size: 12))
                            .foregroundColor(muted)
                    }
                    sampleRow(name: "不挑（回答只出文字，不念）", sub: "", selected: pickedID == nil) {
                        pickedID = nil
                        showSamples = false
                        VoiceJournal.line("聊天音色 → 不挑")
                    }
                    ForEach(samples) { s in
                        sampleRow(name: s.info.name,
                                  sub: String(format: "%.1f s%@　%@", s.info.seconds,
                                              s.info.seconds < 6.0 ? "（偏短）" : "", s.id),
                                  selected: pickedID == s.id) {
                            pickedID = s.id
                            showSamples = false
                            VoiceJournal.line("聊天音色 → 样本「\(s.info.name)」（\(s.id)）")
                        }
                    }
                    Text("和主页面「样本清单」是同一个选择：在这儿挑完，①④⑤ 也跟着用这条。")
                        .font(.system(size: 11))
                        .foregroundColor(muted)
                }
                .padding(20)
            }
        }
        .background(bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func sampleRow(name: String, sub: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? accent : muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 14)).foregroundColor(fg)
                    if !sub.isEmpty {
                        Text(sub).font(.system(size: 11)).foregroundColor(muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 发一条

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pend.isEmpty, !busy else { return }
        guard !model.isEmpty else {
            netNote = "还没拿到模型清单：先把电脑地址填对，点「测试」"
            return
        }
        let sample = samples.first { $0.id == pickedID }
        let taken = pend
        pend = []
        draft = ""
        busy = true
        let uid = nextID()
        var me = ChatRecord(id: uid, role: "user", text: text)
        me.imgs = taken.filter { $0.kind == "image" }
        me.files = taken.filter { $0.kind == "text" }
        feed.append(me)
        let aid = nextID()
        feed.append(ChatRecord(id: aid, role: "assistant"))
        mutate(aid) {
            $0.live = true
            $0.waiting = "正在确认后端是否空闲…"
        }
        let hist = history()
        save()
        scrollTick += 1
        VoiceJournal.line("聊天发出 #\(uid) \(text.count) 字＋图 \(me.imgs.count) 张＋文件 \(me.files.count) 个"
                          + "（\(me.files.reduce(0) { $0 + $1.chars }) 字符）→ \(ChatNet.normalized(server))｜模型 \(model)"
                          + "｜stream \(streamOn) 思考 \(thinkOn) 联网 \(webOn)｜音色 \(sampleName)｜语音回复 \(voiceOn)")
        Task { @MainActor in
            await preflight(aid)
            let a = await ChatNet.chat(base: server, model: model, history: hist, stream: streamOn,
                                       thinking: thinkOn, web: webOn) { ev in
                // ChatNet.chat 是 nonisolated async：从这句 await 起它就不在主线程上了，
                // 流里每个字都回调过来 ⇒ 改 @State 必须自己排回主线程（同 ④⑤ 那两条 onStage 的做法）。
                DispatchQueue.main.async { self.apply(ev, aid) }
            }
            finish(a, aid, sample)
        }
    }

    /// 发送前先问一次排队（此刻本请求还没进队，数字才准），上限 1.5 s，宁可少一句提示 —— 网页同一条。
    @MainActor
    private func preflight(_ id: Int) async {
        let base = server
        let name = model
        let q: ChatNet.Queue? = await withTaskGroup(of: ChatNet.Queue?.self) { g in
            g.addTask { try? await ChatNet.queue(base, model: name) }
            g.addTask {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return nil
            }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
        guard let q = q else {
            mutate(id) { $0.waiting = "" }
            return
        }
        if !q.note.isEmpty {
            mutate(id) { $0.waiting = "排队中：" + q.note }
        } else if let w = q.waitS, w > 0 {
            let ahead = q.ahead > 0 ? "，前方 \(q.ahead) 个请求" : ""
            let dur = fmtDur(w)
            mutate(id) { $0.waiting = "模型被占用\(ahead)，预计等待 \(dur) 后开始生成" }
            countdown(id, w)
        } else if q.occupied {
            mutate(id) { $0.waiting = "模型被占用，预计等待时间未知（正在生成，暂无速度样本）" }
        } else {
            mutate(id) { $0.waiting = "" }
        }
    }

    private func countdown(_ id: Int, _ secs: Double) {
        tickGen += 1
        let mine = tickGen
        Task { @MainActor in
            var left = secs
            while left > 0, mine == tickGen, busy {
                let d = fmtDur(left)
                mutate(id) { $0.waiting = "排队中，预计还需 \(d)" }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                left -= 1
            }
            if mine == tickGen, left <= 0, busy {
                mutate(id) { $0.waiting = "排队结束，正在生成首字…" }
            }
        }
    }

    private func apply(_ ev: ChatNet.Event, _ id: Int) {
        switch ev {
        case .answer(let t):
            mutate(id) {
                $0.text = t
                // 下一个模型回合仍可能排队，这行只是先收起
                $0.waiting = ""
                if !$0.sources.isEmpty && $0.searching.isEmpty {
                    $0.searching = "联网回答（来源与查询次数见下）"
                }
            }
            scrollTick += 1
        case .think(let t):
            mutate(id) { $0.think = t }
            scrollTick += 1
        case .search(let s):
            mutate(id) { $0.searching = s }
        case .sources(let list):
            mutate(id) { $0.sources = list }
        case .queue(let w):
            if let w = w {
                if w <= 0 {
                    mutate(id) { if !$0.waiting.isEmpty { $0.waiting = "排队结束，正在生成首字…" } }
                } else {
                    countdown(id, w)
                }
            } else {
                mutate(id) { $0.waiting = "排队中，预计等待时间未知（无历史样本）" }
            }
        }
    }

    @MainActor
    private func finish(_ a: ChatNet.Answer, _ id: Int, _ sample: SampleStore.Sample?) {
        tickGen += 1
        if a.note.isEmpty {
            mutate(id) {
                $0.live = false
                $0.waiting = ""
                $0.searching = ""
                $0.text = a.text
                $0.think = a.think
                $0.sources = deduped(a.sources)
            }
            save()
            busy = false
            scrollTick += 1
            VoiceJournal.line("聊天回答 #\(id)：\(a.text.count) 字／思考 \(a.think.count) 字／来源 \(a.sources.count) 条")
            if voiceOn && !a.text.isEmpty {
                if sample == nil {
                    mutate(id) { $0.voiceNote = "语音回复开着，但这条发送时还没挑音色 ⇒ 只出了文字。挑一条再点「念出来」。" }
                } else {
                    speak(id, a.text, sample)
                }
            }
        } else {
            mutate(id) {
                $0.live = false
                $0.waiting = ""
                $0.searching = ""
                $0.err = true
                $0.text = a.note
            }
            save()
            busy = false
            VoiceJournal.line("聊天失败 #\(id)：\(a.note)")
        }
    }

    // MARK: - 念出来

    @MainActor
    private func speak(_ id: Int, _ text: String, _ sample: SampleStore.Sample?) {
        guard speakingID == nil else { return }
        if chain.chat || chain.main {
            mutate(id) { $0.voiceNote = "链子正在忙别的（①④⑤ 有一条在跑）⇒ 这条没念，等它完了再点「念出来」" }
            return
        }
        guard let sample = sample else {
            mutate(id) { $0.voiceNote = "先在「音色」里挑一条样本（文本这条路没有自转换）" }
            return
        }
        chain.chat = true
        speakingID = id
        mutate(id) {
            $0.voiceNote = "分句、合成中…"
            $0.wav = nil
        }
        VoiceJournal.line("聊天语音开跑 #\(id) \(text.count) 字 音色=样本「\(sample.info.name)」")
        Task { @MainActor in
            do {
                let url = try await synthesize(text, sample) { t in
                    DispatchQueue.main.async { self.mutate(id) { $0.voiceNote = t } }
                }
                mutate(id) { $0.wav = url.lastPathComponent }
                save()
                player.play(url: url)
                VoiceJournal.line("聊天语音完成 #\(id) → \(url.lastPathComponent)")
            } catch {
                mutate(id) { $0.voiceNote = "念不出来：" + error.localizedDescription }
                VoiceJournal.line("聊天语音失败 #\(id)：\(error.localizedDescription)")
            }
            chain.chat = false
            speakingID = nil
        }
    }

    // MARK: - 会话

    private var newSessionText: String {
        let turns = feed.filter { $0.role == "user" }.count
        let wavs = feed.compactMap { $0.wav }.count
        return "新开会话会清掉：\n· 本页 \(turns) 轮问答（含附件正文和思考）\n· \(pend.count) 个还没发出去的附件\n"
            + "· 已经念出来的 \(wavs) 个语音文件\n"
            + "· 存在这台手机上的会话副本（Documents/chat_feed.json）\n\n清掉不可恢复。"
    }

    private func newSession() {
        // 副本清掉之后那些 wav 就没有任何入口指得着了 ⇒ 一起收掉，别留在盘上（历史页也就不用替它擦屁股）
        var gone = 0
        for it in feed {
            if let name = it.wav, let url = wavURL(name) {
                if (try? FileManager.default.removeItem(at: url)) != nil { gone += 1 }
            }
        }
        player.stop()
        let dropped = pend.count
        feed = []
        pend = []
        draft = ""
        try? FileManager.default.removeItem(at: Self.bookURL())
        feed.append(ChatRecord(id: nextID(), role: "system",
                               text: "新会话已开始，之前的消息、附件、语音文件和这台手机上的副本都已清空。"))
        VoiceJournal.line("新开会话：清掉 \(gone) 个语音文件 + \(dropped) 个待发附件 + chat_feed.json")
        scrollTick += 1
    }

    private func nextID() -> Int { (feed.map { $0.id }.max() ?? 0) + 1 }

    /// 和网页 rebuildHistory 同一条：只有 user 和「没出错的 assistant」进上下文，system 不进。
    /// user 那条的 content 交给 ChatAttachIO：没附件就是原来的纯字符串。
    private func history() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for e in feed {
            if e.role == "user" {
                out.append(["role": "user", "content": ChatAttachIO.content(e)])
            } else if e.role == "assistant" && !e.err && !e.text.isEmpty {
                out.append(["role": "assistant", "content": e.text])
            }
        }
        return out
    }

    private func mutate(_ id: Int, _ f: (inout ChatRecord) -> Void) {
        guard let i = feed.firstIndex(where: { $0.id == id }) else { return }
        f(&feed[i])
    }

    private func deduped(_ list: [ChatNet.Src]) -> [ChatNet.Src] {
        var seen = Set<String>()
        var out: [ChatNet.Src] = []
        for s in list where !s.url.isEmpty && !seen.contains(s.url) {
            seen.insert(s.url)
            out.append(s)
        }
        return out
    }

    private func pickModel(_ name: String) {
        model = name
        UserDefaults.standard.set(name, forKey: "aiModelName")
        VoiceJournal.line("聊天模型 → \(name)")
    }

    @MainActor
    private func reloadModels() async {
        do {
            let rows = try await ChatNet.dashboard(server)
            models = rows
            let prev = model
            if let hit = rows.first(where: { $0.name == prev && $0.ready }) {
                model = hit.name
            } else if let first = rows.first(where: { $0.ready })
                        ?? rows.first(where: { $0.online }) ?? rows.first {
                model = first.name
            } else {
                model = ""
            }
            netNote = rows.isEmpty ? "连上了，但代理里一个模型都没登记" : "连上了：\(rows.count) 个模型（就绪的才能选）"
        } catch {
            models = []
            netNote = "连不上：\(error.localizedDescription)"
        }
        VoiceJournal.line("聊天模型清单：\(netNote)｜地址 \(ChatNet.normalized(server))")
    }

    private func wavURL(_ name: String) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return docs.appendingPathComponent(name)
    }

    static func bookURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("chat_feed.json")
    }

    private func save() {
        var copy = feed
        for i in copy.indices {
            copy[i].live = false
            copy[i].waiting = ""
        }
        // 网页量的是整份 JSON 的字符数（LS_MAX_CHARS）；这边先量 base64 那一段 —— 它就是体积大头，
        // 超了先丢图再编码，省掉一次几十 MB 的白编码。屏幕上这份不动，本次会话照样发得出去。
        let bulk = copy.reduce(0) { $0 + $1.imgs.reduce(0) { $0 + $1.dataUrl.count } }
        if bulk > ChatAttachIO.bookMaxBytes {
            for i in copy.indices {
                for j in copy[i].imgs.indices { copy[i].imgs[j].dataUrl = "" }
            }
            VoiceJournal.line("聊天会话副本里图片 base64 合计 \(bulk / 1024) KB，超过 \(ChatAttachIO.bookMaxBytes / 1024) KB ⇒ 副本只留图的名字和大小")
        }
        do {
            try JSONEncoder().encode(ChatBook(feed: copy)).write(to: Self.bookURL())
        } catch {
            VoiceJournal.line("聊天会话存盘失败：\(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.bookURL()) else { return }
        guard let book = try? JSONDecoder().decode(ChatBook.self, from: data) else {
            VoiceJournal.line("聊天会话副本读不出来（chat_feed.json），从空的开始")
            return
        }
        // 发出去就先存一次（问话和附件别跟着闪退一起没），所以副本里可能留着一条还没收到字的
        // assistant 占位。那种读回来就是一个空气泡，在这儿收掉。
        feed = book.feed.filter {
            $0.role != "system" && !($0.role == "assistant" && $0.text.isEmpty && $0.think.isEmpty)
        }
        let imgs = feed.reduce(0) { $0 + $1.imgs.count }
        let lost = feed.reduce(0) { $0 + $1.imgs.filter { $0.dataUrl.isEmpty }.count }
        VoiceJournal.line("聊天会话副本已读回：\(feed.count) 条（\(feed.filter { $0.role == "user" }.count) 轮问答）"
                          + "／图 \(imgs) 张（其中 \(lost) 张只剩名字）／文件 \(feed.reduce(0) { $0 + $1.files.count }) 个")
    }

    /// 网页 fmtDur 那一套：ms / s / 分秒 / 时分。
    private func fmtDur(_ s: Double) -> String {
        if s < 1 { return "\(Int((s * 1000).rounded()))ms" }
        if s < 60 { return String(format: s < 10 ? "%.1fs" : "%.0fs", s) }
        let m = Int(s / 60)
        let sec = Int((s.truncatingRemainder(dividingBy: 60)).rounded())
        if s < 3600 { return "\(m)分\(sec)秒" }
        return "\(m / 60)时\(m % 60)分"
    }
}

/// 来源那一块的虚线上边框（CSS 是 border-top: 1px dashed）。
struct DashLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

/// 附件那张 64 pt 缩略图。解码＋出图扔后台做一次：挂在 body 里就是每次重画都解一遍几 MB 的 base64。
private struct AttachThumb: View {
    let attach: ChatAttach
    @State var img: UIImage? = nil

    var body: some View {
        Group {
            if let img = img {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundColor(Color(hex: 0x8b949e))
                    .frame(width: 90)
            }
        }
        .frame(height: 64)
        .frame(maxWidth: 150)
        .background(Color(hex: 0x0d1117))
        .clipped()
        .onAppear {
            guard img == nil else { return }
            let a = attach
            DispatchQueue.global(qos: .userInitiated).async {
                let got = ChatAttachIO.thumbnail(a)
                DispatchQueue.main.async { img = got }
            }
        }
    }
}