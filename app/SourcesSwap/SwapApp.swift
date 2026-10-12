import SwiftUI

@main
struct SwapApp: App {
    var body: some Scene {
        WindowGroup {
            SwapContentView()
        }
    }
}

struct SwapContentView: View {
    @State private var facts: [String] = []
    @State private var benchText = ""
    @State private var isRunning = false
    @State private var sendStatus = ""
    @State private var isSending = false
    @State private var logTail = ""
    @State private var runs = 30

    /// 跑着的时候每秒把流水捞上来一次：自检是逐个 unit 往前推的，
    /// 只等最后结果的话，中间几分钟界面上看着像没动。
    private let pulse = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("环境").font(.headline)
                    ForEach(facts, id: \.self) { Text($0).font(.caption) }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("逐帧网自检").font(.headline)
                        Stepper("每次计 \(runs) 帧", value: $runs, in: 5...200, step: 5)
                            .font(.caption)
                        // 点下去立刻置灰 + 改文案：手机上长任务没有别的反馈手段
                        Button(isRunning ? "自检跑着…" : "跑逐帧网自检") {
                            runBench()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRunning)
                        Button(isSending ? "发送中…" : "发到电脑") {
                            sendReport()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSending)
                        if !sendStatus.isEmpty {
                            Text(sendStatus).font(.caption)
                        }
                        Text(isRunning ? "跑着，下面流水在动：" : (benchText.isEmpty ? "（自检还没跑过）" : ""))
                            .font(.caption)
                        if !logTail.isEmpty {
                            Text(logTail)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if !benchText.isEmpty {
                            Text(benchText)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }

                    Divider()

                    DisclosureGroup("这一版在判什么") {
                        Text("""
                        包里只带换脸那条链最小的那张网（逐帧 0.53 GFLOP）。身份那 18 个权重张量喂随机数，\
                        所以这里只出速度和数值一致性，不出长相——真要出片得连 arcface 和权重生成网一起上，那是下一版。
                        四个 compute unit 逐个报加载耗时和每帧多少钱：这张网里有 Resize/Slice/Concat，
                        ANE 认不认它 PC 上判不了，只能看这三行谁快。
                        """)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("换脸自检")
            .onAppear {
                facts = SwapFacts.lines()
                logTail = SwapJournal.tail(30)
            }
            .onReceive(pulse) { _ in
                if isRunning { logTail = SwapJournal.tail(30) }
            }
        }
    }

    private func runBench() {
        isRunning = true
        benchText = ""
        SwapJournal.line("开始逐帧网自检 runs=\(runs)")
        let n = runs
        Task.detached {
            let text = SwapBench.probe(runs: n) { line in
                SwapJournal.line(line)
            }
            DispatchQueue.main.async {
                benchText = text
                isRunning = false
            }
        }
    }

    private func sendReport() {
        isSending = true
        sendStatus = "发着…"
        let facts = SwapFacts.lines().joined(separator: "\n")
        let bench = benchText.isEmpty ? "（自检还没跑过——先点「跑逐帧网自检」）" : benchText
        let text = "—— 环境 ——\n" + facts
            + "\n\n—— 逐帧网自检 ——\n" + bench
            + "\n\n—— 流水 ——\n" + SwapJournal.tail(40)
        Task.detached {
            let r = SwapUploader.send(text)
            SwapJournal.line("发到电脑：\(r)")
            DispatchQueue.main.async {
                sendStatus = r
                isSending = false
            }
        }
    }
}
