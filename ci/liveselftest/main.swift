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
// 页面改完特征（re_rendered）会自己调 refreshStream 再开一条 /video_feed；
// iOS 旧的多部分流连接不马上释放，改 5 次攒满每主机 6 条后整页 fetch 卡死。
ck("脚本 流活着时不重连", shim.contains("feedOk && !feedBroken && !feedAllow")
   && shim.contains("跳过重连"), "0.23 实测：改 5 次特征攒满 6 条 /video_feed 后轮询归零")
ck("脚本 回前台补重连", shim.contains("visibilitychange")
   && shim.contains("feedAllow = true") && shim.contains("feedAllow) refreshFeed()"),
   "后台可能把长连接挂断且不报 error，回前台要自己补一次")
ck("脚本 首帧靠尺寸兜底", shim.contains("feedImg.naturalWidth > 0"), "load 事件在 WebKit 上不一定每帧都来")
ck("脚本 页面卡死自愈", shim.contains("function noteStateOk()")
   && shim.contains("stateEver") && shim.contains("location.reload()"),
   "轮询曾经通过、又 10 秒没回话：整页重载，别让用户只能重开 App")
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

// 0.25：全屏 = VR 鱼眼左右屏。只弯显示，不动协议、不动推流，所以这一组检查全在
// 「有没有偷偷多开一条流 / 有没有把页面的点击吃掉」这类越界动作上。
let vrFrom = shim.range(of: "// —— 全屏 VR")
let vrTo = shim.range(of: "// —— 页面侧日志")
let vrBlock = (vrFrom != nil && vrTo != nil && vrFrom!.upperBound < vrTo!.lowerBound)
    ? String(shim[vrFrom!.lowerBound..<vrTo!.lowerBound]) : ""
ck("VR 段找得到", vrBlock.count > 2000, vrBlock.isEmpty ? "整段没截到" : "只截到 \(vrBlock.count) 字")
ck("VR 不发任何请求", !vrBlock.contains("fetch(") && !vrBlock.contains("XMLHttpRequest")
   && !vrBlock.contains("video_feed"),
   "多开一条 /video_feed 就是把 0.24 刚修好的连接额度泄漏再犯一遍")
ck("VR 跟着全屏开关", shim.contains("try { vrSetOn(on); }")
   && vrBlock.contains("function vrStart()") && vrBlock.contains("function vrStop()"),
   "用户要的就是「点全屏 = 塞进眼镜」，不另设入口")
ck("VR 光学照 vr3d 原式", vrBlock.contains("float R = 0.5 * sqrt(w * w + h * h);")
   && vrBlock.contains("float sc = 1.0 + uK * (dx * dx + dy * dy) / (R * R);")
   && vrBlock.contains("gl.uniform1f(vr.u.uK, vr.fish * 2)"),
   "半径按自家半幅对角的一半归一、强度翻倍成 k，都和 Shaders.metal 的 kSbsFish 一致")
ck("VR 出界涂黑不裁图", vrBlock.contains("if (sx < 0.0 || sx >= w || sy < 0.0 || sy >= h)")
   && vrBlock.contains("if (tx < 0.0 || tx > 1.0 || ty < 0.0 || ty > 1.0)"),
   "黑只落在画框外那一圈：源图一个像素都不丢，这是 vr3d 那边「遮画框方向反了」的教训")
ck("VR 一帧画两遍两半", vrBlock.contains("for (var i = 0; i < 2; i++)")
   && vrBlock.contains("slot: -1") && vrBlock.contains("slot: 1"),
   "两半各装整幅；间距按 slot 反号才是互相推远")
ck("VR 竖屏换上下两半并转 90", vrBlock.contains("var base = portrait ? 1 : 0;")
   && vrBlock.contains("rot: (base + vr.extra) % 4"),
   "竖屏视口里 rect 向下就是物理向右，两半得上下摞、内容再转 90°")
ck("VR 不吞画面上的点击", vrBlock.contains("background:#000;pointer-events:none;"),
   "canvas 盖住整屏，点了还要能唤出控件")
ck("VR 层压得住页面全屏", vrBlock.contains("html.fs #live-vr-canvas")
   && vrBlock.contains("visibility:visible !important")
   && vrBlock.contains("'#live-vr-row{display:none;}'"),
   "页面全屏把 body 下所有东西 visibility:hidden，注入元素不在它名单里；非全屏时那一行不许挡普通页面")
ck("VR 参数行不被忙闸打灰", vrBlock.contains("html.pc-busy #live-vr-row")
   && vrBlock.contains("pointer-events:auto !important"),
   "忙闸那条 html.pc-busy input 会把滑杆灰掉，和页面 #thr-bar 是同一条口子")
ck("VR 参数存本地", vrBlock.contains("var VR_LS = 'live.vr.';")
   && vrBlock.contains("localStorage.getItem(VR_LS + key)"),
   "镜片间距是硬件，一次对好就一直用")
ck("VR 没 WebGL 就退回原画面", vrBlock.contains("vr.dead = true;")
   && vrBlock.contains("if (vr.running || vr.dead) return;"),
   "起不来时页面那张 img 本来就在，不能把画面整个弄没")
ck("VR 二次进全屏接着用同一块画布",
   vrBlock.contains("if (vr.canvas && !vr.canvas.parentNode) document.body.appendChild(vr.canvas);")
   && !vrBlock.contains("vr.canvas = null;"),
   "上下文长在元素上：摘了元素又把手上的引用置空，第二次进全屏就在 vr.canvas.width 上炸")
ck("VR 重画限 15fps", vrBlock.contains("var VR_DRAW_MS = 66;")
   && vrBlock.contains("if (!force && now - vr.lastDraw < VR_DRAW_MS) return;")
   && vrBlock.contains("preserveDrawingBuffer: true"),
   "画面在眼镜里跟着头一起动，刷新率不产生流畅度；0.25 那版每秒 60 次两遍全屏是白烧 GPU，"
   + "而手机这会儿正同时抽帧编码发上行")
// 0.26：用户报「鱼眼视频有点小」。鱼眼本身就是把整幅往中心挤，强度越高越小，
// 所以补一颗放大——它只改读源图的步幅，弯曲张量仍按屏幕位置算（镜片是按角度压的）。
ck("VR 有放大这一颗", vrBlock.contains("'uniform float uZoom;'")
   && vrBlock.contains("float sx = dx * sc / uZoom + w * 0.5;")
   && vrBlock.contains("gl.uniform1f(vr.u.uZoom, vr.zoom)")
   && vrBlock.contains("id=\"vr-zoom\"") && vrBlock.contains("bind('vr-zoom', 'zoom'"),
   "放大要沿两根轴一起生效，且要出现在参数行里——用户嫌小就得能自己拧")
ck("VR 放大默认能补回鱼眼的挤", vrBlock.contains("zoom: vrGet('zoom', 1.25)"),
   "鱼眼 0.35 时画面边缘被挤掉约 12%，默认 1.25 刚好吃满这一半的框")

// 「卡顿怪谁」这条要靠日志分段：perf 行 10 秒一条，没有 VR 进出的边界就分不出
// 开 VR 前后哪段往返高；机身热档位则是手机这一侧唯一能自证的证据。
ck("VR 进出各记一行", vrBlock.contains("'VR 层开：'") && vrBlock.contains("'VR 层关：这次开了 '"),
   "下一次再报卡，先能在日志里把开着 VR 的那段和没开的那段切开")
ck("发热档位进 perf 行", LivePerf.thermalLabel(.nominal).isEmpty
   && LivePerf.thermalLabel(.fair) == "偏热" && LivePerf.thermalLabel(.serious) == "很热"
   && LivePerf.thermalLabel(.critical) == "过热降频",
   "正常时不占那一行的地方；一升档就要看得见，节流是看不见的")
ck("perf 行带得上机身档位", LivePerf.line(sourceFPS: 25, encodeMs: 8, gapMs: 90,
                                        rttAvgMs: 60, rttMaxMs: 120) == "源 25fps｜编码 8ms｜发间隔峰 90ms｜往返 60/120ms"
   && LivePerf.line(sourceFPS: 25, encodeMs: 8, gapMs: 90, rttAvgMs: 60, rttMaxMs: 120,
                    thermal: "偏热").hasSuffix("｜机身偏热"),
   "默认空串时那一截整个省掉，别留个光秃秃的分隔符")

// 0.27：0.25 那轮日志里 09:16:11–09:17:18 有 68 行「登录失效了」，而 PC 那边只回过
// 两秒的 401，之后每一帧都是 204。红字是上一轮留下的、谁都只写不擦；节流又只有一个格子，
// 两条告警换着 key 写就把 10 秒的节流顶没了。这两条不修，日志就会一直把人往
// 一个根本不存在的故障上带——我这次就先被它带偏了一回。
ck("红字 只有真收到帧才擦", LiveAuth.clearsLastError(.accepted)
   && !LiveAuth.clearsLastError(.sessionLost) && !LiveAuth.clearsLastError(.notLive)
   && !LiveAuth.clearsLastError(.rejected(413)),
   "擦早了就是把 401 也一起藏了；擦晚了就是 0.25 那一轮那样挂满一分钟")
var gate0 = LiveWarnGate()
ck("节流 换着 key 轮流说也拦得住",
   gate0.allow("err", now: 0, every: 10) && gate0.allow("fps", now: 1, every: 10)
   && !gate0.allow("err", now: 2, every: 10) && !gate0.allow("fps", now: 3, every: 10)
   && gate0.allow("err", now: 10.5, every: 10),
   "旧写法只记「上一句是谁」：两句轮流写同一格，谁都不算自己的重复，节流形同没有")
ck("节流 一秒一条的活数不误伤", gate0.allow("fps", now: 11.5, every: 0.9)
   && gate0.allow("fps", now: 12.5, every: 0.9),
   "perf 那行是给用户看的活数，看门狗一秒一次，节流按 0.9 秒才不会把它压成十分钟一条")
gate0.reset()
ck("节流 新一轮开头说得出口", gate0.allow("err", now: 13, every: 60),
   "起播以后先把上一轮的静默期清空，不然新一轮开头那句该报的话被压住")

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
// PC 页面自绘确认框（0.21 起替代原生 confirm）：忙闸只拦发给 PC 的命令，
// 框里的确定/取消/输入是页面自己的界面，拦了就是「退出按了没反应」「重命名打不了字」。
ck("忙闸 确认框不拦", LiveShim.dialogSelector == ".qdialog"
   && shim.contains("var QD_SEL = ") && shim.contains("closest(QD_SEL)")
   && shim.contains("html.pc-busy .qdialog"),
   "整框放行：只放按钮会让点遮罩取消失效，只放遮罩又会让输入框打不了字")

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
// 0.28：往返 425ms 那一轮只有 7fps——不是手机算不动（编码 9–10ms），是同时只许 3 帧在路上。
// fps ≈ 在途格数 ÷ 往返，所以能救这一场的只有把窗口放开；下面这组数就是放开的刻度。
ck("窗口 没测到往返不放开", LiveWindow.limit(rttAvgMs: 0) == LiveWindow.base,
   "开局没有往返读数时按 PC 平时要的 3 起步，别一上来就比别人贪")
ck("窗口 链路快用 PC 要的3", LiveWindow.limit(rttAvgMs: 20) == 3
   && LiveWindow.limit(rttAvgMs: 100) == 3 && LiveWindow.limit(rttAvgMs: 200) == 3,
   "200ms 以内 3 条就填得满 15fps，多开的连接只会挤 PC 的入口队列")
ck("窗口 250ms 开4格", LiveWindow.limit(rttAvgMs: 250) == 4, "0.25×15=3.75 向上取整")
ck("窗口 425ms 开满把节奏抬一倍", LiveWindow.limit(rttAvgMs: 425) == LiveWindow.ceiling
   && 3 / 0.425 < 8 && Double(LiveWindow.ceiling) / 0.425 > 14,
   "这一档就是用户报的那次卡顿：3 格只有 7.1fps，6 格 14.1fps；要真追平 15fps 得 6.4 格，被池子顶在 6")
ck("窗口 往返再差也只到上限", LiveWindow.limit(rttAvgMs: 1000) == LiveWindow.ceiling
   && LiveWindow.limit(rttAvgMs: 99999) == LiveWindow.ceiling,
   "顶到 6 以上会挤爆 URLSession 每主机 9 条（帧 6 + 轮询 + 控制），0.24 那次按钮冻死就是池子满了")
ck("窗口 往返回落自己缩回去", LiveWindow.limit(rttAvgMs: 425) == 6
   && LiveWindow.limit(rttAvgMs: 60) == 3, "不缩回去就等于永久改掉了 PC 要的 2–3 帧在途")
// 状态行那一截：没放开时别占地方，放开了必须写得出格数
ck("账目 没放开不写在途", !LivePerf.line(sourceFPS: 24, encodeMs: 9, gapMs: 0,
    rttAvgMs: 425, rttMaxMs: 900, inflightMax: 3).contains("在途"))
let perfWindow = LivePerf.line(sourceFPS: 24, encodeMs: 9, gapMs: 0,
                               rttAvgMs: 425, rttMaxMs: 900, inflightMax: 6)
ck("账目 放开写在途格数", perfWindow.contains("在途≤6"), perfWindow)

// 0.28 起播缓发：这是用户直接要的那条（「开始播时稍微延迟开始，播放中保持连续」）。
// 它不是保守——PC 冷启动那一秒入口队列正一次性丢一大批帧，手机那 18 帧全撞在闸上。
ck("缓发 头几帧按三分之一速", LivePace.interval(full: 1.0 / 15.0, emitted: 0) == 3.0 / 15.0
   && LivePace.interval(full: 1.0 / 15.0, emitted: LiveConfig.rampFrames - 1) == 3.0 / 15.0,
   "6 帧 × 0.2 秒 = 1.2 秒，正好盖住 PC 那一段预热")
ck("缓发 到点自己回全速", LivePace.interval(full: 1.0 / 15.0, emitted: LiveConfig.rampFrames) == 1.0 / 15.0
   && LivePace.interval(full: 1.0 / 15.0, emitted: 999) == 1.0 / 15.0,
   "只顶开头那几帧；一直缓下去就是每小时少发两万帧，用户要的「播放中保持连续」反倒没了")
ck("缓发 不改抽帧判据", LivePace.decide(ptsSeconds: 0.2, nextEmitSeconds: 0.2,
                                         interval: 3.0 / 15.0).emit
   && !LivePace.decide(ptsSeconds: 0.167, nextEmitSeconds: 0.2, interval: 3.0 / 15.0).emit,
   "缓发只把间隔拉长，抽帧还是同一套 PTS 比较——两处一起改就没人说得清开头那几帧是谁丢的")

// MARK: - 和 PC 契约绑死的几个数

ck("契约 在途上限3", LiveConfig.inflightLimit == 3)
ck("契约 推送15fps", LiveConfig.pushFPS == 15.0)
// 0.25 仍是 640：全屏 VR 只在显示端弯像素，推流参数不动。
ck("契约 请求宽640", LiveConfig.fallbackMaxWidth == 640)
ck("契约 UA带版本", LiveConfig.userAgentSuffix == "LiveSwap/0.28"
   && LiveConfig.appVersion == "0.28" && LiveConfig.appBuild == "28")
// 页面在推流中改特征时发的动作：是命令，不是按钮挂子，所以不进 actionNames
//（就绪对账只该对页面里那三个按钮）。
ck("契约 改特征先停动作", LiveShim.hookStopForEdit == "stopedit"
   && !LiveShim.actionNames.contains(LiveShim.hookStopForEdit),
   "\(LiveShim.hookStopForEdit) / \(LiveShim.actionNames)")
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
