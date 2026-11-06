import AVFoundation
import CoreML
import UIKit

/// 播放页自己做控制器，不再借 SwiftUI 的 fullScreenCover：全屏不带卡片缩边，能不能横屏由这一页自己报给系统。
/// ⚠️ 但系统那条路在这个进程里是死的：0.22 实测 delegate 确实被问到、也确实交回了「竖+左横+右横」，
/// requestGeometryUpdate 也没报错，场景朝向一路都是 朝向1＝竖（11-06 17:59、18:00 两轮）。
/// 所以横屏这回事由下面 applyOri() 自己转内容来做；哪天系统真给转起来了，那段自动让路。
final class VRPlayVC: UIViewController {
    private let shell = UIView()
    private let surface = VRLiveView()
    private let live: VRLive
    private let onEnd: (String) -> Void
    private let stopBtn = UIButton(type: .system)
    /// 假横屏那行账只在前 6 次和状态真变的时候记：applyOri 每轮布局都会走
    private var oriSeen = 0
    private var oriLast = ""

    init(url: URL, eyeLong: Int, bpct: Float, units: MLComputeUnits, rot: Bool, sbs: Bool,
         onEnd: @escaping (String) -> Void) {
        self.live = VRLive(url: url, eyeLong: eyeLong, bpct: bpct, zp: 0.15, smooth: 0.4,
                           units: units, rot: rot, sbs: sbs)
        self.onEnd = onEnd
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("这块不用 xib") }

    /// 这一页吃横屏；上限还是 Info.plist 那三档，delegate 那闸也照样放开（两道都得过）
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        [.portrait, .landscapeLeft, .landscapeRight]
    }
    override var shouldAutorotate: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func loadView() {
        view = shell
        shell.backgroundColor = .black
        // surface 的框全由 applyOri 定：交给系统自动缩放会把转好的框改回竖的
        shell.autoresizesSubviews = false
        shell.addSubview(surface)
        let cb = onEnd
        // 线程自己收兵时也会走到这里：先把报告交回界面，再关掉这一页（inside 归位在 finish 里已经做过）
        live.onEnd = { [weak self] text in
            cb(text)
            guard let vc = self, vc.presentingViewController != nil else { return }
            vc.dismiss(animated: true)
        }
        surface.attach(live)
        stopBtn.setTitle("停止", for: .normal)
        stopBtn.setTitleColor(.white, for: .normal)
        stopBtn.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        stopBtn.backgroundColor = UIColor(white: 1, alpha: 0.24)
        stopBtn.layer.cornerRadius = 8
        stopBtn.addTarget(self, action: #selector(tappedStop), for: .touchUpInside)
        surface.addSubview(stopBtn)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyOri()
        // 右上角那一格就是 VRLiveView 给「停止」留出来的 100 pt，实测那几行避开它
        let b = surface.bounds
        stopBtn.frame = CGRect(x: max(8, b.maxX - 96), y: 8, width: 84, height: 34)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 起手（Metal + 载模型）要两三秒，不抱着主线程：起不来把原因显示出来并关掉这一页
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let vc = self else { return }
            let e = vc.live.start(layer: vc.surface.displayLayer, label: vc.surface.stats)
            guard !e.isEmpty else { return }
            DispatchQueue.main.async {
                // 起不来的那句要看得见：实测那几行平时跟着控制栏收着，这一条单独放行
                vc.surface.stats.isHidden = false
                vc.surface.stats.text = e
                vc.onEnd(e)
                if vc.presentingViewController != nil { vc.dismiss(animated: true) }
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 光是改闸不够：得让系统重新来问一遍最上面这个控制器，否则横着进来也不重算朝向
        setNeedsUpdateOfSupportedInterfaceOrientations()
        VROrientation.allowLandscape(true)
        VROrientation.report("页面在场")
        // 设备朝向的监听归这一页：不在的时候没人替我们转内容
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(oriChanged),
                                               name: UIDevice.orientationDidChangeNotification, object: nil)
        applyOri()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        VROrientation.allowLandscape(false)
    }

    /// 页面被收走 = 两条线程必须停：inside 一直占着的话，全片和下一条实时都起不来
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        surface.teardown()
    }

    @objc private func oriChanged() { applyOri() }

    /// 横屏自己来：手机横过来就把整页内容转 ±90°、宽高对调，铺满物理屏（各眼正好占半屏）。
    /// 只在「窗还是竖的那块尺寸、系统界面也没转」时动手；系统真给横屏了这段就让路，不会转两遍。
    private func applyOri() {
        let dev = UIDevice.current.orientation
        let scene = shell.window?.windowScene?.interfaceOrientation ?? .unknown
        let base = shell.window?.bounds ?? UIScreen.main.bounds
        let sysLandscape = scene == .landscapeLeft || scene == .landscapeRight
        let fake = (dev == .landscapeLeft || dev == .landscapeRight) && !sysLandscape && base.width <= base.height
        // 两套枚举是反的：设备 landscapeRight（顶边转到用户右手那边）时，内容上方要对准设备的左边
        let deg: CGFloat = dev == .landscapeRight ? -90 : 90
        let size = fake ? CGSize(width: base.height, height: base.width) : base.size
        surface.bounds = CGRect(origin: .zero, size: size)
        surface.center = CGPoint(x: base.width / 2.0, y: base.height / 2.0)
        surface.transform = fake
            ? CGAffineTransform(rotationAngle: deg * .pi / 180.0)
            : .identity
        let state = "设备\(VRPlayVC.oriName(dev)) 界面\(scene.rawValue) 窗\(Int(base.width))x\(Int(base.height))"
            + " → 内容 \(Int(size.width))x\(Int(size.height))\(fake ? " 转 \(Int(deg))°" : " 不转")"
        if state != oriLast {
            oriLast = state
            oriSeen += 1
            if oriSeen <= 6 { VRJournal.line("假横屏 \(state)") }
        }
        surface.setNeedsLayout()
    }

    private static func oriName(_ o: UIDeviceOrientation) -> String {
        switch o {
        case .portrait: return "竖"
        case .portraitUpsideDown: return "倒竖"
        case .landscapeLeft: return "左横"
        case .landscapeRight: return "右横"
        case .faceUp: return "面朝上"
        case .faceDown: return "面朝下"
        default: return "未知"
        }
    }

    @objc private func tappedStop() {
        VRLive.requestStopCurrent()
    }
}

enum VRPage {
    /// 把播放页从窗口根控制器呈现出去。返回假 = 连根控制器都没找到（这份副本就该还回去）。
    /// ⚠️ 相册那条 cover 的关闭是异步的：finishPick 里刚把 showVideoPicker 置假就立刻 present，
    /// 根控制器手上还挂着它，系统会直接拒掉第二次呈现（「already presenting」）。
    /// 所以这里等它退干净，最多再试 3 次、每次隔 0.25 s。
    @discardableResult
    static func present(url: URL, eyeLong: Int, bpct: Float, units: MLComputeUnits,
                        rot: Bool, sbs: Bool, onEnd: @escaping (String) -> Void) -> Bool {
        guard rootController() != nil else {
            VRJournal.line("页面 没有找到窗口根控制器，播放页没开")
            return false
        }
        launch(url: url, eyeLong: eyeLong, bpct: bpct, units: units, rot: rot, sbs: sbs,
               tries: 0, onEnd: onEnd)
        return true
    }

    private static func launch(url: URL, eyeLong: Int, bpct: Float, units: MLComputeUnits,
                               rot: Bool, sbs: Bool, tries: Int, onEnd: @escaping (String) -> Void) {
        guard let root = rootController() else {
            VRJournal.line("页面 第 \(tries + 1) 次没找到窗口根控制器，不起了")
            return
        }
        if let busy = root.presentedViewController, tries < 3 {
            VRJournal.line("页面 根控制器手上还挂着 \(String(describing: type(of: busy)))"
                + "（相册大概还在退），0.25 s 后再试第 \(tries + 1) 次")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                launch(url: url, eyeLong: eyeLong, bpct: bpct, units: units, rot: rot,
                       sbs: sbs, tries: tries + 1, onEnd: onEnd)
            }
            return
        }
        let vc = VRPlayVC(url: url, eyeLong: eyeLong, bpct: bpct, units: units, rot: rot,
                          sbs: sbs, onEnd: onEnd)
        let had = root.presentedViewController.map { String(describing: type(of: $0)) } ?? "无"
        root.present(vc, animated: true) {
            VRJournal.line("页面 呈现完成 \(String(describing: type(of: vc)))"
                + "｜它自己支持 竖+左横+右横")
            VROrientation.report("呈现完成")
        }
        VRJournal.line("页面 请求呈现 从 \(String(describing: type(of: root)))"
            + " 递过去前它手上有 \(had)（第 \(tries + 1) 次）")
    }

    static func rootController() -> UIViewController? {
        var picked: UIViewController?
        var seen = 0
        for scene in UIApplication.shared.connectedScenes {
            seen += 1
            guard let ws = scene as? UIWindowScene else { continue }
            guard scene.session.role == .windowApplication else { continue }
            for w in ws.windows where w.rootViewController != nil {
                if picked == nil || w.isKeyWindow { picked = w.rootViewController }
            }
        }
        if picked == nil {
            VRJournal.line("页面 场景 \(seen) 个里没有一个带根控制器的窗口场景")
        }
        return picked
    }
}
