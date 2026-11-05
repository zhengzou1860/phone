//
//  ci/liveselftest/main.swift
//  出包前在 mac 上把「没被真编译器碰过、也没被真机器跑过」的那几件事判一遍：
//  地址解析、跳转解析、抽帧节奏、vImage+ImageIO 那条编码通路真的出不出得来 JPEG、
//  注入脚本里的挂子名和 Swift 分发器对不对得上、以及和 PC 契约绑死的那几个数。
//
//  只编 LiveLogic / FrameSource / SwapClient 三个文件：界面那个文件要 UIKit，
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
ck("脚本 占位符全替换掉了", !shim.contains("__HOOKS__") && !shim.contains("__BRIDGE__"))
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
ck("脚本 全屏克隆那份也重连", shim.contains("fullscreen-video"), "全屏里是克隆出来的 img，原图被隐藏着")
ck("转义 引号反斜杠", LiveShim.jsLiteral("a\"b\\c") == "\"a\\\"b\\\\c\"",
   LiveShim.jsLiteral("a\"b\\c"))
ck("转义 中文原样", LiveShim.jsLiteral("推流").hasPrefix("\"推流"))

// MARK: - 和 PC 契约绑死的几个数

ck("契约 在途上限3", LiveConfig.inflightLimit == 3)
ck("契约 推送15fps", LiveConfig.pushFPS == 15.0)
ck("契约 封顶宽640", LiveConfig.fallbackMaxWidth == 640)
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
ck("契约 PC默认端口5100", LiveConfig.defaultPort == 5100,
   "5000 已被另一台程序占用，换脸服务长期在 5100")
ck("契约 预填地址用5100", LiveConfig.suggestedHost.hasSuffix(":5100"),
   LiveConfig.suggestedHost)
ck("契约 预填那台能解析成地址", LiveHost.base(LiveConfig.suggestedHost) != nil,
   LiveConfig.suggestedHost)

// 客户端默认值与地址解析共用一条路
ck("客户端 坏地址建不出来", SwapClient(hostText: "192.168.1.20/login") == nil)
let c = SwapClient(baseURL: URL(string: "http://192.168.1.9:5000")!)
ck("客户端 宽度先用兜底640", c.liveWidth == 640)
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

// MARK: - 判定

if fails == 0 {
    print("LIVE-VERDICT PASS \(checks)/\(checks)")
} else {
    print("LIVE-VERDICT FAIL \(fails)/\(checks)")
    exit(1)
}
