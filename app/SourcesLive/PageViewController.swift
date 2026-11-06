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
    private var phaseName: String {
        switch phase {
        case .none: return "没选片"
        case .loaded: return "已选片"
        case .pushing: return "推流中"
        case .paused: return "后台暂停"
        }
    }
    private var stopGateName: String {
        switch stopGate {
        case .idle: return "待命"
        case .stopping: return "停止中"
        case .failed: return "停止失败"
        }
    }
    /// 崩溃补发只试一次：PC 没开的时候不必每次回前台都撞。
    private var crashUploadTried = false
    private var resumeSeconds: Double = 0
    private var greetedHost = ""
    /// 页面给 <html> 加 .fs 时置 true：原生藏状态栏/Home 指示条，横屏铺满。
    private var pageFullscreen = false
    /// MJPEG 没有声音，原声在手机上跟播；对齐量见 LiveAudio。
    private let audio = ClipAudio()
    /// PC 还没出过新鲜帧（冷启动模型在加载）：声音先不响，等 tick 看到第一帧再对当前画面起播。
    private var audioWaitingForOutput = false

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
    /// 下载落点：WKDownload 完成时只回传对象本身，路径得自己在决定落点时记下来。
    private var downloadTargets: [ObjectIdentifier: URL] = [:]

    // PC 掉出推流模式（10 秒空闲看门狗、重启服务）后的重连计数
    private var restartTries = 0
    private var lastRestartTick: TimeInterval = 0
    private var lastSeen409 = 0
    /// 每次用户停推/退后台/换地址都自增：await 回来以后靠它认出「这一次已经作废了」，
    /// 免得后台的 startLive 回来把用户刚停掉的流又 resurrect 起来。
    private var pushGen = 0

    /// 停止握手：点停止到 PC 确认之间，按钮和特征下拉框都锁着；没送到就停在 failed。
    private var stopGate: LiveStopGate = .idle
    /// 还在飞的那次 /live_stop。重开推流前必须先等它落地，否则停止可能后到、
    /// 把刚开起来的新一轮推流又关掉。
    private var pendingStop: Task<Bool, Never>?
    /// 每次停/重开都自增：旧的完成回调凭它认出自己已经作废。
    private var stopGen = 0

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification, object: nil)

        AppLog.shared.log("life", "界面起来了：版本 \(LiveConfig.appVersion)(\(LiveConfig.appBuild))")
        loadPage()
    }

    override var prefersStatusBarHidden: Bool { pageFullscreen }
    override var prefersHomeIndicatorAutoHidden: Bool { pageFullscreen }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

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
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: LiveConfig.seekBridgeName)
    }

    @objc private func appWillTerminate() {
        AppLog.shared.markCleanExit()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        AppLog.shared.log("mem", "收到系统内存警告：前台足迹 \(AppLog.footprintMB())MB")
    }

    /// 手机不能一边在后台一边解 1080p 还指望它推帧：先停手，把 PC 的锁也放开。
    @objc private func resignActive() {
        guard phase == .pushing else {
            AppLog.shared.log("life", "退到后台（\(phaseName)）")
            return
        }
        AppLog.shared.log("life", "退到后台，正在停推")
        pushGen += 1
        video.stop()
        audio.pause()
        audioWaitingForOutput = false
        resumeSeconds = clampSeconds(CMTimeGetSeconds(video.currentPTS))
        stopMeter()
        phase = .paused
        sendStopAndSettle(report: "手机退到后台，已停推流；回前台会自己接着推")
    }

    /// 回前台先问一次 /live_status：PC 那 10 秒空闲看门狗多半已经把推流模式关掉了。
    @objc private func becomeActive() {
        AppLog.shared.log("life", "回到前台（\(phaseName)）")
        guard phase == .paused, video.hasClip else { return }
        guard let client = client else { phase = .loaded; return }
        let from = resumeSeconds
        let gen = pushGen
        Task { @MainActor in
            // 退后台那一笔停止可能还在飞：先等它落地再问状态，
            // 否则拿旧读数决定 needStart，停止可能后到把新一轮推流又关掉。
            if let flying = self.pendingStop { _ = await flying.value }
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
        cfg.userContentController.add(self, name: LiveConfig.seekBridgeName)
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
            self.audio.pause()
            self.audioWaitingForOutput = false
            self.phase = .loaded
            self.resumeSeconds = 0
            self.stopMeter()
            self.pushSeek(cur: 0, total: 0)
            let avg = self.client?.averageFrameBytes ?? 0
            self.sendStopAndSettle(report: avg > 0
                ? "这一段推完了：再点「播放」从头重推，或选另一段；上行均值 \(max(1, avg / 1024)) KB/帧"
                : "这一段推完了：再点「播放」从头重推，或选另一段")
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
        AppLog.shared.log("net", "连 PC \(LiveHost.display(base))")
        let c = SwapClient(baseURL: base)
        // 页面和原生盯的是同一个 base（下面 load 的就是它），cookie 按主机匹配才不会错位；
        // store 也取这个 webView 自己的，不碰别的 WebView / 其他 app 的会话。
        c.attachCookieStore(webView.configuration.websiteDataStore.httpCookieStore)
        client = c
        pushGen += 1
        // 旧主机的停止请求还可能在飞：它属于上一个 client，这里不再等；新页面加载完
        // 会自己按 PC 的状态刷按钮和下拉框，握手锁必须先清掉。
        stopGen += 1
        pendingStop = nil
        stopGate = .idle
        // 换地址可能发生在推流中：旧 reader 会继续往新 client 发帧（没 /live_start 只会吃 409），
        // 声音也得一起停。
        video.stop()
        stopMeter()
        audio.pause()
        audioWaitingForOutput = false
        phase = .none
        resumeSeconds = 0
        greetedHost = ""
        restartTries = 0
        setPageFullscreen(false)
        pushSeek(cur: 0, total: 0)
        // 页面就是全部界面：PC 改模板后必须一次拿到新的，不能吃 WKWebView 的旧 HTML/JS，
        // 否则只能卸了重装才看得到修复。
        webView.load(URLRequest(url: base,
                                cachePolicy: .reloadIgnoringLocalCacheData,
                                timeoutInterval: 20))
    }

    // MARK: - 状态写回页面

    private func status(_ msg: String, _ kind: String = "success") {
        // 用户在屏幕上看到的那一行，日志里也要有：事后对时间线靠它。
        AppLog.shared.log(kind == "error" ? "err" : "ui", msg)
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

    /// 进度条走页面自己的容器：每秒回填当前/总长；total<=0 页面会整行收起。
    private func pushSeek(cur: Double, total: Double) {
        guard webView != nil else { return }
        let c = cur.isFinite ? max(0, cur) : 0
        let t = (total.isFinite && total > 0) ? total : 0
        let js = "window.LiveUI && window.LiveUI.setSeek && window.LiveUI.setSeek("
            + String(format: "%.3f", c) + ", " + String(format: "%.3f", t) + ")"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 页面在 change（松手）时 postMessage(秒)：推流中重建 reader；停止态只记起播点。
    private func handleSeekBar(_ body: Any) {
        let seconds: Double
        if let n = body as? NSNumber {
            seconds = n.doubleValue
        } else if let s = body as? String, let v = Double(s) {
            seconds = v
        } else {
            return
        }
        seekTo(seconds)
    }

    private func seekTo(_ raw: Double) {
        guard raw.isFinite, video.hasClip, phase != .none else { return }
        let dur = CMTimeGetSeconds(video.duration)
        let target = max(0, min(raw, dur.isFinite && dur > 0 ? max(0, dur - 0.05) : raw))
        resumeSeconds = target
        pushSeek(cur: target, total: dur)

        switch phase {
        case .pushing, .paused:
            // 和输入框回车走同一条：先停 reader，清 PC 的旧帧/旧姿势缓存，再从新 PTS 重建。
            let wasPaused = phase == .paused
            pushGen += 1
            video.stop()
            audio.pause()
            audioWaitingForOutput = false
            let c = client
            Task { @MainActor in
                await c?.seek()
                let expected: Phase = wasPaused ? .paused : .pushing
                guard self.phase == expected else { return }
                self.resumePushing(from: target, reason: "跳到 \(LiveTime.clock(target))",
                                   needStart: wasPaused, manual: true)
            }
        case .loaded:
            status("已记下起播点 \(LiveTime.clock(target))，点「播放」从这儿开始推")
        case .none:
            break
        }
    }

    /// 页面用 <html class="fs"> 表达全屏；这里只负责系统状态栏/Home 条，布局全在页面里。
    private func setPageFullscreen(_ on: Bool) {
        guard pageFullscreen != on else { return }
        pageFullscreen = on
        LiveChrome.shared.fullscreen = on
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        parent?.setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: - 三条挂子的原生侧

    private func onPick() {
        AppLog.shared.log("ui", "打开相册选片")
        var cfg = PHPickerConfiguration()
        cfg.selectionLimit = 1
        cfg.filter = .videos
        cfg.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func onPlay() {
        // 停止握手没走完，这颗按钮不许把推流又开起来：stopping 时它是灰的，
        // 正常点不到；failed 时它写着「重试停止」，点了就再送一次停止。
        switch stopGate {
        case .stopping:
            status(LiveStopGate.stoppingNote)
            return
        case .failed:
            sendStopAndSettle(report: nil)
            return
        case .idle:
            break
        }
        switch phase {
        case .pushing:
            stopPush("已停止推流（再点一次「播放」接着推）")
        case .paused:
            resumePushing(from: resumeSeconds, reason: "接着推", manual: true)
        default:
            // 有本地片才走手机推帧；没有就先问 PC，别一上来就弹相册。
            if video.hasClip {
                startPush()
            } else {
                playOnPCOrPick()
            }
        }
    }

    /// 手机还没选片时点「播放」：先问 PC 手上有没有片。
    /// 剪辑页「用于换脸」会把路径交给 PC（/set_video），这时该由 PC 自己放，
    /// 页面原有的 /start_playback 就是那条路；只有 PC 也没片才弹手机相册。
    private func playOnPCOrPick() {
        guard let client = client else {
            status("还没连上 PC：屏幕长按 1.5 秒填地址", "error")
            return
        }
        setPageBusy(true)
        Task { @MainActor in
            defer { self.setPageBusy(false) }
            let path = await client.fetchVideoPathOnce()
            guard self.client === client else { return }
            AppLog.shared.log("ui", "点播放时手机没片；PC 上的片：\(path ?? "（空）")")
            guard LivePlaySource.usesPCVideo(hasLocalClip: self.video.hasClip, pcPath: path) else {
                self.onPick()
                return
            }
            // 交回页面自己的按钮处理：播放/暂停、进度条、状态行都在页面里，原生不另造一条。
            let js = "typeof togglePlayStop === 'function' ? (togglePlayStop(), true) : false"
            self.webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self = self, (result as? Bool) != true else { return }
                self.status("PC 上已有视频，但这个页面的播放处理对不上（PC 改过页面？）", "error")
            }
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
        // 进推流模式也是一条要等 PC 回话的命令：这期间整页不接点击，
        // 否则连点会把 /live_start 和 reader 重建叠成几轮。
        setPageBusy(true)

        Task { @MainActor in
            defer { self.setPageBusy(false) }
            // 上一笔 /live_stop 还没落地就开新一轮：停止可能后到，把刚开的推流又关掉。
            if let flying = self.pendingStop { _ = await flying.value }
            guard gen == self.pushGen else { return }
            if needStart {
                // PC 的 /live_start 现在自己会把 is_playing 清掉并置 stop_requested，
                // 进推流模式不用再先补一发 /stop_playback。
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
                // 推流模式已经开起来了却出不了帧：把它停回去。走握手是因为停止也可能失败，
                // 失败时界面得停在「重试停止」，不能假装 PC 已经停了。
                if needStart {
                    self.sendStopAndSettle(report: "这一段没能起播，已把 PC 的推流模式停回去")
                }
                return            // 起不来的原因 video 已经通过 onError 报过了
            }
            self.phase = .pushing
            // 真在出帧以后才交回按钮：之前解除的话，页面会先把按钮刷成「停止」，
            // 而原生还停在 loaded，用户点下去会被当成「开始」再开一轮。
            self.disarmStopGate()
            self.lastSeen409 = client.saw409
            self.lastWarnKey = ""
            self.startMeter()
            self.pushSeek(cur: seconds, total: CMTimeGetSeconds(self.video.duration))
            self.startAudio(at: seconds, client: client)
            self.status("手机推流中：从 \(LiveTime.clock(seconds)) 起，"
                        + "宽 \(self.video.targetWidth)、\(Int(self.video.pushFPS))fps")
        }
    }

    /// 起播声音：延迟读数新鲜就直接落后 L 秒出声；PC 还没出帧（冷启动模型加载中）
    /// 就先等着，tick 看到第一帧新鲜输出再对着当前画面起播，免得声音在没画面时自己跑远。
    /// 两个 age 都还是 nil 说明这一轮还没轮询过（第一次点播放），不知道延迟不等于没画面：
    /// 按兜底值先出声，tick 拿到读数后偏得多再纠一次。
    private func startAudio(at seconds: Double, client: SwapClient) {
        if let delay = LiveAudio.measuredDelay(inputMs: client.inputAgeMs,
                                               outputMs: client.outputAgeMs) {
            audioWaitingForOutput = false
            audio.start(at: seconds, delay: delay)
        } else if client.inputAgeMs == nil && client.outputAgeMs == nil {
            audioWaitingForOutput = false
            audio.start(at: seconds, delay: LiveAudio.defaultDelay)
        } else {
            audioWaitingForOutput = true
            audio.pause()
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
                    self.audio.pause()
                    self.audioWaitingForOutput = false
                    self.resumePushing(from: seconds, reason: "跳到 \(LiveTime.clock(seconds))",
                                       needStart: wasPaused, manual: true)
                } else {
                    self.status("已记下起播点 \(LiveTime.clock(seconds))，点「播放」从这儿开始推")
                }
            }
        }
    }

    private func stopPush(_ note: String) {
        AppLog.shared.log("ui", "用户点了停止（从 \(phaseName)）")
        pushGen += 1
        video.stop()
        audio.pause()
        audioWaitingForOutput = false
        resumeSeconds = clampSeconds(CMTimeGetSeconds(video.currentPTS))
        phase = .loaded
        stopMeter()
        pushSeek(cur: 0, total: 0)
        restartTries = 0
        let avg = client?.averageFrameBytes ?? 0
        sendStopAndSettle(report: avg > 0
            ? note + "；上行均值 \(max(1, avg / 1024)) KB/帧"
            : note)
    }

    // MARK: - 停止握手

    private func pushStopUI(_ gate: LiveStopGate) {
        guard webView != nil else { return }
        let state: String
        switch gate {
        case .idle: state = ""
        case .stopping: state = LiveStopGate.stoppingState
        case .failed: state = LiveStopGate.failedState
        }
        let js = "window.LiveUI && window.LiveUI.setStopPending && "
            + "window.LiveUI.setStopPending(\(LiveShim.jsLiteral(state)))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 整页忙闸：原生这条命令（起播/跳转/停止）在等 PC 回话时，页面所有按钮都不接点击。
    /// 停止那条走 setStopPending，这里只给起播和跳转用；两路在页面里分开计数，互不覆盖。
    private func setPageBusy(_ on: Bool) {
        guard webView != nil else { return }
        let js = "window.LiveUI && window.LiveUI.setBusy && window.LiveUI.setBusy("
            + (on ? "true" : "false") + ")"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 所有「真的要把 PC 停掉」的路径都走这里：点停止、退后台、这一段放完。
    /// 先把界面锁上再发请求；PC 回成功才解，失败停在「重试停止」等用户再送一次。
    private func sendStopAndSettle(report: String?) {
        guard let client = client else {
            stopGate = .idle
            pushStopUI(stopGate)
            if let report = report { status(report) }
            return
        }
        stopGen += 1
        let gen = stopGen
        stopGate.begin()
        pushStopUI(stopGate)
        status(LiveStopGate.stoppingNote)
        let task: Task<Bool, Never>
        if let flying = pendingStop {
            task = flying
        } else {
            task = Task { await client.stopLive() }
            pendingStop = task
        }
        Task { @MainActor in
            let ok = await task.value
            // 等待期间又开推了、或换了地址：这一次的结果已经作废，别再拿它锁/解锁界面。
            guard gen == self.stopGen else { return }
            self.pendingStop = nil
            self.stopGate.settle(ok: ok)
            self.pushStopUI(self.stopGate)
            if ok {
                self.status(report ?? "已停止推流：PC 已确认，可以改特征了")
            } else {
                self.status(LiveStopGate.failedNote, "error")
            }
        }
    }

    /// 会话已经失效时停推：/live_stop 多半也会吃 401，不拿它锁界面——该做的是重新登录，
    /// 不是「重试停止」。但仍记在 pendingStop 上，重开推流前要等它落地。
    private func stopQuietly() {
        guard let client = client, pendingStop == nil else { return }
        stopGen += 1
        let gen = stopGen
        let task = Task { await client.stopLive() }
        pendingStop = task
        Task { @MainActor in
            _ = await task.value
            guard gen == self.stopGen else { return }
            self.pendingStop = nil
        }
    }

    /// 新一轮推流已经接上：之前的停止握手作废，按钮交回页面按 live_mode 刷。
    private func disarmStopGate() {
        stopGen += 1
        pendingStop = nil
        stopGate = .idle
        pushStopUI(stopGate)
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
        pushSeek(cur: CMTimeGetSeconds(video.currentPTS),
                 total: CMTimeGetSeconds(video.duration))
        // 屏幕上现在放的是 reader 送出位置往前 L 秒的那帧；声音跟着它走。
        // 读数不新鲜说明 PC 还没出帧，先不动，等下一 Tick。
        if let delay = LiveAudio.measuredDelay(inputMs: client.inputAgeMs,
                                               outputMs: client.outputAgeMs) {
            let shown = max(0, CMTimeGetSeconds(video.currentPTS) - delay)
            if audioWaitingForOutput {
                audioWaitingForOutput = false
                audio.start(at: shown, delay: 0)
            } else {
                audio.sync(to: shown)
            }
        }
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
            audio.pause()
            audioWaitingForOutput = false
            resumeSeconds = clampSeconds(CMTimeGetSeconds(video.currentPTS))
            stopMeter()
            phase = .loaded
            pushSeek(cur: 0, total: 0)
            stopQuietly()
            status(LiveAuth.lostMessage, "error")
            return
        }
        // 恢复路径①：PC 判了 409 或 /live_status 报 live_mode=false，都意味着必须重新 /live_start
        if client.saw409 != lastSeen409 || !client.pcLiveMode {
            lastSeen409 = client.saw409
            video.stop()
            audio.pause()
            audioWaitingForOutput = false
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
            // 重连一次；全屏只是 <html class="fs">，同一路 #video-stream，不用另刷。
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
            let avg = client.averageFrameBytes
            let up = avg > 0 ? "｜上行均值 \(max(1, avg / 1024)) KB/帧" : ""
            // 眼睛看到的卡顿只有三种来源：抽帧规则、编码太慢、链路太慢。
            // 这三个数摆在一行里，一看就知道该动哪处，不再靠猜。
            let send = video.takeSendStats()
            let net = client.takeNetworkStats()
            let encFail = video.takeEncodeFailures()
            let perf = LivePerf.line(sourceFPS: video.sourceFPS, encodeMs: send.costMs,
                                     gapMs: send.gapMs, rttAvgMs: net.avgMs, rttMaxMs: net.maxMs)
            status(warm + "手机 \(String(format: "%.1f", fps))fps"
                    + (perf.isEmpty ? "" : "｜" + perf)
                    + (encFail > 0 ? "｜编码失败 \(encFail)" : "")
                    + "｜本地丢帧 \(client.framesDroppedLocal)"
                    + "｜PC 拒 \(client.framesRejected)｜PC 收到 \(client.pcFramesIn)、"
                    + "预热丢 \(client.pcFramesDropped)" + up
                    + "｜屏幕长按 1.5 秒改 PC 地址")
            // 同一组数进日志，且多带 PC 侧的输入/输出年龄和换脸相似度：
            // 「卡顿」到底卡在手机发、链路、还是 PC 算，看这一行。
            let inAge = client.inputAgeMs.map { String($0) } ?? "-"
            let outAge = client.outputAgeMs.map { String($0) } ?? "-"
            let best = client.bestSim.map { String(format: "%.2f", $0) } ?? "-"
            let thr = client.matchThr.map { String(format: "%.2f", $0) } ?? "-"
            AppLog.shared.log("perf", "手机 \(String(format: "%.1f", fps))fps｜\(perf)"
                              + "｜编码失败 \(encFail)"
                              + "｜本地丢 \(client.framesDroppedLocal)｜PC拒 \(client.framesRejected)"
                              + "｜PC收 \(client.pcFramesIn) 预热丢 \(client.pcFramesDropped)"
                              + "｜in_age \(inAge) out_age \(outAge)"
                              + "｜plan \(client.planCount) swapped \(client.swappedFaces)"
                              + " best \(best) thr \(thr)")
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

    /// 让页面重连 /video_feed。0.11 起全屏不再克隆第二个 img，只有页面那一路。
    /// 8 秒内最多一次：看门狗每秒都在算，停着不等于每秒都要弹一条新长连接。
    private func refreshFeedInPage() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFeedRefresh >= 8 else { return }
        lastFeedRefresh = now
        webView.evaluateJavaScript("""
        (function () {
          try { if (window.LiveUI && LiveUI.refreshStream) LiveUI.refreshStream(); } catch (e) {}
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
        audio.load(url: url)                    // 同步摘音轨：选完马上点播放也来得及
        audioWaitingForOutput = false
        pushGen += 1
        phase = .loaded
        resumeSeconds = 0
        restartTries = 0
        pushSeek(cur: 0, total: 0)
        setPath(name)
        let dur = CMTimeGetSeconds(video.duration)
        let durText = dur.isFinite ? LiveTime.clock(dur) : "-"
        let size = video.naturalSize
        AppLog.shared.log("ui", "选中 \(name)：\(durText) \(Int(size.width))×\(Int(size.height))"
                          + " 源 \(Int(video.sourceFPS))fps")
        status("已选中 \(name)（\(durText)·\(Int(size.width))×\(Int(size.height))"
               + LivePerf.sourceLabel(video.sourceFPS) + "）："
               + "点「播放」开始推流｜那一格里输 秒数或 mm:ss 再按回车 = 跳到那儿"
               + (audio.hasTrack ? "｜原声在手机上跟播" : "｜这一段没有音轨，只有画面"))
    }

    // MARK: - 把运行日志发到 PC

    /// 界面左下角那颗「发日志」。日志压成几段 GET 发到 PC 的 /app_log?…：
    /// PC 不需要新接口，它的启动日志会把请求行连同查询串记下来，换脸服务重启也不丢。
    private func sendLogs(auto: Bool) {
        let base = client?.baseURL ?? storedHost().flatMap { LiveHost.base($0) }
        guard let base = base else {
            if !auto { status("还没连上 PC：先填地址，日志才有地方发", "error") }
            return
        }
        if !auto {
            webView.evaluateJavaScript(
                "window.LiveUI && LiveUI.logSending && LiveUI.logSending()",
                completionHandler: nil)
        }
        AppLog.shared.log("ui", auto ? "启动时自动补发上一轮的日志" : "用户点了「发日志」")
        let payload = AppLog.shared.snapshot()
        let id = AppLog.sessionID()
        Task {
            let report = await withCheckedContinuation {
                (cont: CheckedContinuation<AppLog.UploadReport, Never>) in
                AppLog.upload(payload: payload, to: base, session: id,
                              version: LiveConfig.appVersion) { cont.resume(returning: $0) }
            }
            await MainActor.run {
                if report.ok {
                    AppLog.shared.clearCrashFlag()
                    self.status("日志已发到电脑：编号 \(id)（\(report.chunks) 段）", "success")
                } else {
                    AppLog.shared.log("err", "日志发送失败：\(report.message)")
                    self.status("日志没发出去：\(report.message)｜确认手机和电脑在同一张网", "error")
                }
                let js = "window.LiveUI && LiveUI.logDone && LiveUI.logDone("
                    + (report.ok ? "true" : "false") + ", \(LiveShim.jsLiteral(id)))"
                self.webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    /// 上一轮是被杀掉/闪退的：启动后自动补发一次，用户不用先发现再手动点。
    private func maybeAutoSendCrashLog() {
        guard !crashUploadTried, AppLog.shared.needsAutoUpload else { return }
        crashUploadTried = true
        AppLog.shared.log("boot", "上一轮没正常收尾：自动补发一次")
        sendLogs(auto: true)
    }

    // MARK: - 页面日志（JS 错误、命令回话、播放状态）

    private func clipped(_ body: [String: Any], _ key: String, _ max: Int = 600) -> String {
        let s = (body[key] as? String) ?? ""
        return s.count > max ? String(s.prefix(max)) + "…" : s
    }

    private func logJsMessage(_ body: [String: Any]) {
        let level = clipped(body, "level", 20)
        let msg = clipped(body, "msg")
        let src = clipped(body, "src", 160)
        let line = (body["line"] as? NSNumber)?.intValue ?? 0
        var text = "[\(level)] \(msg)"
        if !src.isEmpty { text += " @\(src):\(line)" }
        AppLog.shared.log("js", text)
    }

    private func logCommand(_ body: [String: Any]) {
        let url = clipped(body, "url", 120)
        let status = (body["status"] as? NSNumber)?.intValue ?? 0
        let ms = (body["ms"] as? NSNumber)?.intValue ?? 0
        let text = clipped(body, "body", 300)
        var line = "\(url) \(status == 0 ? "网络错" : "HTTP \(status)") \(ms)ms"
        if !text.isEmpty { line += " \(text)" }
        AppLog.shared.log("cmd", line)
    }

    /// 页面读到的 PC 状态变了才报。和原生 phase 摆在一行：
    /// 「按钮说停了、PC 还在播」这种前后台不一致，靠这条时间线定位。
    private func logPageState(_ body: [String: Any]) {
        func flag(_ key: String) -> Int { (body[key] as? Bool) == true ? 1 : 0 }
        let plan = (body["plan"] as? NSNumber)?.intValue ?? 0
        let fps = (body["fps"] as? NSNumber)?.intValue ?? 0
        AppLog.shared.log("page", "live=\(flag("live")) playing=\(flag("playing")) "
                           + "locked=\(flag("locked")) plan=\(plan) fps=\(fps)"
                           + "｜原生 \(phaseName) 停止闸 \(stopGateName)")
    }
}

// MARK: - 页面与原生之间

extension PageViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == LiveConfig.seekBridgeName {
            handleSeekBar(message.body)
            return
        }
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
        case LiveShim.hookFullscreen:
            setPageFullscreen((body["on"] as? Bool) ?? false)
        case LiveShim.hookSendLog:
            sendLogs(auto: false)
        case LiveShim.hookJsLog:
            logJsMessage(body)
        case LiveShim.hookCmdLog:
            logCommand(body)
        case LiveShim.hookPageState:
            logPageState(body)
        case LiveShim.hookReady:
            let hooks = body["hooks"] as? [String: Bool] ?? [:]
            let missing = LiveShim.actionNames.filter { hooks[$0] != true }
            AppLog.shared.log("page", "页面加载完：\(clipped(body, "title", 80))"
                              + (missing.isEmpty ? "｜挂子齐" : "｜缺 \(missing.joined(separator: "、"))"))
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
        AppLog.shared.log("page", "页面加载完：\(webView.url?.path ?? "/")")
        // 上一轮是被闪退/杀掉的：等页面稳定两秒自动补发一次日志。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.maybeAutoSendCrashLog()
        }
        client.importCookies { [weak self] in
            guard let self = self else { return }
            // 页面重载会把握手锁一起刷掉：还在 stopping/failed 就重新锁上，
            // 别让用户在新页面上看到一颗能点的「播放」。
            if self.stopGate != .idle { self.pushStopUI(self.stopGate) }
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

    /// 下载链接（剪辑产物、录像）走的是顶层导航 + attachment 响应：WebKit 自己不会存，
    /// 交回 .download 让 WKDownload 接住，由原生决定落到手机哪个目录、再弹保存框。
    /// 判断放在响应这一侧：登录过期时 /download_file 会先 302 到登录页，按 URL 提前
    /// 判下载的话会把登录页的 HTML 存成文件；等最终响应看类型和 attachment 才不会错。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // 三条任一命中就是下载：URL 是下载口、响应明说 attachment、或者 WebKit 自己放不了。
        if Self.isDownloadResponse(navigationResponse.response)
            || !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    private static func isDownloadPath(_ url: URL) -> Bool {
        let p = url.path
        return p == "/download_file" || p.hasPrefix("/download_file/")
            || p == "/api/record/download"
    }

    private static func isDownloadResponse(_ response: URLResponse) -> Bool {
        if let url = response.url, isDownloadPath(url) { return true }
        guard let http = response as? HTTPURLResponse,
              let cd = http.value(forHTTPHeaderField: "Content-Disposition") else { return false }
        return cd.lowercased().contains("attachment")
    }

    private func reportFailure(_ error: Error) {
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled else { return }
        AppLog.shared.log("net", "页面加载失败：\(ns.domain) \(ns.code) \(ns.localizedDescription)")
        let host = client.map { LiveHost.display($0.baseURL) } ?? "（没地址）"
        status("连不上 \(host)：\(ns.localizedDescription)｜确认手机和电脑在同一张网，"
               + "并且这台手机的「本地网络」权限是开的", "error")
        openAddress(storedHost())
    }
}

// MARK: - 下载落盘：WKDownload 决定路径 → 完成弹保存框
//
// 89MB 的剪辑产物不可能读进内存再拼 blob：WKDownload 是流式落盘，
// 完成以后把文件 URL 交给系统保存框，用户自己选「存储到文件」或相册。

extension PageViewController: WKDownloadDelegate {
    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let fm = FileManager.default
        let raw = suggestedFilename.isEmpty ? "download.mp4" : suggestedFilename
        let name = (raw as NSString).lastPathComponent
        let dir = fm.temporaryDirectory
            .appendingPathComponent("LiveSwapDownloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent(name)
            downloadTargets[ObjectIdentifier(download)] = dst
            completionHandler(dst)
            status("正在下载 \(name)…", "success")
        } catch {
            completionHandler(nil)
            status("下载落不了盘：\(error.localizedDescription)", "error")
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloadTargets.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .intValue ?? 0
        AppLog.shared.log("download", "落到临时目录：\(url.lastPathComponent) \(bytes / 1024)KB")
        status("已下载 \(url.lastPathComponent)：选「存储到文件」或相册", "success")
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX,
                                                                 y: view.bounds.midY,
                                                                 width: 0, height: 0)
        sheet.completionWithItemsHandler = { _, _, _, _ in
            // 用户存到哪儿由系统拷走；临时这份留到保存框关掉就删，不占手机空间。
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        present(sheet, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadTargets.removeValue(forKey: ObjectIdentifier(download))
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled else { return }
        status("下载失败：\(ns.localizedDescription)", "error")
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

/// 全屏是页面里的 CSS 类，SwiftUI 这层只知道「要不要藏系统条」。
final class LiveChrome: ObservableObject {
    static let shared = LiveChrome()
    @Published var fullscreen = false
    private init() {}
}

@main
struct LiveApp: App {
    @StateObject private var chrome = LiveChrome.shared

    init() {
        // 第一件事就把日志接上：后面无论页面起没起来、有没有闪退，都有记录可发。
        AppLog.shared.boot(version: LiveConfig.appVersion, build: LiveConfig.appBuild)
    }

    var body: some Scene {
        WindowGroup {
            chromeContent
        }
    }

    @ViewBuilder private var chromeContent: some View {
        if #available(iOS 16.0, *) {
            RootView().ignoresSafeArea()
                .statusBarHidden(chrome.fullscreen)
                .persistentSystemOverlays(chrome.fullscreen ? .hidden : .automatic)
        } else {
            // iOS 15：状态栏能藏，Home 条交给 PageViewController 的 prefersHomeIndicatorAutoHidden。
            RootView().ignoresSafeArea()
                .statusBar(hidden: chrome.fullscreen)
        }
    }
}
