//
//  ci/liveselftest/main.swift
//  出包前在 mac 上把「没被真编译器碰过、也没被真机器跑过」的那几件事判一遍：
//  地址解析、跳转解析、抽帧节奏、vImage+ImageIO 那条编码通路真的出不出得来 JPEG、
//  注入脚本里的挂子名和 Swift 分发器对不对得上、以及和 PC 契约绑死的那几个数。
//
//  只编 LiveLogic / FrameSource / SwapClient / AppLog 四个文件：界面那个文件要 UIKit，
//  它在 xcodebuild 那一跑被真编译器过一遍。
//

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

var checks = 0
var fails = 0

func ck(_ name: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    if ok {
        print("ok   \(name)")
    } else {
        fails += 1
        print("FAIL \(name) \(detail)")
    }
}

func eq<T: Equatable>(_ a: T?, _ b: T) -> Bool { a == b }

// MARK: - PC 地址

func host(_ s: String) -> String? { LiveHost.base(s)?.absoluteString }

ck("地址 光host补默认端口", eq(host("192.168.1.20"), "http://192.168.1.20:5100"),
   "\(String(describing: host("192.168.1.20")))")
ck("地址 带端口", eq(host("192.168.1.20:5055"), "http://192.168.1.20:5055"),
   "\(String(describing: host("192.168.1.20:5055")))")
ck("地址 自带scheme", eq(host("http://192.168.1.20:5000"), "http://192.168.1.20:5000"),
   "\(String(describing: host("http://192.168.1.20:5000")))")
ck("地址 尾巴斜杠容忍", eq(host("192.168.1.20:5000/"), "http://192.168.1.20:5000"),
   "\(String(describing: host("192.168.1.20:5000/")))")
ck("地址 空格吃掉", eq(host("  10.0.0.5:8080\n"), "http://10.0.0.5:8080"),
   "\(String(describing: host("  10.0.0.5:8080\n")))")
ck("地址 带路径拒", host("192.168.1.20/login") == nil, "把页面地址整条粘过来不该放行")
ck("地址 端口非数字拒", host("192.168.1.20:abc") == nil)
ck("地址 端口0拒", host("192.168.1.20:0") == nil)
ck("地址 端口越界拒", host("192.168.1.20:70000") == nil)
ck("地址 空拒", host("") == nil)
ck("地址 中文拒", host("办公室那台") == nil)
ck("地址 回显", LiveHost.display(URL(string: "http://192.168.1.9:5000")!) == "192.168.1.9:5000")

// MARK: - 跳转那一格

func t(_ s: String) -> Double? { LiveTime.parse(s) }

ck("跳转 纯秒", eq(t("75"), 75.0), "\(String(describing: t("75")))")
ck("跳转 小数秒", eq(t("75.5"), 75.5))
ck("跳转 分:秒", eq(t("1:15"), 75.0))
ck("跳转 时:分:秒", eq(t("1:02:03"), 3723.0))
ck("跳转 补零", eq(t("01:15"), 75.0))
ck("跳转 空拒", t("") == nil)
ck("跳转 文件路径不误判", t("E:/videos/11.mp4") == nil, "PC 的文件路径要原样交回页面")
ck("跳转 粘过去的路径不误判", t("uploads/11.mp4") == nil)
ck("跳转 段数超了拒", t("1:2:3:4") == nil)
ck("跳转 尾巴冒号拒", t("1:") == nil)
ck("跳转 两个点拒", t("1..2") == nil)
ck("跳转 钟面", LiveTime.clock(75) == "1:15")
ck("跳转 钟面过小时", LiveTime.clock(3661) == "1:01:01")
ck("跳转 钟面nan", LiveTime.clock(.nan) == "-")

// MARK: - 抽帧节奏

// 30fps 源 + 15fps 推送：一秒 30 帧里该发 15 帧
var next: Double?
var emitted = 0
for i in 0..<60 {
    let pts = Double(i) / 30.0
    let d = LivePace.decide(ptsSeconds: pts, nextEmitSeconds: next, interval: 1.0 / 15.0)
    if d.emit { emitted += 1 }
    next = d.nextEmitSeconds
}
ck("节奏 30fps抽到15fps", emitted >= 29 && emitted <= 31, "实发 \(emitted)，要 30 左右")

// 源比推送慢：全部照发，不做插帧
next = nil
var slow = 0
for i in 0..<10 {
    let pts = Double(i) / 5.0          // 5fps
    let d = LivePace.decide(ptsSeconds: pts, nextEmitSeconds: next, interval: 1.0 / 15.0)
    if d.emit { slow += 1 }
    next = d.nextEmitSeconds
}
ck("节奏 慢源全发", slow == 10, "实发 \(slow)，要 10")

// 24fps 源 + 15fps 目标：上一格是 pts+1/15，落在两帧之间，只能隔一帧发一次 → 实际 12fps。
// 用户看到的「明显停顿」先查这个：素材是 24/25fps 时抽帧规则本身就只给 12~12.5fps。
next = nil
var q24 = 0
for i in 0..<72 {                        // 3 秒
    let pts = Double(i) / 24.0
    let d = LivePace.decide(ptsSeconds: pts, nextEmitSeconds: next, interval: 1.0 / 15.0)
    if d.emit { q24 += 1 }
    next = d.nextEmitSeconds
}
ck("节奏 24fps源只到12fps", q24 == 36, "实发 \(q24)，3 秒应 36 帧（每两帧取一帧）")

// 落后了重新对齐：下一格时刻在身后，这一帧必须发出去，不能欠账堆积
let behind = LivePace.decide(ptsSeconds: 5.0, nextEmitSeconds: 4.0, interval: 1.0 / 15.0)
ck("节奏 落后重对齐", behind.emit && eq(behind.nextEmitSeconds, 5.0 + 1.0 / 15.0),
   "emit=\(behind.emit) next=\(String(describing: behind.nextEmitSeconds))")
let early = LivePace.decide(ptsSeconds: 4.0, nextEmitSeconds: 4.05, interval: 1.0 / 15.0)
ck("节奏 未到点抽掉", !early.emit && eq(early.nextEmitSeconds, 4.05))
let bad = LivePace.decide(ptsSeconds: .nan, nextEmitSeconds: nil, interval: 1.0 / 15.0)
ck("节奏 坏PTS不发", !bad.emit)

// MARK: - vImage + ImageIO 那条编码通路

func makeBuffer(w: Int, h: Int) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let err = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                  kCVPixelFormatType_32BGRA, nil, &pb)
    guard err == kCVReturnSuccess, let buf = pb else { return nil }
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
    let rowBytes = CVPixelBufferGetBytesPerRow(buf)
    for y in 0..<h {
        for x in 0..<w {
            let p = base.advanced(by: y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
            p[0] = UInt8(x % 256)          // B
            p[1] = UInt8(y % 256)          // G
            p[2] = UInt8((x + y) % 256)    // R
            p[3] = 255
        }
    }
    return buf
}

if let pb = makeBuffer(w: 1280, h: 720) {
    if let jpeg = FrameCodec.jpeg(pb, maxWidth: 640, quality: LiveConfig.jpegQuality) {
        ck("编码 出得来JPEG", jpeg.count > 1024 && jpeg[0] == 0xFF && jpeg[1] == 0xD8,
           "bytes=\(jpeg.count)")
        ck("编码 单帧远小于PC的2MB上限", jpeg.count < 2 * 1024 * 1024, "bytes=\(jpeg.count)")
        let size = FrameCodec.decodedSize(jpeg)
        ck("编码 宽封顶640", eq(size?.width, 640), "\(String(describing: size))")
        ck("编码 宽高比不变", eq(size?.height, 360), "\(String(describing: size))")
    } else {
        ck("编码 出得来JPEG", false, "nil")
    }
    // 源比封顶窄时不许放大：放大会白占上行带宽
    if let small = makeBuffer(w: 320, h: 240), let j2 = FrameCodec.jpeg(small, maxWidth: 640,
                                                                        quality: 0.7) {
        ck("编码 不 upscale", eq(FrameCodec.decodedSize(j2)?.width, 320),
           "\(String(describing: FrameCodec.decodedSize(j2)))")
    } else {
        ck("编码 不 upscale", false)
    }
} else {
    ck("编码 造得出测试像素缓冲", false)
}

// MARK: - 注入脚本与 Swift 分发器对账

let shim = LiveShim.source()
ck("挂子 三条都有名字", LiveShim.actionNames == [LiveShim.hookPick, LiveShim.hookPlay, LiveShim.hookSeek],
   "\(LiveShim.actionNames)")
ck("挂子 名字是页面里那几个", LiveConfig.bridgeName == "livebridge")
ck("脚本 占位符全替换掉了", !shim.contains("__HOOKS__") && !shim.contains("__BRIDGE__")
   && !shim.contains("__SEEK__") && !shim.contains("__FULLSCREEN__")
   && !shim.contains("__STOPPING__") && !shim.contains("__FAILED__")
   && !shim.contains("__LOG__") && !shim.contains("__JSLOG__")
   && !shim.contains("__CMDLOG__") && !shim.contains("__PAGESTATE__")
   && !shim.contains("__LOGSEL__"))
for hook in LiveShim.hooks {
    // 脚本里注入的是 JSON 字面量（选择器带引号），所以按编码后的形态找
    ck("脚本 带挂子 \(hook.name)",
       shim.contains(LiveShim.jsLiteral(hook.name)) && shim.contains(LiveShim.jsLiteral(hook.selector)))
}
ck("脚本 报 ready", shim.contains("action: 'ready'") && LiveShim.hookReady == "ready")
ck("脚本 捕获阶段拦", shim.contains("}, true);") && shim.contains("stopPropagation"))
ck("脚本 走页面自己的showStatus", shim.contains("showStatus"))
ck("脚本 桥名注入了", shim.contains(LiveShim.jsLiteral(LiveConfig.bridgeName)))
ck("脚本 跳转改成回车", shim.contains("addEventListener('keydown'") && shim.contains("'Enter'")
   && shim.contains(LiveShim.jsLiteral(LiveShim.pathSelector)) && shim.contains("[SEEK]"))
ck("脚本 不再挂被删的按钮", !shim.contains("onclick^"),
   "PC 撤掉了「设置视频路径」那颗按钮，选择器留着也匹配不到")
// PC 页面从这一版起自己也有 LiveUI（setPlaying/refreshStream/autoRefresh）：
// 注入脚本只能在其上补方法。整赋一个新对象会把页面那三个一起冲掉，
// 暂停态改完绑定以后那次 re_rendered 自动重连就调用不到，屏幕定在原帧。
ck("脚本 不整个覆盖页面LiveUI", !shim.contains("window.LiveUI = {"),
   "整赋新对象会把 setPlaying/refreshStream/autoRefresh 一起冲掉")
ck("脚本 合并到现有LiveUI", shim.contains("var UI = window.LiveUI") && shim.contains("window.LiveUI = UI"))
ck("脚本 关掉页面30秒盲刷", shim.contains("UI.autoRefresh(false)"))
ck("脚本 长连接断了会重连", shim.contains("LiveUI.refreshStream") && shim.contains("img.id !== 'video-stream'"))
ck("脚本 全屏不再克隆第二路流", !shim.contains("fullscreen-video"),
   "0.11 起页面只用 html.fs 铺满，同一路 #video-stream")
ck("脚本 全屏态上报原生", shim.contains("action: FS") && LiveShim.hookFullscreen == "fullscreen",
   "原生靠它藏/恢复状态栏")
// 0.20：全屏里控件平时收起，点画面唤出，几秒不动自己收；退出全屏一起还原。
ck("脚本 全屏控件默认收起", shim.contains("FS_IDLE = 'live-fs-idle'")
   && shim.contains("if (on) fsIdle(true);"),
   "页面全屏会点亮播放行和进度条，注入层要在进入那一刻就盖掉")
ck("脚本 收起样式压得住页面", shim.contains("html.fs.live-fs-idle .controls.play-row")
   && shim.contains("html.fs.live-fs-idle #live-seek-row.on")
   && shim.contains("visibility:hidden !important"),
   "页面那条 visibility:visible 是直接声明，不用 !important 压不住")
ck("脚本 点画面唤出控件", shim.contains("function fsShow") && shim.contains("fsShow();")
   && shim.contains("setTimeout(function () { fsIdle(true); }, FS_HIDE_MS)"))
ck("脚本 控件上的点击不收起", shim.contains("t.closest('.controls.play-row')")
   && shim.contains("t.closest(LOG_SEL)"))
ck("脚本 拖进度条不收起", shim.contains("addEventListener('input'")
   && shim.contains("t.closest('#live-seek-row')"),
   "拖 range 只发 input，不发 click，不重置计时就会把条从手指底下抽走")
ck("脚本 退出全屏还原控件", shim.contains("clearTimeout(fsHideTimer)")
   && shim.contains("fsIdle(false)") && shim.contains("html.fs.live-fs-idle #live-log-btn"))

// 停止握手：点停止到 PC 确认之间，按钮和特征下拉框必须一直锁着；
// /live_stop 没送到就停在 failed，不许假装停了——那正是用户撞 409 的那条路。
ck("停止 按下即锁", LiveStopGate.stopping.blocksPlay && LiveStopGate.stopping.holdsEditingLock)
ck("停止 失败仍锁", LiveStopGate.failed.blocksPlay && LiveStopGate.failed.holdsEditingLock)
ck("停止 待命才放开", !LiveStopGate.idle.blocksPlay && !LiveStopGate.idle.holdsEditingLock)
var gate = LiveStopGate.idle
gate.begin()
ck("停止 进停止中", gate == .stopping)
gate.settle(ok: false)
ck("停止 没送到停在失败", gate == .failed && gate.holdsEditingLock)
gate.begin()
gate.settle(ok: true)
ck("停止 确认成功回待命", gate == .idle)
ck("停止 脚本有握手法", shim.contains("setStopPending"))
ck("停止 握手中拦轮询", shim.contains("if (STOP_HOLD)"),
   "轮询读到的是 PC 上一秒的状态，不许把「停止中…」改回「停止」")
ck("停止 状态字进脚本", shim.contains(LiveShim.jsLiteral(LiveStopGate.stoppingState))
   && shim.contains(LiveShim.jsLiteral(LiveStopGate.failedState)))
ck("停止 两个状态字不同", LiveStopGate.stoppingState != LiveStopGate.failedState)

// 整页忙闸：命令发出到 PC 回话之间，所有可点的东西一起灰；每秒轮询不许进闸，
// 否则页面会跟着心跳一秒一闪。
ck("忙闸 有整页灰样式", shim.contains("pc-busy") && shim.contains("pointer-events:none"))
ck("忙闸 命令包了fetch", shim.contains("window.fetch = function") && shim.contains("busyFetches"))
ck("忙闸 心跳不进闸", shim.contains("/get_playback_state") && shim.contains("/api/record/status")
   && shim.contains("/api/edit/progress"))
ck("忙闸 非按钮也挡", shim.contains("busyNow()") && shim.contains("ev.stopPropagation"),
   "剪辑页模式格是 div，只靠样式挡不住")
ck("忙闸 原生能开关", shim.contains("UI.setBusy") && shim.contains("busyNative = Math.max"))
ck("忙闸 停止失败可重试", shim.contains("busyHold = (s === STOP_STOPPING)"),
   "失败态还灰住整页，用户就点不到「重试停止」")
ck("忙闸 PC没回话到点放开", shim.contains("BUSY_MAX_MS") && shim.contains("clearTimeout(timer)"))
ck("忙闸 下载链接不拦", shim.contains("downloadFile") && shim.contains("pointer-events:auto"),
   "下载是顶层导航交给 WKDownload，没有回话可等，灰住就点不了")

// 发日志：界面左下角那颗按钮 → 原生把日志压成几段 GET 发到 PC 的 /app_log?…。
// 等 PC 回话的忙闸不许挡它（用户往往正是卡住时才想发日志）。
ck("日志 界面有按钮", shim.contains("live-log-btn")
   && shim.contains(LiveShim.jsLiteral(LiveShim.hookSendLog)))
ck("日志 忙时也点得动", shim.contains("html.pc-busy #live-log-btn")
   && shim.contains("closest(LOG_SEL)"))
ck("日志 按钮有回显", shim.contains("logDone") && shim.contains("logSending"))
ck("日志 页面JS错误进日志", shim.contains("unhandledrejection") && shim.contains("console.error"))
ck("日志 播放状态变化进日志", shim.contains("/get_playback_state")
   && shim.contains(LiveShim.jsLiteral(LiveShim.hookPageState)))
ck("日志 命令回话带响应体", shim.contains(LiveShim.jsLiteral(LiveShim.hookCmdLog))
   && shim.contains("observeCommand"), "特征改不了多半是 409 的响应体在说话")
ck("日志 分段纯函数", AppLog.chunks("abcdef", size: 2) == ["ab", "cd", "ef"],
   "\(AppLog.chunks("abcdef", size: 2))")
ck("日志 base64url 只含免转义字符", AppLog.base64URL(Data([0xfb, 0xff])) == "-_8",
   AppLog.base64URL(Data([0xfb, 0xff])))
ck("日志 编号12位十六进制", AppLog.sessionID().count == 12
   && AppLog.sessionID().allSatisfy { $0.isHexDigit }, AppLog.sessionID())
let logSample = Data(String(repeating: "手机推流日志 ", count: 400).utf8)
if let packed = AppLog.compress(logSample) {
    ck("日志 压缩真的变小", packed.count < logSample.count, "\(packed.count)/\(logSample.count)")
} else {
    ck("日志 压缩真的变小", false, "压缩返回 nil（会落回明文，不算致命）")
}

// 点「播放」时 PC 手上已有片（剪辑页「用于换脸」）就交回页面自己的 /start_playback；
// 两边都没片才是手机上选片的时机。
ck("播放 手机有片自己推", !LivePlaySource.usesPCVideo(hasLocalClip: true,
                                                   pcPath: "uploads\\a.mp4"))
ck("播放 PC有片放行页面", LivePlaySource.usesPCVideo(hasLocalClip: false,
                                                  pcPath: "uploads\\edited_1.mp4"))
ck("播放 两边都没片才弹相册", !LivePlaySource.usesPCVideo(hasLocalClip: false, pcPath: "")
   && !LivePlaySource.usesPCVideo(hasLocalClip: false, pcPath: nil)
   && !LivePlaySource.usesPCVideo(hasLocalClip: false, pcPath: "none"))
ck("桥名 进度条独立", LiveConfig.seekBridgeName == "liveSeek"
   && LiveConfig.seekBridgeName != LiveConfig.bridgeName)
ck("转义 引号反斜杠", LiveShim.jsLiteral("a\"b\\c") == "\"a\\\"b\\\\c\"",
   LiveShim.jsLiteral("a\"b\\c"))
ck("转义 中文原样", LiveShim.jsLiteral("推流").hasPrefix("\"推流"))

// MARK: - 状态行里的出帧账目

let perfAll = LivePerf.line(sourceFPS: 24, encodeMs: 18.4, gapMs: 312, rttAvgMs: 40, rttMaxMs: 180)
ck("账目 四项齐全", perfAll.contains("源 24fps") && perfAll.contains("编码 18ms")
   && perfAll.contains("发间隔峰 312ms") && perfAll.contains("往返 40/180ms"), perfAll)
ck("账目 零值全省", LivePerf.line(sourceFPS: 0, encodeMs: 0, gapMs: 0,
                                  rttAvgMs: 0, rttMaxMs: 0).isEmpty)
ck("账目 选片标源帧率", LivePerf.sourceLabel(24) == "·源 24fps", LivePerf.sourceLabel(24))
ck("账目 未知源不标", LivePerf.sourceLabel(0).isEmpty)

// MARK: - 和 PC 契约绑死的几个数

ck("契约 在途上限3", LiveConfig.inflightLimit == 3)
ck("契约 推送15fps", LiveConfig.pushFPS == 15.0)
// 0.20 仍是 640：全屏交互改在脚本层，推流参数这一版不动。
ck("契约 请求宽640", LiveConfig.fallbackMaxWidth == 640)
ck("契约 UA带版本", LiveConfig.userAgentSuffix == "LiveSwap/0.20"
   && LiveConfig.appVersion == "0.20" && LiveConfig.appBuild == "20")
ck("契约 质量0.7", LiveConfig.jpegQuality == 0.7)
ck("契约 看门狗2500ms", LiveConfig.watchdogMs == 2500, "1500 太紧：收尾那一秒实测到过 1489")
ck("契约 出帧判据500ms", LiveConfig.warmAgeMs == 500,
   "PC 要求用 output_age_ms<500 判首帧，不能用 has_output（热态下一直是 true）")

// 预热/首帧判据：只认 output_age_ms。PC 热态实测 5–26ms，冷启动首帧前是 null。
ck("预热 热态5ms 算出帧", LiveWatch.warm(outputAgeMs: 5))
ck("预热 26ms 算出帧", LiveWatch.warm(outputAgeMs: 26))
ck("预热 499ms 算出帧", LiveWatch.warm(outputAgeMs: 499))
ck("预热 500ms 边界算出帧", !LiveWatch.warm(outputAgeMs: 500),
   "500 本身不算「刚出过帧」，要更严一点")
ck("预热 1489ms 算没出帧", !LiveWatch.warm(outputAgeMs: 1489))
ck("预热 无读数(null)算没出帧", !LiveWatch.warm(outputAgeMs: nil),
   "冷启动一帧未出时 output_age_ms 是 null")

// 停帧报警的前提：手机这一秒确实在发帧（PC 实测 398 帧全 204、稳定约 13fps）
ck("看门狗 1489ms+13fps 不报", !LiveWatch.stalled(outputAgeMs: 1489, localFPS: 13))
ck("看门狗 2600ms+13fps 报", LiveWatch.stalled(outputAgeMs: 2600, localFPS: 13))
ck("看门狗 2600ms+0fps 不报", !LiveWatch.stalled(outputAgeMs: 2600, localFPS: 0),
   "自己停手/拖进度条重建 reader 的那一秒不出帧，不是 PC 挂了")
ck("看门狗 没出过帧(null)不报", !LiveWatch.stalled(outputAgeMs: nil, localFPS: 13),
   "预热期 output_age_ms 是 null，不能当 PC 挂了")
ck("看门狗 2500ms 边界", !LiveWatch.stalled(outputAgeMs: 2500, localFPS: 13),
   "阈值本身不算超")

// 配了目标脸却没换：解释只读 PC 下发的 best_sim/match_thr，门槛不写死
ck("解释 没配目标脸要说清", (PlanHint.explain(planCount: 0, swappedFaces: 0,
                                          bestSim: 0.1, matchThr: 0.3) ?? "")
   .contains("还没配目标脸"),
   "空表是 PC 的正常行为，不是故障，但得让用户知道要先传脸")
ck("解释 空表不露-1.0", !(PlanHint.explain(planCount: 0, swappedFaces: 0,
                                        bestSim: -1, matchThr: 0.3) ?? "")
   .contains("-1.0"))
ck("解释 已经换了不说", PlanHint.explain(planCount: 2, swappedFaces: 1,
                                     bestSim: 0.1, matchThr: 0.3) == nil)
ck("解释 老PC没字段不说", PlanHint.explain(planCount: 1, swappedFaces: 0,
                                       bestSim: nil, matchThr: nil) == nil,
   "老 PC 不读这两个字段也能照常推流")
ck("解释 没检到可比的脸", (PlanHint.explain(planCount: 1, swappedFaces: 0,
                                        bestSim: -1, matchThr: 0.3) ?? "")
   .contains("还没检到可比的脸"),
   "-1 是哨兵值，不是负相似度，也不许把 -1.0 显示出来")
ck("解释 0.1x 判不是同一人", (PlanHint.explain(planCount: 2, swappedFaces: 0,
                                           bestSim: 0.12, matchThr: 0.3) ?? "")
   .contains("不是视频里同一个人"))
ck("解释 0.2x 判太小太糊", (PlanHint.explain(planCount: 1, swappedFaces: 0,
                                         bestSim: 0.24, matchThr: 0.3) ?? "")
   .contains("照片太小或太糊"))
ck("解释 门槛用PC下发的", (PlanHint.explain(planCount: 1, swappedFaces: 0,
                                       bestSim: 0.24, matchThr: 0.5) ?? "").contains("0.50"),
   "不许把 0.30 写死在手机里")
ck("解释 过了门槛只提示再等", (PlanHint.explain(planCount: 1, swappedFaces: 0,
                                          bestSim: 0.35, matchThr: 0.3) ?? "")
   .contains("可能刚起播"))
ck("契约 PC默认端口5100", LiveConfig.defaultPort == 5100,
   "5000 已被另一台程序占用，换脸服务长期在 5100")
ck("契约 预填地址用5100", LiveConfig.suggestedHost.hasSuffix(":5100"),
   LiveConfig.suggestedHost)
ck("契约 预填那台能解析成地址", LiveHost.base(LiveConfig.suggestedHost) != nil,
   LiveConfig.suggestedHost)

// 客户端默认值与地址解析共用一条路
ck("客户端 坏地址建不出来", SwapClient(hostText: "192.168.1.20/login") == nil)
let c = SwapClient(baseURL: URL(string: "http://192.168.1.9:5000")!)
ck("客户端 宽度先用兜底640", c.liveWidth == LiveConfig.fallbackMaxWidth)
ck("客户端 首页URL", c.pageURL.absoluteString == "http://192.168.1.9:5000")
ck("客户端 结果流URL", c.feedURL.absoluteString == "http://192.168.1.9:5000/video_feed")
ck("客户端 本地计数从0", c.framesSent == 0 && c.framesDroppedLocal == 0)

// MARK: - 会话失效的判定（PC 的 login_required 对 POST 也是 302→200 登录页）

ck("会话 200+登录页路径判丢", LiveAuth.lostSession(statusCode: 200, path: "/login",
                                                   contentType: "text/html"))
ck("会话 200+带子路径的登录页", LiveAuth.lostSession(statusCode: 200, path: "/login?next=1",
                                                     contentType: nil))
ck("会话 200+HTML 判丢", LiveAuth.lostSession(statusCode: 200, path: "/live_frame",
                                              contentType: "text/html; charset=utf-8"))
ck("会话 200+空body的登录页跳转判丢", LiveAuth.lostSession(statusCode: 200, path: "/login",
                                                           contentType: "text/html"))
ck("会话 401 判丢", LiveAuth.lostSession(statusCode: 401, path: "/live_frame", contentType: nil))
ck("会话 非 /live_ 的 200+HTML 不算丢",
   !LiveAuth.lostSession(statusCode: 200, path: "/uploads/nope", contentType: "text/html"),
   "别处回 HTML 是 404 那一类，不是被弹回登录页")
ck("会话 403 判丢", LiveAuth.lostSession(statusCode: 403, path: "/live_frame", contentType: nil))
ck("会话 204 正常收帧不判丢", !LiveAuth.lostSession(statusCode: 204, path: "/live_frame",
                                                    contentType: nil))
ck("会话 409 不算掉登录", !LiveAuth.lostSession(statusCode: 409, path: "/live_frame",
                                                contentType: "application/json"))
ck("会话 405 不算掉登录", !LiveAuth.lostSession(statusCode: 405, path: "/live_stop",
                                                contentType: "text/html"),
   "PC 那 405 回的是 HTML：错方法不该被归成「会话丢了」")
ck("会话 503 不算掉登录", !LiveAuth.lostSession(statusCode: 503, path: "/live_frame",
                                                contentType: "application/json"))
ck("会话 413 不算掉登录", !LiveAuth.lostSession(statusCode: 413, path: "/live_frame",
                                                contentType: "application/json"))

// 一帧的归类：非 2xx 一律不算「送到」，不然 fps 账目会骗人
typealias V = LiveAuth.FrameVerdict
func jd(_ code: Int, _ path: String = "/live_frame", _ ct: String? = nil) -> V {
    LiveAuth.judge(statusCode: code, path: path, contentType: ct)
}
ck("归类 204 算送到", jd(204) == .accepted)
ck("归类 200+json 算送到", jd(200, "/live_frame", "application/json") == .accepted)
ck("归类 409 算退出推流", jd(409) == .notLive)
ck("归类 400 解不开算拒", jd(400, "/live_frame", "application/json") == .rejected(400))
ck("归类 413 超上限算拒", jd(413) == .rejected(413))
ck("归类 503 没起流水线算拒", jd(503) == .rejected(503))
ck("归类 415 算拒不算送到", jd(415, "/login") == .sessionLost,
   "落到 /login 就是被弹走了，跟着重定向拿回来的 415 也算会话丢")
ck("归类 405 算拒", jd(405, "/live_stop", "text/html") == .rejected(405))
ck("归类 500 算拒", jd(500) == .rejected(500))

// MARK: - 页面会话 cookie（WK 的 store → 原生请求头）

func cookie(_ value: String, domain: String?, path: String = "/",
            secure: Bool = false) -> HTTPCookie? {
    var p: [HTTPCookiePropertyKey: Any] = [.name: "session", .value: value, .path: path,
                                           .version: 0]
    if let d = domain { p[.domain] = d }
    if secure { p[.secure] = "TRUE" }
    return HTTPCookie(properties: p)
}

let phost = "192.168.31.100"
let liveURL = URL(string: "http://192.168.31.100:5100/live_start")!
let frameURL = URL(string: "http://192.168.31.100:5100/live_frame")!
let wkCookie = cookie("eyJh.b.c", domain: phost)!
let moved = CookieBridge.normalized(wkCookie, host: phost)!
ck("cookie 重建保留名值", moved.name == "session" && moved.value == "eyJh.b.c")
ck("cookie 拼头", CookieBridge.header([moved], for: liveURL) == "session=eyJh.b.c",
   String(describing: CookieBridge.header([moved], for: liveURL)))
ck("cookie 主机归一", CookieBridge.hostOf(liveURL) == phost)
ck("cookie 换主机不拼",
   CookieBridge.header([moved], for: URL(string: "http://192.168.31.101:5100/live_start")!) == nil)
ck("cookie 别的域不搬",
   CookieBridge.normalized(cookie("v", domain: "example.com")!, host: phost) == nil)
let parentDomain = CookieBridge.normalized(cookie("v", domain: ".example.com")!,
                                           host: "a.example.com")?.domain
ck("cookie 父域保留原写法",
   parentDomain == ".example.com" || parentDomain == "example.com",
   String(describing: parentDomain))
ck("cookie 同名后一条生效",
   CookieBridge.header([moved, cookie("new", domain: phost)!], for: liveURL) == "session=new")
ck("cookie 精确路径匹配",
   CookieBridge.header([cookie("v", domain: phost, path: "/live_frame")!], for: frameURL)
       == "session=v")
ck("cookie 路径不匹配不拼",
   CookieBridge.header([cookie("v", domain: phost, path: "/live_frame")!], for: liveURL) == nil)
ck("cookie Secure 不往 http 送",
   CookieBridge.header([cookie("v", domain: phost, secure: true)!], for: liveURL) == nil)

// MARK: - 原声跟播的对齐量

// PC 重启后出流改为 640 全分辨率、q70、12.8fps：输出年龄峰值 ~78ms，和输入年龄相加仍在
// 实测的 155–207ms 一帧附近；公式不变，只是随读数自己变小。
ck("音频 用两个年龄之和", LiveAudio.measuredDelay(inputMs: 40, outputMs: 160) == 0.2,
   "\(String(describing: LiveAudio.measuredDelay(inputMs: 40, outputMs: 160)))")
ck("音频 输出太老不当延迟", LiveAudio.measuredDelay(inputMs: 30, outputMs: 4000) == nil,
   "/live_start 不清上一轮 latest_frame，闲置很久后的 output_age 是旧账")
ck("音频 缺读数不当延迟", LiveAudio.measuredDelay(inputMs: nil, outputMs: 100) == nil)
ck("音频 下限 50ms", LiveAudio.measuredDelay(inputMs: 1, outputMs: 1) == 0.05)
ck("音频 上限 600ms", LiveAudio.measuredDelay(inputMs: 500, outputMs: 600) == 0.6)
ck("音频 起播兜底 200ms", LiveAudio.startDelay(inputMs: nil, outputMs: nil) == 0.20)

// MARK: - 判定

if fails == 0 {
    print("LIVE-VERDICT PASS \(checks)/\(checks)")
} else {
    print("LIVE-VERDICT FAIL \(fails)/\(checks)")
    exit(1)
}
