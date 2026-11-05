//
//  PageViewController.swift
//  手机上看到的就是 PC 那份页面：WKWebView 直接加载 http://<PC>:5100/，
//  登录页、换脸/剪辑两个 tab、结果视频流、特征管理、录像按钮全部原样，一个控件都不新画。
//
//  原生只补浏览器做不到的事：从相册挑片（走页面上传会变成整片 POST，首帧等待又回来）、
//  手机硬解出帧推给 PC、以及 PC 掉出推流模式以后的重连。接法是在页面已有按钮的
//  捕获阶段拦一手，状态一律写回页面自己的那一行 showStatus——不盖浮标，不加按钮。
//

import AVFoundation
import CoreGraphics
import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

final class PageViewController: UIViewController {
    private var webView: WKWebView!
    private var client: SwapClient?
    private let video = VideoFrameSource()

    private enum Phase {
        case none       // 没选片
        case loaded     // 选了片，没在推
        case pushing    // 正在推流
        case paused     // 退到后台停住了，回前台自动接着推
    }
    private var phase: Phase = .none
    private var resumeSeconds: Double = 0
    private var greetedHost = ""

    private var meterTimer: Timer?
    private var lastSentSample = 0
    private var lastSentTick: TimeInterval = 0
    private var lastWarnKey = ""
    private var lastWarnTick: TimeInterval = 0
    /// 屏幕不动时补一次 /video_feed 重连的节流。页面 30 秒盲刷已经在注入脚本里关掉，
    /// 这条是它之外唯一的兜底：长连接断掉时 WebView 不一定报 error。
    private var lastFeedRefresh: TimeInterval = 0
    /// 目标脸没换的解释 12 秒最多说一次：页面自己的目标脸状态行每秒都在刷新，不用跟着刷屏。
    private var lastPlanHintTick: TimeInterval = 0
    /// 没存过地址时要在界面出现以后才能弹框：viewDidLoad 里 present 会被系统
    /// 静默拒绝（那时还没进窗口），表现就是一片黑、连填地址的输入框都看不到。
    private var pendingAddressPrompt = false

    // PC 掉出推流模式（10 秒空闲看门狗、重启服务）后的重连计数
    private var restartTries = 0
    private var lastRestartTick: TimeInterval = 0
    private var lastSeen409 = 0
    /// 每次用户停推/退后台/换地址都自增：await 回来以后靠它认出「这一次已经作废了」，
    /// 免得后台的 startLive 回来把用户刚停掉的流又 resurrect 起来。
    private var pushGen = 0

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildWebView()
        wireVideoSource()

        let press = UILongPressGestureRecognizer(target: self, action: #selector(openAddressSheet(_:)))
        press.minimumPressDuration = 1.5
        press.cancelsTouchesInView = false
        webView.addGestureRecognizer(press)

        NotificationCenter.default.addObserver(
            self, selector: #selector(resignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(becomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)

        loadPage()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if pendingAddressPrompt {
            pendingAddressPrompt = false
            openAddress(storedHost())
        }
        // 兜底：2.5 秒后页面仍然一个 URL 都没加载、也没东西在弹，说明卡在了空白态，
        // 直接把地址框顶上来——总比让人对着一片黑不知道点哪儿好。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self,
                  self.webView.url == nil,
                  self.presentedViewController == nil else { return }
            self.openAddress(self.storedHost())
        }
    }

    deinit {
        meterTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: LiveConfig.bridgeName)
    }

    /// 手机不能一边在后台一边解 1080p 还指望它推帧：先停手，把 PC 的锁也放开。
    @objc private func resignActive() {
        guard phase == .pushing else { return }
        pushGen += 1
        video.stop()
        resumeSeconds = clampSeconds(CMTimeGetSeconds(video.currentPTS))
        stopMeter()
        phase = .paused
        let c = client
        Task { await c?.stopLive() }
        status("手机退到后台，已停推流；回前台会自己接着推")
    }

    /// 回前台先问一次 /live_status：PC 那 10 秒空闲看门狗多半已经把推流模式关掉了。
    @objc private func becomeActive() {
        guard phase == .paused, video.hasClip else { return }
        guard let client = client else { phase = .loaded; return }
        let from = resumeSeconds
        let gen = pushGen
        Task { @MainActor in
            guard gen == self.pushGen else { return }
            let snap = await client.fetchStatusOnce()
            guard gen == self.pushGen else { return }
            if snap?.liveMode == true {
                // PC 还认这次推流：直接接着出帧，省掉一次会清空检测缓存的 startLive
                self.resumePushing(from: from, reason: "回到前台", needStart: false, manual: true)
            } else {
                self.resumePushing(from: from, reason: "回到前台，PC 已退出推流模式", manual: true)
            }
        }
    }

    // MARK: - 建视图

    private func buildWebView() {
        let cfg = WKWebViewConfiguration()
        cfg.applicationNameForUserAgent = LiveConfig.userAgentSuffix
        cfg.userContentController.add(self, name: LiveConfig.bridgeName)
        cfg.userContentController.addUserScript(
            WKUserScript(source: LiveShim.source(),
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true))

        // 用约束钉四边而不是拿 view.bounds 当初始 frame：viewDidLoad 时 bounds 可能是 0，
        // 靠 autoresizing 要等父视图尺寸变化那一下才跟着变，万一没变就是个永远 0×0 的空白页。
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        webView = web
    }

    private func wireVideoSource() {
        video.jpegQuality = LiveConfig.jpegQuality
        video.pushFPS = LiveConfig.pushFPS
        video.onJPEG = { [weak self] jpeg in
            self?.client?.push(jpeg)
        }
        video.onError = { [weak self] msg in
            DispatchQueue.main.async { self?.status(msg, "error") }
        }
        video.onSegmentEnd = { [weak self] in
            guard let self = self else { return }
            self.pushGen += 1
            self.phase = .loaded
            self.resumeSeconds = 0
            self.stopMeter()
            let c = self.client
            Task { await c?.stopLive() }
            self.status("这一段推完了：再点「播放」从头重推，或选另一段")
        }
    }

    private func loadPage() {
        guard let text = storedHost(), let base = LiveHost.base(text) else {
            // 第一次启动：等 viewDidAppear 再弹，这时才进得了窗口
            pendingAddressPrompt = true
            return
        }
        connect(to: base)
    }

    private func connect(to base: URL) {
        let c = SwapClient(baseURL: base)
        client = c
        pushGen += 1
        phase = .none
        resumeSeconds = 0
        greetedHost = ""
        restartTries = 0
        webView.load(URLRequest(url: base))
    }

    // MARK: - 状态写回页面

    private func status(_ msg: String, _ kind: String = "success") {
        let js = "window.LiveUI && window.LiveUI.status(\(LiveShim.jsLiteral(msg)), "
            + "\(LiveShim.jsLiteral(kind)))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func setPath(_ value: String) {
        let js = "window.LiveUI && window.LiveUI.path(\(LiveShim.jsLiteral(value)))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func readPath(_ then: @escaping (String?) -> Void) {
        let js = "window.LiveUI ? window.LiveUI.readPath() : null"
        webView.evaluateJavaScript(js) { obj, _ in
            then(obj as? String)
        }
    }

    // MARK: - 三条挂子的原生侧

    private func onPick() {
        var cfg = PHPickerConfiguration()
        cfg.selectionLimit = 1
        cfg.filter = .videos
        cfg.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func onPlay() {
        switch phase {
        case .pushing:
            stopPush("已停止推流（再点一次「播放」接着推）")
        case .paused:
            resumePushing(from: resumeSeconds, reason: "接着推", manual: true)
        default:
            startPush()
        }
    }

    private func startPush() {
        guard video.hasClip else {
            status("先点「选择视频文件」从相册里挑一段", "error")
            return
        }
        guard client != nil else {
            status("还没连上 PC：屏幕长按 1.5 秒填地址", "error")
            return
        }
        resumePushing(from: resumeSeconds, reason: "开始", manual: true)
    }

    /// 起播/重连共用这一条：先要到推流模式，再让 reader 从指定点开始出帧。
    /// needStart=false 用在「PC 还认这次推流」的场景，省掉一次会清空检测缓存的 startLive。
    /// manual=true 是用户自己按的：不看重连次数上限，也不被两次之间的间隔拦住。
    private func resumePushing(from seconds: Double, reason: String,
                               needStart: Bool = true, manual: Bool = false) {
        guard let client = client else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if needStart && !manual && restartTries >= LiveConfig.maxRestartTries {
            status("自动重连试到 \(restartTries) 次都没进得去：查那台电脑的换脸服务在不在跑"
                   + "（刚重启后模型加载要等一会儿），好了再点「播放」", "error")
            restartTries = 0
            return
        }
        if !manual && now - lastRestartTick < LiveConfig.restartGapSeconds { return }
        lastRestartTick = now
        if manual { restartTries = 0 }
        if needStart { restartTries += 1 }
        let gen = pushGen
        status(needStart
               ? "\(reason)：正在接上 PC 的推流模式…"
               : "\(reason)：PC 还在推流模式，直接接着出帧…")

        Task { @MainActor in
            if needStart {
                do {
                    let w = try await client.startLive()
                    video.targetWidth = w
                    await client.seek()
                } catch {
                    guard gen == self.pushGen else { return }
                    let msg = (error as? SwapError)?.message ?? error.localizedDescription
                    self.status("进不了推流模式：\(msg)（第 \(self.restartTries) 次）", "error")
                    return
                }
            }
            guard gen == self.pushGen else { return }
            guard self.video.start(from: CMTime(seconds: seconds, preferredTimescale: 600)) else {
                self.phase = .loaded
                self.stopMeter()
                if needStart { await client.stopLive() }
                return            // 起不来的原因 video 已经通过 onError 报过了
            }
            self.phase = .pushing
            self.lastSeen409 = client.saw409
            self.lastWarnKey = ""
            self.startMeter()
            self.status("手机推流中：从 \(LiveTime.clock(seconds)) 起，"
                        + "宽 \(self.video.targetWidth)、\(Int(self.video.pushFPS))fps")
        }
    }

    private func onSeek() {
        readPath { [weak self] raw in
            guard let self = self else { return }
            guard let text = raw, let seconds = LiveTime.parse(text) else {
                // 这一格在 PC 上是「视频路径」，在手机上只是跳转输入：手机上片子是本地挑的，
                // 把名字当路径发回 PC 只会吃一次 409/400，所以不代跑页面那个 setVideoPath()
                self.status("手机上这一格只当跳转输入用：填 秒数或 mm:ss 再按回车＝跳到那儿；"
                            + "换一段片子点「选择视频文件」", "error")
                return
            }
            guard self.phase != .none else {
                self.status("还没选视频，跳转没有意义", "error")
                return
            }
            let dur = CMTimeGetSeconds(self.video.duration)
            if dur.isFinite, seconds >= dur {
                self.status("跳到 \(LiveTime.clock(seconds)) 超出这一片长度 \(LiveTime.clock(dur))",
                            "error")
                return
            }
            self.resumeSeconds = seconds
            let c = self.client
            let wasPaused = self.phase == .paused
            Task { @MainActor in
                await c?.seek()
                if self.phase == .pushing || self.phase == .paused {
                    // AVAssetReader 开始读以后不能 seek：停手、换 timeRange 重建
                    self.pushGen += 1
                    self.video.stop()
                    self.resumePushing(from: seconds, reason: "跳到 \(LiveTime.clock(seconds))",
                                       needStart: wasPaused, manual: true)
                } else {
                    self.status("已记下起播点 \(LiveTime.clock(seconds))，点「播放」从这儿开始推")
                }
            }
        }
    }

    private func stopPush(_ note: String) {
        pushGen += 1
        video.stop()
        resumeSeconds = clampSeconds(CMTimeGetSeconds(video.currentPTS))
        phase = .loaded
        stopMeter()
        restartTries = 0
        let c = client
        Task { await c?.stopLive() }
        status(note)
    }

    private func clampSeconds(_ s: Double) -> Double {
        guard s.isFinite, s > 0 else { return 0 }
        return s
    }

    // MARK: - 每秒账目与看门狗

    private func startMeter() {
        meterTimer?.invalidate()
        lastSentSample = client?.framesSent ?? 0
        lastSentTick = CFAbsoluteTimeGetCurrent()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func tick() {
        guard let client = client, phase == .pushing else { return }
        let sent = client.framesSent
        let now = CFAbsoluteTimeGetCurrent()
        let span = max(0.001, now - lastSentTick)
        let fps = Double(sent - lastSentSample) / span
        lastSentSample = sent
        lastSentTick = now
        if fps > 0.5 { restartTries = 0 }        // 帧在走就算连上了，重连计数归零

        // 会话失效：PC 把每一帧都弹回登录页，跟随后拿到的是 200 的 HTML，
        // 光看状态码就是「帧在走」。这条得排在重连前面——重连也进不去，只会白试三轮。
        if client.sessionLost {
            video.stop()
            resumeSeconds = clampSeconds(CMTimeGetSeconds(video.currentPTS))
            stopMeter()
            phase = .loaded
            let c = client
            Task { await c.stopLive() }
            status(LiveAuth.lostMessage, "error")
            return
        }
        // 恢复路径①：PC 判了 409 或 /live_status 报 live_mode=false，都意味着必须重新 /live_start
        if client.saw409 != lastSeen409 || !client.pcLiveMode {
            lastSeen409 = client.saw409
            video.stop()
            resumeSeconds = clampSeconds(CMTimeGetSeconds(video.currentPTS))
            stopMeter()
            phase = .loaded
            resumePushing(from: resumeSeconds, reason: "PC 退出了推流模式")
            return
        }
        if let err = client.lastError, warnOnce("err:" + err) {
            status(err, "error")
        }
        // 手机在推、PC 不出帧：那边进程崩了（这条只报警，不停手——停手是上面那条的事）。
        // 前提是这一秒手机确实在发帧：自己刚停手、刚拖完进度条重建 reader 的那一秒不出帧，
        // 不该报成 PC 挂了。
        if LiveWatch.stalled(outputAgeMs: client.outputAgeMs, localFPS: fps),
           let age = client.outputAgeMs {
            // 只报警不够：屏幕那条 MJPEG 长连接可能已经断了，PC 再出帧也看不到。
            // 重连一次；全屏那份是页面克隆出来的 img，注入脚本也一并换掉它的地址。
            refreshFeedInPage()
            if warnOnce("age") {
                status("手机在推、PC 有 \(age)ms 没出帧了：查那台电脑的换脸进程还在不在", "error")
            }
        }
        // 冷启动预热期 PC 入口队列会一次性丢一大批帧，那不是故障，所以只进这一行账目、不报警
        if warnOnce("fps", every: 10.0) {
            // 模型还没加载完时 PC 一帧输出都没有（frames_in 在涨、output 是 null）：
            // 空着不说明，手机上看到的就是「点了没画面」，最容易当成连坏了。
            // 判据是 output_age_ms：has_output 热态下一直为 true（上一轮的 latest_frame 还挂着），
            // 拿它判首帧会得出「0.0s」这种假读数。这句只是说明，不是超时。
            let warm = LiveWatch.warm(outputAgeMs: client.outputAgeMs)
                ? "" : "PC 这会儿没出帧（刚起播、刚跳转或模型还没加载完）｜"
            status(warm + "手机 \(String(format: "%.1f", fps))fps｜本地丢帧 \(client.framesDroppedLocal)"
                    + "｜PC 拒 \(client.framesRejected)｜PC 收到 \(client.pcFramesIn)、"
                    + "预热丢 \(client.pcFramesDropped)"
                    + "｜屏幕长按 1.5 秒改 PC 地址")
        }
        // 配了目标脸却一张没换：用 PC 下发的 best_sim/match_thr 说清是“不是同一个人”
        // 还是“照片太小太糊”。老 PC 没有这两个字段时 PlanHint 返回 nil，不猜也不报警。
        // 空表不是故障（PC 本来就不换），别用报错的红色。
        if let hint = PlanHint.explain(planCount: client.planCount,
                                       swappedFaces: client.swappedFaces,
                                       bestSim: client.bestSim,
                                       matchThr: client.matchThr),
           now - lastPlanHintTick >= 12 {
            lastPlanHintTick = now
            status(hint, client.planCount == 0 ? "success" : "error")
        }
    }

    /// 同一句话别刷屏：同 key 两次播报最少隔 every 秒
    private func warnOnce(_ key: String, every: Double = 6.0) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if key == lastWarnKey && now - lastWarnTick < every { return false }
        lastWarnKey = key
        lastWarnTick = now
        return true
    }

    /// 让页面重连 /video_feed，全屏克隆出来那份也换一次地址。
    /// 8 秒内最多一次：看门狗每秒都在算，停着不等于每秒都要弹一条新长连接。
    private func refreshFeedInPage() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFeedRefresh >= 8 else { return }
        lastFeedRefresh = now
        webView.evaluateJavaScript("""
        (function () {
          try { if (window.LiveUI && LiveUI.refreshStream) LiveUI.refreshStream(); } catch (e) {}
          var f = document.getElementById('fullscreen-video');
          if (f) f.src = '/video_feed?t=' + Date.now();
        })();
        """)
    }

    // MARK: - PC 地址那一格

    private func storedHost() -> String? {
        let s = UserDefaults.standard.string(forKey: "pcBase")
        return (s?.isEmpty == false) ? s : nil
    }

    @objc private func openAddressSheet(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        openAddress(storedHost())
    }

    private func openAddress(_ prefill: String?) {
        // 已经有东西在弹（比如连不上又弹一次）就不叠第二个，否则 iOS 会拒绝并且什么都不显示
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "PC 地址",
                                      message: "局域网里那台跑换脸的电脑，例："
                                             + LiveConfig.suggestedHost,
                                      preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = prefill ?? LiveConfig.suggestedHost
            tf.placeholder = LiveConfig.suggestedHost
            tf.keyboardType = .URL
            tf.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "连接", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let text = alert.textFields?.first?.text ?? ""
            guard let base = LiveHost.base(text) else {
                self.status("地址读不出：[\(text)]", "error")
                // 这个回调里弹窗还在退场，直接 present 会被上面那条 guard 挡掉；
                // 挪到主队列下一拍，等它真的退干净
                DispatchQueue.main.async { self.openAddress(text) }
                return
            }
            UserDefaults.standard.set(base.absoluteString, forKey: "pcBase")
            self.connect(to: base)
        })
        if prefill != nil {
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        }
        present(alert, animated: true)
    }

    // MARK: - 相册文件落到本地

    private func incomingDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LiveIn")
        let fm = FileManager.default
        try? fm.removeItem(at: dir)         // 一条片子几百 MB，只留当前这条
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadMovie(from provider: NSItemProvider) {
        let id = movieIdentifier(in: provider)
        status("正在把这一片取到手机本地…")
        provider.loadFileRepresentation(forTypeIdentifier: id) { [weak self] src, err in
            guard let self = self else { return }
            guard let src = src else {
                let why = (err as NSError?)?.localizedDescription ?? "读不到内容"
                DispatchQueue.main.async { self.status("取文件失败：\(why)", "error") }
                return
            }
            let safe = src.lastPathComponent
                .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
                .joined(separator: "_")
            let dst = self.incomingDirectory().appendingPathComponent(safe)
            do {
                // 这个临时文件在回调返回后就没了，必须先拷走再解
                try FileManager.default.copyItem(at: src, to: dst)
            } catch {
                DispatchQueue.main.async {
                    self.status("拷不进手机：\(error.localizedDescription)", "error")
                }
                return
            }
            DispatchQueue.main.async { self.useClip(dst, name: safe) }
        }
    }

    private func movieIdentifier(in provider: NSItemProvider) -> String {
        for id in provider.registeredTypeIdentifiers {
            // UTType(identifier:) 这个标签不存在，正确的初始化器是 UTType("public.movie") 这种
            if let t = UTType(id), t.conforms(to: .movie) { return id }
        }
        return UTType.movie.identifier
    }

    private func useClip(_ url: URL, name: String) {
        video.load(url: url)
        guard video.hasClip else { return }     // load 里已经通过 onError 报过了
        pushGen += 1
        phase = .loaded
        resumeSeconds = 0
        restartTries = 0
        setPath(name)
        let dur = CMTimeGetSeconds(video.duration)
        let durText = dur.isFinite ? LiveTime.clock(dur) : "-"
        let size = video.naturalSize
        status("已选中 \(name)（\(durText)·\(Int(size.width))×\(Int(size.height))）："
               + "点「播放」开始推流｜那一格里输 秒数或 mm:ss 再按回车 = 跳到那儿")
    }
}

// MARK: - 页面与原生之间

extension PageViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == LiveConfig.bridgeName,
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case LiveShim.hookPick:
            onPick()
        case LiveShim.hookPlay:
            onPlay()
        case LiveShim.hookSeek:
            onSeek()
        case LiveShim.hookReady:
            let hooks = body["hooks"] as? [String: Bool] ?? [:]
            let missing = LiveShim.actionNames.filter { hooks[$0] != true }
            if !missing.isEmpty {
                status("界面对不上：缺 \(missing.joined(separator: "、")) 这几个按钮"
                       + "（PC 那边改过页面？）", "error")
            }
        default:
            break
        }
    }
}

// MARK: - 导航与 cookie

extension PageViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let client = client else { return }
        client.importCookies(from: webView.configuration.websiteDataStore.httpCookieStore) { [weak self] in
            guard let self = self else { return }
            let host = LiveHost.display(client.baseURL)
            guard self.greetedHost != host else { return }
            self.greetedHost = host
            let onLogin = webView.url?.path.hasPrefix("/login") == true
            if onLogin {
                self.status("已连上 \(host)：先在这儿登录（这就是 PC 的登录页）｜屏幕长按 1.5 秒可改地址")
            } else {
                self.status("已连上 \(host)：点「选择视频文件」挑一段，再点「播放」｜屏幕长按 1.5 秒可改地址")
            }
        }
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        reportFailure(error)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        reportFailure(error)
    }

    private func reportFailure(_ error: Error) {
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled else { return }
        let host = client.map { LiveHost.display($0.baseURL) } ?? "（没地址）"
        status("连不上 \(host)：\(ns.localizedDescription)｜确认手机和电脑在同一张网，"
               + "并且这台手机的「本地网络」权限是开的", "error")
        openAddress(storedHost())
    }
}

// MARK: - 页面里的 alert/confirm/prompt：浏览器会弹，App 里得自己接

extension PageViewController: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { tf in tf.text = defaultText }
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        present(alert, animated: true)
    }
}

// MARK: - 相册挑片

extension PageViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        loadMovie(from: provider)
    }
}

// MARK: - SwiftUI 入口

struct RootView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PageViewController {
        PageViewController()
    }

    func updateUIViewController(_ uiViewController: PageViewController, context: Context) {}
}

@main
struct LiveApp: App {
    var body: some Scene {
        WindowGroup {
            RootView().ignoresSafeArea()
        }
    }
}
