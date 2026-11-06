import SwiftUI
import Foundation
import UIKit
import AVFoundation
import CoreML
import PhotosUI

@main
struct VR3DApp: App {
    /// 方向闸在 delegate 那边（SwiftUI 没有别的口子能回答 supportedInterfaceOrientations），
    /// 所以必须挂一个 delegate；挂上它不影响这套 App 协议的生命周期。
    @UIApplicationDelegateAdaptor(VRAppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            VRMainView()
        }
    }
}

/// 系统每次要转屏都来问这里。返回的是「此刻」允许的朝向：播放页把横屏放开，出来就收回去。
/// 这一版开始把「到底有没有人来问过」也记下来：0.18~0.21 三版横屏都不动，
/// 分不清是这道闸没放开、还是压根没人来问（LiveContainer 里我们这份 delegate 未必是本进程的应用代理）。
final class VRAppDelegate: NSObject, UIApplicationDelegate {
    /// 只记前 8 次，免得播着播着把日志刷满
    private static var asked = 0
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        let m = VROrientation.current
        if VRAppDelegate.asked < 8 {
            VRAppDelegate.asked += 1
            VRJournal.line("朝向 delegate 第 \(VRAppDelegate.asked) 次被问，交回 \(VROrientation.name(m))"
                + "｜窗 \(window.map { String(describing: type(of: $0)) } ?? "没给")")
        }
        return m
    }
}

/// 播放页要不要允许横屏，由这一个开关说；Info.plist 那三档是上限，这里是在上限里再收。
enum VROrientation {
    private static let lock = NSLock()
    private static var mask: UIInterfaceOrientationMask = .portrait

    static var current: UIInterfaceOrientationMask {
        lock.lock(); defer { lock.unlock() }
        return mask
    }

    static func name(_ m: UIInterfaceOrientationMask) -> String {
        var parts: [String] = []
        if m.contains(.portrait) { parts.append("竖") }
        if m.contains(.landscapeLeft) { parts.append("左横") }
        if m.contains(.landscapeRight) { parts.append("右横") }
        if m.contains(.portraitUpsideDown) { parts.append("倒竖") }
        return parts.isEmpty ? "空" : parts.joined(separator: "+")
    }

    /// 把「场景有几个、角色是什么、现在朝哪儿」摊开记一行。
    /// 横屏不成时这三样能分清：没有窗口场景（LiveContainer 把场景给了宿主）、几何更新被拒、
    /// 还是闸放开了系统也不转（那是 delegate 没人问 / 最上面的控制器不支持）。
    static func report(_ tag: String) {
        DispatchQueue.main.async {
            var n = 0
            var txt = ""
            for scene in UIApplication.shared.connectedScenes {
                n += 1
                guard let ws = scene as? UIWindowScene else {
                    txt += "[\(n) 不是 UIWindowScene]"
                    continue
                }
                let role = scene.session.role == .windowApplication ? "主窗" : "其它角色"
                let ori = ws.interfaceOrientation
                // UIWindowScene 这一版 SDK 没有「读当前几何优先级」这一条（CI 报的 no member），
                // 想分清通知档高低只能看 requestGeometryUpdate 被不被拒
                txt += "[\(n) \(role) 朝向\(ori.rawValue) 窗\(ws.windows.count)]"
            }
            VRJournal.line("朝向 盘点 \(tag)：闸=\(name(current))｜场景 \(n) 个 \(txt)")
        }
    }

    /// 改完闸还得自己催一次几何更新：手机本来就横着进播放页时，系统不会重新算一次朝向，
    /// 页面就一直竖着（iOS 16 起 UIDevice.orientation 也不让直接设了）。
    static func allowLandscape(_ on: Bool) {
        lock.lock()
        mask = on ? [.portrait, .landscapeLeft, .landscapeRight] : .portrait
        let want = mask
        lock.unlock()
        VRJournal.line("朝向 \(on ? "播放页放开横屏" : "收回只留竖屏") 闸现在 \(name(mask))")
        report("闸刚改")
        DispatchQueue.main.async {
            var sent = 0
            for scene in UIApplication.shared.connectedScenes {
                guard let ws = scene as? UIWindowScene else { continue }
                // 那个 C 常量在 Swift 侧已改名成 UISceneSession.Role.windowApplication（CI 报的）；
                // 外部显示场景也在 connectedScenes 里，不认角色就会把几何更新发给错的那个
                guard scene.session.role == .windowApplication else { continue }
                sent += 1
                ws.requestGeometryUpdate(.iOS(interfaceOrientations: want)) { e in
                    VRJournal.line("朝向 几何更新被拒 \(e.localizedDescription)")
                }
            }
            VRJournal.line("朝向 几何更新发出 \(sent) 个场景（主窗角色几个就是几个，0 个说明这进程里没有我们的窗口场景）")
            report("几何更新后")
        }
    }
}

struct VRMainView: View {
    @StateObject private var job = VRJob()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("VR3D 验证件 v\((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "-")")
                    .font(.title2)
                    .foregroundColor(.green)

                Text(VRFacts.lines().joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)

                Picker("出片模式", selection: $job.fullMode) {
                    Text("试片 几秒").tag(false)
                    Text("全片 整条").tag(true)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                if job.fullMode {
                    Picker("全片出几条", selection: $job.fullZps) {
                        Text("1 条 zp0.15").tag(1)
                        Text("3 条 zp.15/.50/.85").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .font(.footnote)

                    Toggle(isOn: $job.withAudio) {
                        Text("带声音 源片音轨搬进成片（AAC，只认 1、2 声道）").font(.footnote)
                    }

                    Text("全片不限时长：一趟扫（深度落盘 0.77 MB/帧＝518x392 的 Float32，按 30 fps 约 23 MB/秒素材）"
                         + "＋每条一趟出片。开跑前先看磁盘闸门报的那一行：够就往下跑，不够就直接告诉你还能塞多少秒。"
                         + "整片 p1/p99（PC 的 m6 口径）、时域平滑 0.4 都在这条路上，跟抽帧数的 6.6 s 样片无关\n"
                         + "按 10-10 实测单价折：扫约 0.25 s/帧、出片约 0.15 s/帧 ⇒ 3 分钟片 1 条约 35 分钟、3 条约 1 小时"
                         + "（这数是按单价乘出来的，全片这条链路本身还没上机跑过）")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.orange)
                } else {
                    Picker("抽帧数", selection: $job.frames) {
                        Text("6 帧").tag(6)
                        Text("10 帧").tag(10)
                        Text("20 帧").tag(20)
                    }
                    .pickerStyle(.segmented)
                    .font(.footnote)

                    Text("送检尺寸不可调：模型声明「只认 518x392」（上机实测）\n"
                         + "竖屏画面等比进去只占约 215~220 px 宽，左右是黑边 ⇒ 深度单价与「每眼」档无关")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.orange)
                }

                Picker("送检朝向", selection: $job.feedRot) {
                    Text("摆正").tag(false)
                    Text("转 90°").tag(true)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                Text("尺寸动不了，朝向能换画面在框里占多少：每眼 540x960 摆正 86k px（上机实测）／转 90° 按信箱公式算 151k px（+75%，这版自己会在报告里报「本次实占」）")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                Picker("每眼长边", selection: $job.eyeLong) {
                    Text("540").tag(540)
                    Text("720").tag(720)
                    Text("960").tag(960)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                Picker("视差上限", selection: $job.bpct) {
                    Text("3%").tag(3)
                    Text("5%").tag(5)
                    Text("8%").tag(8)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                Picker("试片计算单元", selection: $job.unitTag) {
                    Text("CPU").tag(3)
                    Text("all").tag(0)
                    Text("GPU").tag(1)
                    Text("ANE").tag(2)
                }
                .pickerStyle(.segmented)
                .font(.footnote)

                Text("上机实测 518x392：CPU 184 ms/帧（加载 0.43 s）｜GPU 461｜ANE 697（加载 122 s）｜all 853（加载 132 s）")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                HStack(spacing: 10) {
                    Button("环境自检") { job.startCheck() }
                    Button("深度自检") { job.startProbe() }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
                .disabled(job.busy)

                HStack(spacing: 10) {
                    Button(job.fullMode ? "选视频出全片" : "选视频出试片") { job.showVideoPicker = true }
                    Button("发到电脑") { job.sendReport() }
                }
                .buttonStyle(.borderedProminent)
                .font(.footnote)
                .disabled(job.busy)

                HStack(spacing: 10) {
                    Button(job.cleanArmed
                           ? "确认删除 \(job.cleanTargets.count) 个（\(String(format: "%.1f", job.cleanMB)) MB）"
                           : "删除历史视频") { job.tapClean() }
                    if job.cleanArmed {
                        Button("取消") { job.cancelClean() }
                    }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
                .disabled(job.busy)

                Text("清的是 app 自己目录里的历史文件：临时目录的源片副本、Documents 的深度缓存和没存进相册的成片。相册里的原片和已入库成品不受影响")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                HStack(spacing: 10) {
                    Button("播放相册（左右眼）") { job.pickForPlayback() }
                    Button("实时左右眼播放") { job.pickForLive() }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
                .disabled(job.busy || VRFull.isBusy() || VRLive.isBusy())

                Text("两条播放都走同一套：点屏幕出控件（暂停、拖进度、左右眼水平位置 ±12%，存一次下次照用），手机横过来就横屏全屏，出声靠 .playback 这个音频类别（不再听静音拨片的）。播相册那条选本身已是左右眼的片子，只按半幅平移、不跑深度；实时那条选普通视频，边解帧边形变直接上屏，不写文件、不进相册。实时画面按源的帧率走，深度实测 180~200 ms/帧 ⇒ 立体感约每秒 5 次一级一级跳；实时拿不到整片 p1/p99，改成已见样本的滑动分位，开头几秒幅度会偏\n"
                     + "生成存相册的那条按约定不带音轨（做片的时候就把声音丢了），要看成片的效果请用实时那条播原片")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                if job.busy {
                    Text(job.status)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    if job.fullRunning && VRFull.totalFrames > 0 {
                        ProgressView(value: Double(VRFull.doneFrames), total: Double(VRFull.totalFrames))
                            .tint(.green)
                    }
                }
                if job.fullRunning && !job.stopPressed {
                    Button("停止（已扫的和已出的照样收）") { job.stopFull() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .font(.footnote)
                }

                Text(job.log.joined(separator: "\n\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                DisclosureGroup("磁盘日志（闪退后重开还在）") {
                    Text(VRJournal.tail(12))
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
            }
            .padding()
        }
        .fullScreenCover(isPresented: $job.showVideoPicker) {
            VRPickerHost { url, msg in job.finishPick(url: url, failMessage: msg) }
        }
        // 播放页不再用 fullScreenCover：改成自己那个 UIViewController（VRPlayPage.swift），
        // 转屏和全屏都由我们自己呈现，理由写在那份文件头上
    }
}

@MainActor
final class VRJob: ObservableObject {
    @Published var log: [String] = []
    @Published var busy = false
    @Published var status = ""
    @Published var showVideoPicker = false
    /// 真放进这一页的是不是「原样左右眼」：true=相册那条已经是 SBS，false=普通视频实时形变
    @Published var liveSbs = false
    /// 下一次选片的去向：0=拿去转，1=拿去播（已是左右眼，原样上屏），2=拿去实时播（普通视频）
    private var pickPurpose = 0
    /// 播放器手里那份 tmp 副本，关掉页面时删
    private var liveCopy: URL?
    @Published var frames = 10
    @Published var eyeLong = 540
    @Published var bpct = 5
    /// 默认 CPU：10-10 上机实测 184 ms/帧，比 all 的 853 ms 快 4.6 倍，且不交 ANE 那 122 s 的加载税
    @Published var unitTag = 3
    /// 默认摆正：所有已测数字都是这个口径下测的，换朝向要靠同一素材两版对看
    @Published var feedRot = false
    /// 试片（抽 N 帧、只出几秒，指标全）／全片（整条，深度落盘跑两趟）
    @Published var fullMode = false
    /// 1 条 = PC m6 那个出货档 zp0.15；3 条 = 上中下三个零视差面对比
    @Published var fullZps = 1
    /// 全片默认带源片音轨。留这一档是给「编码器不收料」那条排查用的对照：关掉就只挂视频输入。
    @Published var withAudio = true
    @Published var fullRunning = false
    @Published var stopPressed = false
    /// 「删除历史视频」的第一击只列清单、置 armed；第二击才真删
    @Published var cleanArmed = false
    @Published var cleanTargets: [URL] = []
    @Published var cleanMB = 0.0
    private var ticker: Timer?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        VRJournal.line("=== 启动 v\(info["CFBundleShortVersionString"] ?? "-") ===")
        VRPressure.start()
        // 「全片跑到一半没账了」得先分清是不是被挂起：11-06 17:01 那条第 31 帧报 Operation Interrupted，
        // 前面正好空了 98 秒一行没出。这四个通知谁来了都记一行，下次一看就知道。
        for (one, tag) in [(UIApplication.willResignActiveNotification, "失活跃（锁屏/下拉/切走）"),
                           (UIApplication.didEnterBackgroundNotification, "进后台"),
                           (UIApplication.didBecomeActiveNotification, "变活跃"),
                           (UIApplication.willEnterForegroundNotification, "回前台")] {
            NotificationCenter.default.addObserver(forName: one, object: nil, queue: .main) { _ in
                VRJournal.line("前台 \(tag)")
            }
        }
    }

    /// 跑片期间把「屏幕自己黑掉」这条路堵上：屏一黑系统就挂起我们，AVAssetWriter 当场
    /// Operation Interrupted，这条片子就废了（11-06 那次正是这么没跑完）。finish() 里必还回去。
    /// ⚠️ 播放页的 attach/teardown 也动同一个开关；两条本来就被 playGate/VRFull.isBusy 互斥挡着。
    private func keepAwake(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
        VRJournal.line("常亮 \(on ? "跑片期间不许自动锁屏" : "还给系统")")
    }

    static func unit(_ tag: Int) -> MLComputeUnits {
        switch tag {
        case 1: return .cpuAndGPU
        case 2: return .cpuAndNeuralEngine
        case 3: return .cpuOnly
        default: return .all
        }
    }

    func finish(_ report: String, pickCopy: URL? = nil) {
        ticker?.invalidate()
        ticker = nil
        fullRunning = false
        keepAwake(false)
        log.append(report)
        if log.count > 8 { log.removeFirst(log.count - 8) }
        busy = false
        status = ""
        VRJournal.line("界面 " + report.replacingOccurrences(of: "\n", with: " ／ "))
        dropPickCopy(pickCopy)
    }

    /// 源片副本一跑完就删。它进 app 自己的 tmp 只为了躲开「回调一返回系统就回收」，
    /// 留着就是你 10-12 在 LC 的 Data/Application/*/tmp 里看到的那些 vr3d_*.mov。
    func dropPickCopy(_ url: URL?) {
        guard let url = url else { return }
        guard url.path.hasPrefix(FileManager.default.temporaryDirectory.path + "/") else {
            log.append("源片副本不在临时目录，不动它：\(url.path)")
            return
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let mb = Double(bytes) / 1_048_576
        if (try? FileManager.default.removeItem(at: url)) != nil {
            VRJournal.line("清副本 删掉源片副本 \(url.lastPathComponent) \(String(format: "%.1f", mb)) MB")
        } else {
            log.append("源片副本没删掉：\(url.path)")
            VRJournal.line("清副本 没删掉 \(url.path)")
        }
    }

    func tapClean() {
        if busy || VRFull.isBusy() {
            log.append("有一条在跑，历史先不动（跑完会自动清它自己那份）。进度：\(status)")
            return
        }
        if cleanArmed {
            var n = 0, fail = 0, mb = 0.0
            for one in cleanTargets {
                let sz = Double((try? one.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / 1_048_576
                if (try? FileManager.default.removeItem(at: one)) != nil { n += 1; mb += sz } else { fail += 1 }
            }
            cleanArmed = false
            cleanTargets = []
            cleanMB = 0
            let msg = "删除历史 删掉 \(n) 个，释放 \(String(format: "%.1f", mb)) MB"
                + (fail > 0 ? "，\(fail) 个没删掉" : "")
            log.append(msg)
            VRJournal.line(msg)
            return
        }
        // 只认 vr3d_ 前缀：别 app 落在同一个容器里的文件一律不碰
        var items: [URL] = []
        let fm = FileManager.default
        var dirs = [fm.temporaryDirectory]
        dirs += fm.urls(for: .documentDirectory, in: .userDomainMask)
        for dir in dirs {
            items += ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("vr3d_") }
        }
        cleanTargets = items
        cleanMB = items.reduce(0.0) {
            $0 + Double((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / 1_048_576
        }
        guard !items.isEmpty else {
            cleanArmed = false
            log.append("删除历史 没找到可删的（源片副本、深度缓存、成片都是空的）")
            VRJournal.line("删除历史 没找到可删的")
            return
        }
        cleanArmed = true
        let names = items.prefix(6).map { $0.lastPathComponent }.joined(separator: "、")
            + (items.count > 6 ? " 等 \(items.count) 个" : "")
        log.append("删除历史 找到 \(items.count) 个，共 \(String(format: "%.1f", cleanMB)) MB：\(names)\n再点一次「确认删除」才真删")
        VRJournal.line("删除历史 预备 \(items.count) 个 \(String(format: "%.1f", cleanMB)) MB")
    }

    func cancelClean() {
        cleanArmed = false
        cleanTargets = []
        cleanMB = 0
    }

    func startCheck() {
        busy = true
        status = "环境自检中…（Metal + 色彩往返 + 白线实验）"
        Task.detached { [weak self] in
            let r = VRCheck.all()
            await MainActor.run { self?.finish(r) }
        }
    }

    func startProbe() {
        busy = true
        status = "深度自检中…（四单元各加载一遍＋预热 5＋正式 30 次；带 ANE 的两个单元各自加载要 2 分钟，整轮实测 345 s）"
        Task.detached { [weak self] in
            let r = VRDepth.probe(runs: 30)
            await MainActor.run { self?.finish(r) }
        }
    }

    func startPilot(_ url: URL) {
        showVideoPicker = false
        busy = true
        let n = frames
        let eye = eyeLong
        let b = Float(bpct)
        let u = VRJob.unit(unitTag)
        let rot = feedRot
        let rn = rot ? "转90°" : "摆正"
        VRPressure.reset()
        keepAwake(true)
        status = "出试片中…（抽 \(n) 帧 × 3 个零视差面；送检\(rn)；深度单元 \(VRPilot.unitsName(u))，单价见上方实测那行）"
        Task.detached { [weak self] in
            let r = VRPilot.run(url: url, frames: n, bpct: b, eyeLong: eye,
                                zps: [0.15, 0.50, 0.85], outFps: 5.0, units: u, rot: rot)
            await MainActor.run { self?.finish(r, pickCopy: url) }
        }
    }

    func startFull(_ url: URL) {
        showVideoPicker = false
        busy = true
        fullRunning = true
        stopPressed = false
        let b = Float(bpct)
        let eye = eyeLong
        let u = VRJob.unit(unitTag)
        let rot = feedRot
        let zps: [Float] = fullZps == 3 ? [0.15, 0.50, 0.85] : [0.15]
        VRFull.wantAudio = withAudio
        VRPressure.reset()
        keepAwake(true)
        status = "全片起手…（读几何、载模型、过磁盘闸门）"
        ticker = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.busy else { return }
                let p = VRFull.progress
                guard !p.isEmpty else { return }
                self.status = (VRFull.cancelRequested ? "正在收兵｜" : "") + p
            }
        }
        Task.detached { [weak self] in
            let r = VRFull.run(url: url, bpct: b, eyeLong: eye, zps: zps, smooth: 0.4, units: u, rot: rot)
            await MainActor.run { self?.finish(r, pickCopy: url) }
        }
    }

    func stopFull() {
        VRFull.requestCancel()
        stopPressed = true
        status = "正在收兵：把手上这一帧/这一条做完就停，已扫的深度和已出的成片照样报"
    }

    /// 两条播放都要先确认没别的在跑：相册那条虽然不跑深度，可它一样要发 Metal 指令（半幅平移），
    /// 跟全片并发就是 10-10 那次闪退的同一个坑。
    private func playGate(_ tag: String) -> Bool {
        guard !(busy || VRFull.isBusy() || VRLive.isBusy()) else {
            log.append("有一条在跑，\(tag)不起（两条共用那份 Metal 地基）。进度：\(status.isEmpty ? "刚起手" : status)")
            return false
        }
        return true
    }

    func pickForPlayback() {
        guard playGate("相册左右眼播放") else { return }
        pickPurpose = 1
        showVideoPicker = true
    }

    func pickForLive() {
        guard playGate("实时左右眼播放") else { return }
        pickPurpose = 2
        showVideoPicker = true
    }

    /// 把播放页呈现出去。两条去向（相册里已是左右眼的、要实时形变的）都进同一个页，靠 sbs 分野。
    private func openLive(_ url: URL) {
        let ok = VRPage.present(url: url, eyeLong: eyeLong, bpct: Float(bpct),
                                units: VRJob.unit(unitTag), rot: feedRot, sbs: liveSbs) { r in
            self.liveEnd(r)
        }
        if ok {
            log.append("播放页已呈现（转屏由这一页自己说：竖+左横+右横）")
        } else {
            log.append("播放页没开起来：找不到窗口根控制器（详情见日志「页面」那几行）")
            dropPickCopy(url)
            liveCopy = nil
        }
    }

    /// 实时页收兵后由 VRLive 把报告送回这里：关页面、进日志、删那份 tmp 副本
    func liveEnd(_ report: String) {
        VROrientation.allowLandscape(false)
        log.append(report)
        if log.count > 8 { log.removeFirst(log.count - 8) }
        VRJournal.line("界面 " + report.replacingOccurrences(of: "\n", with: " ／ "))
        dropPickCopy(liveCopy)
        liveCopy = nil
    }

    func finishPick(url: URL?, failMessage: String?) {
        showVideoPicker = false
        guard let url = url else {
            log.append("取文件失败\n\(failMessage ?? "未知原因")")
            return
        }
        // 播放器这两条不跑转换：去向在选择那一刻就记下了，回来只负责把同一个全屏页撑开（liveSbs 分野）
        if pickPurpose == 1 || pickPurpose == 2 {
            let asIs = pickPurpose == 1
            pickPurpose = 0
            guard playGate(asIs ? "相册左右眼播放" : "实时左右眼播放") else {
                dropPickCopy(url)
                return
            }
            liveSbs = asIs
            liveCopy = url
            openLive(url)
            return
        }
        // 选片回调是异步的：拷一条一分钟的片子要好几秒，这期间按钮的 busy 还没置上，
        // 再点一次就会有两段回调前后落到这里（10-10 22:27 就是这么起了两条全片、约 90 秒后闪退）。
        // 界面的 busy 会在视图重建时丢；闸在 run() 入口那份带锁的状态上，问它才算数
        if busy || VRFull.isBusy() {
            log.append("已经有一条在跑，这条选片不算（进度：\(status)）。要换片先按「停止」。")
            return
        }
        // 上一次跑一半闪退/直接退出的，finish 永远等不到 ⇒ 这里补删。只认自己那份前缀，别的不碰
        let fm = FileManager.default
        var staleN = 0, staleMb = 0.0
        for one in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory,
                    includingPropertiesForKeys: [.fileSizeKey], options: [])) ?? []
            where one.lastPathComponent.hasPrefix("vr3d_") && one.path != url.path {
            let sz = (try? one.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if (try? fm.removeItem(at: one)) != nil { staleN += 1; staleMb += Double(sz) / 1_048_576 }
        }
        if staleN > 0 {
            log.append("选片 顺带删掉上几轮留下的 \(staleN) 个源片副本，释放 \(String(format: "%.1f", staleMb)) MB")
            VRJournal.line("选片 补删上几轮副本 \(staleN) 个 \(String(format: "%.1f", staleMb)) MB")
        }
        if fullMode { startFull(url) } else { startPilot(url) }
    }

    func sendReport() {
        busy = true
        status = "正在发往电脑…"
        let text = VRFacts.lines().joined(separator: "\n") + "\n\n"
            + log.joined(separator: "\n\n")
            + "\n\n—— 磁盘日志最近 150 行 ——\n" + VRJournal.tail(150)
        Task.detached { [weak self] in
            let r = VRUploader.send(text)
            await MainActor.run { self?.finish(r) }
        }
    }
}

struct VRPickerHost: UIViewControllerRepresentable {
    let onDone: (URL?, String?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .videos
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onDone: (URL?, String?) -> Void

        init(_ onDone: @escaping (URL?, String?) -> Void) { self.onDone = onDone }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                done(nil, "没选到文件")
                return
            }
            provider.loadFileRepresentation(forTypeIdentifier: "public.movie") { file, error in
                guard let file = file else {
                    self.done(nil, "loadFileRepresentation 返回空: \(error?.localizedDescription ?? "-")")
                    return
                }
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("vr3d_\(UUID().uuidString.prefix(8))")
                    .appendingPathExtension(file.pathExtension)
                do {
                    if FileManager.default.fileExists(atPath: dst.path) {
                        try FileManager.default.removeItem(at: dst)
                    }
                    try FileManager.default.copyItem(at: file, to: dst)
                    self.done(dst, nil)
                } catch {
                    self.done(nil, "拷贝到临时目录失败: \(error)")
                }
            }
        }

        private func done(_ url: URL?, _ failMessage: String?) {
            let onDone = self.onDone
            Task { @MainActor in onDone(url, failMessage) }
        }
    }
}
