//
//  LiveLogic.swift
//  和 PC 页面打交道时那几件不需要 UIKit 也判得动的事：地址归一、推流节奏、
//  界面挂子（把页面里已有的按钮接到原生）与注入脚本本身。
//
//  这几样单独拎出来放一个文件，是因为本机没有 Swift 工具链：CI 在 mac 上
//  能把这个文件连同 FrameSource/SwapClient 一起 swiftc 跑自测，界面那层跑不动。
//  判据写在这里才测得到，写进界面里就只剩装机以后靠肉眼了。
//

import Foundation
import CoreGraphics

enum LiveConfig {
    static let defaultPort = 5100

    /// PC 那边 /live_start 响应里的 max_width 是权威；这个既是请求值，也是读不到响应时的兜底。
    /// 0.14 试过 800，实测不是带宽先崩：PC 挂 3 张目标脸只算到 3–8fps，手机上看到的就是卡。
    /// 0.19 起退回 640（实测 51–54KB/帧），让 PC 先跟上节奏；再要高清等 PC 那边算力跟上。
    /// 0.24 仍是 640：这一版只给 /video_feed 加重连闸，推流参数不动。
    /// 0.25 仍是 640：全屏 VR 只在显示端弯像素，一帧像素都不多往 PC 发。
    /// 0.26 仍是 640：加放大、降重画频率，全在手机上，跟 PC 说的话一条没多。
    /// 0.27 仍是 640：这一版只擦两笔旧账（红字不跟着新一轮挂、节流按 key 各记各的），
    /// 上行一个字节没动。
    /// 0.28 仍是 640：改的是「同时几条在途」和「开头那 1.2 秒发几条」，一帧的字节数一个字节没动。
    static let fallbackMaxWidth = 640

    static let appVersion = "0.28"
    static let appBuild = "28"

    static let jpegQuality: CGFloat = 0.7
    static let pushFPS: Double = 15

    /// 起播缓发：头 rampFrames 帧的间隔拉长 rampDivisor 倍，之后回到全速。
    /// 用户要的就是这一条（「开始播时稍微延迟开始，播放中保持连续」），它也不是凭空来的——
    /// PC 冷启动那一秒入口队列会一次性丢一大批帧，手机照样 15fps 往上砸：那批帧白占了上行，
    /// 开头那几秒就一顿一顿。抽掉的帧由 PTS 对齐兜着，不会欠成越滚越长的延迟。
    static let rampFrames = 6
    static let rampDivisor = 3

    /// 在途帧窗口的起点。PC 明确要求保持 2–3 帧在途：一帧等一个往返会被单次 RTT 限死节奏
    /// （它第一版测试就是这么只跑到 10fps）。满了丢最旧，绝不排队。
    /// 0.28 起这只是平时值：往返高了 LiveWindow 会临时放开，往返回落自己缩回这个数。
    static let inflightLimit = 3

    /// 注入脚本里 messageHandlers 的名字；Swift 侧注册和脚本发送共用这一条。
    static let bridgeName = "livebridge"
    /// 进度条松手（change）单独走这条桥：页面 postMessage(浮点秒)，原生只管本地 seek。
    static let seekBridgeName = "liveSeek"

    /// PC 输出帧 age 超过这个数、并且手机这一秒确实还在发帧，才认定流水线停了。
    /// 1500 太紧：实测推流收尾那一秒 age 到过 1489，再晚 0.2 秒就报「PC 没出帧」，
    /// 可那是手机自己停的手。正常出帧时 age 只有几十毫秒，2500 留得出余量。
    static let watchdogMs = 2500

    /// 判「PC 已经出帧」只看最近一帧有多新。不能用 has_output：
    /// 热态下上一轮留下的 latest_frame 还挂在服务器上，has_output 从第一秒就是 true，
    /// 拿它当预热结束会得出「首帧 0.0s」这种假读数。
    static let warmAgeMs = 500

    /// 自动重连的节奏：两次之间至少隔这么久，最多试这几次就交回用户处理。
    /// PC 有 10 秒空闲看门狗，掉出推流模式是常事，不试不行；无脑重试会变成打转。
    static let restartGapSeconds: Double = 3.0
    static let maxRestartTries = 3

    /// 追加到 WKWebView 默认 UA 末尾：PC 那边看 access log 就知道是手机 app 在访问，
    /// 而不是有人在浏览器里手点。
    static let userAgentSuffix = "LiveSwap/" + appVersion

    /// 第一次启动时地址栏里预填的这台：PC 侧现在监听的就是它。
    /// 只当预填和提示用，不当写死的配置——PC 重连 WiFi 以后 IP 会变，
    /// 长按改地址那条路必须一直留着。
    static let suggestedHost = "192.168.31.100:5100"
}

// MARK: - PC 地址

enum LiveHost {
    /// 把那一格里可能出现的写法归一成 base URL：
    /// "192.168.1.20"、"192.168.1.20:5100"、"http://192.168.1.20:5100/" 都收，
    /// 带真路径的拒（那种是把页面地址整条粘过来了，让它过去只会在 404 里绕）。
    static func base(_ raw: String, defaultPort: Int = LiveConfig.defaultPort) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let lowered = s.lowercased()
        for scheme in ["http://", "https://"] where lowered.hasPrefix(scheme) {
            s = String(s.dropFirst(scheme.count))
            break
        }

        if let slash = s.firstIndex(of: "/") {
            let tail = s[s.index(after: slash)...]
            guard tail.isEmpty || tail.allSatisfy({ $0 == "/" }) else { return nil }
            s = String(s[..<slash])
        }

        var host = s
        var port = defaultPort
        if let colon = s.lastIndex(of: ":") {
            host = String(s[..<colon])
            let digits = String(s[s.index(after: colon)...])
            guard isDigits(digits), let p = Int(digits), p > 0, p < 65536 else { return nil }
            port = p
        }

        guard !host.isEmpty, host.allSatisfy({ isHostChar($0) }) else { return nil }
        return URL(string: "http://\(host):\(port)")
    }

    /// 给状态行回显用的 "192.168.1.20:5100"
    static func display(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        if let p = url.port { return "\(host):\(p)" }
        return host
    }

    /// 只认 ASCII 的 host 字符集：中文主机名一填，URL(string:) 那条在各系统上表现不一样，
    /// 与其让它随机放行/随机失败，不如在这里就判死并让用户重填。
    private static let hostChars = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_")

    private static func isHostChar(_ c: Character) -> Bool {
        return c.unicodeScalars.allSatisfy { hostChars.contains($0) }
    }

    private static func isDigits(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.allSatisfy { $0 >= "0" && $0 <= "9" }
    }
}

// MARK: - 在途帧窗口

/// 一帧等一个往返，节奏就被往返钉死：3 帧在途、往返 425ms，就只剩 7fps——
/// 用户看到的「卡」就是这个 7fps，不是手机算不动（那两段编码还是 9–10ms）。
/// 所以往返一高就把窗口放开，让管道里始终有帧在走；回落到几十毫秒自己缩回 PC 要的 3。
/// 上限 6 而不是更多：手机这个 URLSession 每主机只开 9 条，要给状态轮询和一次性控制请求
/// 留位置——0.24 那次就是池子被帧占满，页面轮询全排队、按钮冻死。
enum LiveWindow {
    static let base = LiveConfig.inflightLimit      // PC 平时要的 3
    static let ceiling = 6

    /// 要几条才填得满这条管道：每秒想要帧数 × 一个往返。
    /// 夹在 base 和 ceiling 之间：往返再高也不许越过池子，往返再低也不比 PC 要求的更贪。
    static func limit(rttAvgMs: Double, fps: Double = LiveConfig.pushFPS) -> Int {
        guard rttAvgMs > 0 else { return base }
        let need = Int((rttAvgMs * fps / 1000.0).rounded(.up))
        return min(ceiling, max(base, need))
    }
}

// MARK: - 会话失效的判定

enum LiveAuth {
    /// PC 的 login_required 对 GET 和 POST 一律 redirect('/login')，不区分方法；
    /// URLSession 默认跟随 302 并把 POST 降级成 GET，于是 cookie 一失效
    /// /live_frame 就回「200 + 登录页 HTML」——看着像这一帧被收了，实际 PC 一帧没收到，
    /// 盯着一个永远不涨的 fps 找不出原因。所以 200 也要验一下到底是谁回的。
    /// 409（未进推流模式）和 405（方法不对）都不算会话丢：那是另外两条恢复路径的事。
    static func lostSession(statusCode: Int, path: String?, contentType: String?) -> Bool {
        if statusCode == 401 || statusCode == 403 { return true }
        // 原生这边只打 /live_*，落到 /login 就说明被 login_required 弹走了——
        // 状态码是什么不重要（跟随重定向以后可能是 200 的页面，也可能是 415）。
        if let p = path, p.hasPrefix("/login") { return true }
        guard statusCode == 200 else { return false }
        // PC 修掉 /login 闪现那个 bug 以前，任何不存在的路径都回「200 + 登录页 HTML」，
        // 所以这条只认 /live_*：那几个口按契约要么是 204 要么是 JSON，回 HTML 就是被弹走了；
        // 别处（比如 404 页）回 HTML 不该算掉登录。
        guard let p = path, p.hasPrefix("/live_") else { return false }
        if let ct = contentType?.lowercased(), ct.contains("text/html") { return true }
        return false
    }

    /// 一帧的读数归类。四个出口对应四条不同的处置，混在「2xx 就算发出去了」里会看错账：
    /// 400 解不开、413 超 2MB、503 流水线没起、405 方法不对——这些都不算 PC 收到了一帧。
    enum FrameVerdict: Equatable {
        case accepted
        case notLive          // 409：PC 不在推流模式，走重新 /live_start 那条恢复路径
        case sessionLost      // 被弹回登录页，只有重登一条路
        case rejected(Int)    // 其余非 2xx，带上码
    }

    static func judge(statusCode: Int, path: String?, contentType: String?) -> FrameVerdict {
        if lostSession(statusCode: statusCode, path: path, contentType: contentType) {
            return .sessionLost
        }
        if statusCode == 409 { return .notLive }
        if (200..<300).contains(statusCode) { return .accepted }
        return .rejected(statusCode)
    }

    /// 上面两条的 HTTPURLResponse 外壳。
    /// resp.url 就是跟随重定向以后真正取到那一页的地址（登录页时为 /login）；
    /// expectedURL 是缓存用的、iOS 18 起才有，别在这儿用它。
    static func lost(_ resp: HTTPURLResponse) -> Bool {
        let path = resp.url?.path
        let type = resp.value(forHTTPHeaderField: "Content-Type")
        return lostSession(statusCode: resp.statusCode, path: path, contentType: type)
    }

    static func judge(_ resp: HTTPURLResponse) -> FrameVerdict {
        let path = resp.url?.path
        let type = resp.value(forHTTPHeaderField: "Content-Type")
        return judge(statusCode: resp.statusCode, path: path, contentType: type)
    }

    /// 屏幕上那行红字什么时候擦。以前谁都只写不擦：用户重登、重新起播以后
    /// 帧明明一路走到 55KB/帧，界面却还每秒贴一句「登录失效了」，
    /// 看日志的人就照着这句话去找一个根本不存在的故障。
    /// 只有 PC 真收下了一帧才擦；401、409、被拒那三条得留着，那是真该看见的。
    static func clearsLastError(_ verdict: FrameVerdict) -> Bool {
        if case .accepted = verdict { return true }
        return false
    }

    /// 给用户看的那一句：重新搬一次 cookie 还是 401，页面那边就得重登了。
    static let lostMessage = "登录失效了（PC 回 401 未登录）：在这一页重新登录，再点「播放」接着推"
}

// MARK: - 告警不刷屏

/// 同一句话最多多少秒说一遍。以前整个界面共用一个格子记「上次说的是哪句」：
/// 看门狗里「会话失效」和 perf 行一秒换一次 key，谁都不算自己的连续重复，
/// 10 秒的节流形同没有——0.25 那轮日志里「登录失效」和 perf 行就是这么每秒贴在一起贴了一分多钟。
/// 每个 key 自己记自己的上次时间，轮流说话也拦得住。
struct LiveWarnGate {
    private var last: [String: TimeInterval] = [:]

    mutating func allow(_ key: String, now: TimeInterval, every: TimeInterval) -> Bool {
        if let t = last[key], now - t < every { return false }
        last[key] = now
        return true
    }

    /// 新一轮起播：上一轮的静默期不该压住这一轮开头该说的话。
    mutating func reset() { last = [:] }
}

// MARK: - 页面会话 cookie

/// 页面登录出来的会话在 WKWebView 自己的 cookie store 里，原生 URLSession 看不见。
/// 这里把 WK 取回来的 cookie 统一成「按页面主机算」的一份，再直接拼成 Cookie 头发出去：
/// 不经过 HTTPCookieStorage —— WK 对 IP 主机给回来的 cookie 可能没有 domain，
/// 原样 setCookie 会被静默丢掉，症状正是「页面 200、原生 /live_start 401」。
enum CookieBridge {
    /// 页面和原生用的是同一个 baseURL，这里只做小写归一。
    static func hostOf(_ url: URL) -> String { (url.host ?? "").lowercased() }

    /// 重建一份能按页面主机匹配的 cookie。WK 对 IP 主机可能把 domain 丢空，那一条按页面主机补；
    /// 是本页父域的（正常域名场景）保留原写法；别的站点的 cookie 一律不带，别往这台 PC 上误送。
    static func normalized(_ cookie: HTTPCookie, host: String) -> HTTPCookie? {
        let h = host.lowercased()
        guard !h.isEmpty, !cookie.name.isEmpty else { return nil }
        let raw = cookie.domain.lowercased()
        let base = raw.hasPrefix(".") ? String(raw.dropFirst()) : raw
        let domain: String
        if base.isEmpty {
            domain = h
        } else if h == base || h.hasSuffix("." + base) {
            domain = cookie.domain
        } else {
            return nil
        }
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .domain: domain,
            .path: cookie.path.isEmpty ? "/" : cookie.path,
            .version: 0,
        ]
        if let d = cookie.expiresDate { props[.expires] = d }
        if cookie.isSecure { props[.secure] = "TRUE" }
        return HTTPCookie(properties: props)
    }

    /// 按 RFC 6265 的规则拼 Cookie 头：域、路径、Secure 都要对得上。
    /// 同名只留最后一条——Werkzeug 解析重复键时也是后一条生效。
    static func header(_ cookies: [HTTPCookie], for url: URL) -> String? {
        let host = hostOf(url)
        guard !host.isEmpty else { return nil }
        let scheme = (url.scheme ?? "").lowercased()
        let path = url.path.isEmpty ? "/" : url.path
        var picked: [String: String] = [:]
        var order: [String] = []
        for c in cookies {
            let raw = c.domain.lowercased()
            let d = raw.hasPrefix(".") ? String(raw.dropFirst()) : raw
            guard !d.isEmpty, host == d || host.hasSuffix("." + d) else { continue }
            if c.isSecure && scheme != "https" { continue }
            let p = c.path.isEmpty ? "/" : c.path
            guard path == p || path.hasPrefix(p.hasSuffix("/") ? p : p + "/") else { continue }
            if picked[c.name] == nil { order.append(c.name) }
            picked[c.name] = c.value
        }
        guard !order.isEmpty else { return nil }
        return order.compactMap { name in
            picked[name].map { "\(name)=\($0)" }
        }.joined(separator: "; ")
    }
}

// MARK: - 跳转输入

enum LiveTime {
    /// 手机上 #video-path 那一格兼作跳转输入：接受 "75"、"75.5"、"1:15"、"01:15:30"。
    /// 解析不出时间的（比如 PC 上的文件路径）返回 nil，调用方就把这一笔原样交回页面自己处理。
    static func parse(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 1 && parts.count <= 3 else { return nil }

        var total = 0.0
        for part in parts {
            guard isNumber(String(part)) else { return nil }
            let v = Double(String(part)) ?? 0
            total = total * 60 + v
        }
        guard total.isFinite else { return nil }
        return total
    }

    /// 给状态行看的 mm:ss
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "-" }
        let t = Int(seconds.rounded())
        if t >= 3600 {
            return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
        }
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private static func isNumber(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var seenDot = false
        var seenDigit = false
        for c in s {
            if c == "." {
                if seenDot { return false }
                seenDot = true
            } else if c >= "0" && c <= "9" {
                seenDigit = true
            } else {
                return false
            }
        }
        return seenDigit
    }
}

// MARK: - 推流节奏

enum LivePace {
    /// 这一帧发还是抽掉。源帧率高于 pushFPS 时按 PTS 抽帧，不靠 sleep 硬压；
    /// 落后了就跟着当前 PTS 重新对齐，不把欠账堆成越滚越长的延迟。
    static func decide(ptsSeconds: Double, nextEmitSeconds: Double?, interval: Double)
        -> (emit: Bool, nextEmitSeconds: Double?) {
        guard ptsSeconds.isFinite, interval > 0 else { return (false, nextEmitSeconds) }
        if let ne = nextEmitSeconds, ptsSeconds < ne { return (false, ne) }
        return (true, ptsSeconds + interval)
    }

    /// 起播那一段把间隔拉长，之后回到全速（LiveConfig.rampFrames/rampDivisor）。
    /// 数的是已经发出去的帧数、不是墙钟：跳转和重建 reader 都从头计，所以那两处也一起缓。
    static func interval(full: Double, emitted: Int) -> Double {
        emitted < LiveConfig.rampFrames ? full * Double(LiveConfig.rampDivisor) : full
    }
}

// MARK: - 流水线停了的判定

enum LiveWatch {
    /// 只有「手机这一秒确实还在发帧」时，PC 输出超龄才算 PC 那边停了。
    /// 手机自己停手、或者拖进度条重建 reader（那一下本来就有近一秒不出帧）时不该报，
    /// 否则用户刚松手就看到「PC 有 Nms 没出帧」，会去查一台根本没问题的电脑。
    static func stalled(outputAgeMs: Int?, localFPS: Double,
                        thresholdMs: Int = LiveConfig.watchdogMs) -> Bool {
        guard let age = outputAgeMs, age > thresholdMs else { return false }
        return localFPS >= 0.5
    }

    /// PC 真的在出帧：最近一帧在 warmAgeMs 以内。没读数（null）也算还没出。
    static func warm(outputAgeMs: Int?, maxAgeMs: Int = LiveConfig.warmAgeMs) -> Bool {
        guard let age = outputAgeMs else { return false }
        return age < maxAgeMs
    }
}

// MARK: - 停止握手

/// 「点了停止」到「PC 确认停止」之间那一段。页面自己每秒才轮询一次，这段时间界面
/// 不能先装作停了：按钮灰着写「停止中…」、特征下拉框全灰，等 /live_stop 明确回成功
/// 才解。请求没送到就停在 failed，按钮换成「重试停止」，下拉框继续锁着——PC 那边
/// 可能还在跑，这时候解锁就是让用户去撞 409，症状和这次要修的一模一样。
enum LiveStopGate: Equatable {
    case idle
    case stopping
    case failed

    /// 注入脚本认的两个状态字：Swift 和 JS 共用这一份，别各写各的。
    static let stoppingState = "stopping"
    static let failedState = "failed"

    static let stoppingNote = "正在停 PC 的推流…等它回话"
    static let failedNote = "停止没送到 PC：推流可能还在跑，点「重试停止」再试一次"

    var blocksPlay: Bool { self != .idle }
    var holdsEditingLock: Bool { self != .idle }

    mutating func begin() { self = .stopping }
    mutating func settle(ok: Bool) { self = ok ? .idle : .failed }
}

// MARK: - 状态行的性能读数

enum LivePerf {
    /// 状态行里那一截。读数为 0 的一律省掉：还没出帧、还没测到往返时，
    /// 一屏 0 只会让人以为坏了。
    /// 机身热档位只在离开「正常」时才写：这一版的 VR 层是不是把手机热到降频，
    /// 是「卡顿到底怪谁」这条上唯一能在手机上取到的证据。
    /// 在途窗口只在放开过 PC 要的那 3 条时才写：不写就分不出「这 7fps 是往返压出来的」
    /// 还是「这 7fps 是手机自己发不出去」。
    static func line(sourceFPS: Double, encodeMs: Double, gapMs: Double,
                     rttAvgMs: Double, rttMaxMs: Double, thermal: String = "",
                     inflightMax: Int = 0) -> String {
        var parts: [String] = []
        if sourceFPS >= 1 { parts.append(String(format: "源 %.0ffps", sourceFPS)) }
        if encodeMs > 0 { parts.append(String(format: "编码 %.0fms", encodeMs)) }
        if gapMs > 0 { parts.append(String(format: "发间隔峰 %.0fms", gapMs)) }
        if rttAvgMs > 0 { parts.append(String(format: "往返 %.0f/%.0fms", rttAvgMs, rttMaxMs)) }
        if inflightMax > LiveWindow.base { parts.append("在途≤\(inflightMax)") }
        if !thermal.isEmpty { parts.append("机身" + thermal) }
        return parts.joined(separator: "｜")
    }

    /// iOS 的热档位。正常时返回空串（不占那一行的地方），偏热往上才写。
    static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return ""
        case .fair: return "偏热"
        case .serious: return "很热"
        default: return "过热降频"
        }
    }

    /// 选片时那一行。源帧率决定按 15fps 抽帧时实际能到多少：
    /// 30fps 素材每两帧取一帧是 15fps，24fps 素材每两帧取一帧只有 12fps。
    static func sourceLabel(_ fps: Double) -> String {
        fps >= 1 ? String(format: "·源 %.0ffps", fps) : ""
    }
}

// MARK: - 原声跟播的对齐量

enum LiveAudio {
    /// 读不到读数时的兜底：PC 实测这条换脸链一帧 155–207ms。
    static let defaultDelay: Double = 0.20
    /// output_age 超过这个数说明 PC 还没开始出帧。`/live_start` 不清上一轮的 latest_frame，
    /// 这时的年龄是「上一轮留了多久」，不是流水线延迟，不能拿来对音。
    static let staleOutputMs = 700

    /// 音轨要落后 reader 多少秒：PC 下发的 input_age_ms + output_age_ms。
    /// 不新鲜就返回 nil：起播时退回 defaultDelay，推流中则先等着，等第一帧新画面出来再对。
    static func measuredDelay(inputMs: Int?, outputMs: Int?) -> Double? {
        guard let i = inputMs, let o = outputMs, i >= 0, o >= 0,
              o < staleOutputMs else { return nil }
        return min(0.6, max(0.05, Double(i + o) / 1000.0))
    }

    static func startDelay(inputMs: Int?, outputMs: Int?) -> Double {
        measuredDelay(inputMs: inputMs, outputMs: outputMs) ?? defaultDelay
    }
}

// MARK: - 配了目标脸却没换时的解释

enum PlanHint {
    /// 「0.1x = 不是同一个人」这条分界只负责选解释文案，不是判定门槛；
    /// 门槛一律用 PC 下发的 match_thr，不把 0.30 写死在手机里。
    static let wrongPersonCeiling = 0.20

    /// 配了目标脸、这一帧却一张都没换：用画面里最像那张脸和 PC 下发的门槛解释原因。
    /// 老版本 PC 没有 best_sim/match_thr 就什么也不说——不猜、不当故障上报。
    static func explain(planCount: Int, swappedFaces: Int,
                        bestSim: Double?, matchThr: Double?) -> String? {
        // 空表不是故障：PC 本来就是一帧都不换，说清楚表里没配就行。
        if planCount == 0 {
            return "还没配目标脸：这一帧不换脸（先在页面上传目标脸、选好替换特征再播）"
        }
        guard swappedFaces == 0 else { return nil }
        guard let best = bestSim, let thr = matchThr else { return nil }
        // -1 是 PC 的哨兵值，意思是画面里没有可比的脸，不是“负相似度”。
        if best < 0 {
            return "目标脸 \(planCount) 张、这一帧没换：画面里还没检到可比的脸"
        }
        let b = String(format: "%.2f", best)
        let t = String(format: "%.2f", thr)
        if best < wrongPersonCeiling {
            return "目标脸 \(planCount) 张、这一帧没换：画面里最像的只有 \(b)（门槛 \(t)）——"
                + "照片里多半不是视频里同一个人，换一张视频里那个人的清晰正脸"
        }
        if best < thr {
            return "目标脸 \(planCount) 张、这一帧没换：最像 \(b) 没过门槛 \(t)——"
                + "是同一个人，但照片太小或太糊"
        }
        return "目标脸 \(planCount) 张、这一帧没换：最像 \(b) 已过门槛 \(t)，"
            + "可能刚起播；一直这样就把 PC 日志发我"
    }
}

/// 没选片时点「播放」该由谁放。PC 的剪辑页「用于换脸」会把路径 POST /set_video 写进
/// 服务端，这时画面是 PC 自己本地的片：手机要放行的正是页面原来的 /start_playback，
/// 不能再弹自己的相册（用户看到的就是「文件名都对，点播放却让选文件」）。
enum LivePlaySource {
    static func usesPCVideo(hasLocalClip: Bool, pcPath: String?) -> Bool {
        if hasLocalClip { return false }
        let p = (pcPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !p.isEmpty && p.lowercased() != "none"
    }
}

// MARK: - 界面挂子与注入脚本

struct LiveHook: Equatable {
    let name: String
    let selector: String
}

enum LiveShim {
    /// 挂子名同时喂给 Swift 的分发器和注入脚本，CI 对拍两边是不是同一套：
    /// 手机看到的 action 只可能是这里列过的，页面里拼错的字符串不会被静默吃掉。
    static let hookPick = "pick"
    static let hookPlay = "play"
    static let hookSeek = "seek"
    /// 页面给 <html> 加/去 class="fs" 时由注入脚本上报，原生据此藏状态栏。
    /// 不是按钮挂子，所以不进 actionNames 的 ready 对账表。
    static let hookFullscreen = "fullscreen"
    /// 不是按钮，是页面加载完主动报上来的一行：界面挂子上没对上号就在这里说出口
    static let hookReady = "ready"

    /// 界面左下角那颗「发日志」：不是页面原有控件，是 App 自己加的
    /// （用户要求不用一段段截图，点一下把运行日志发到电脑）。
    static let hookSendLog = "sendlog"
    /// 页面脚本里的 JS 错误/rejection/console.error，原生写进日志。
    static let hookJsLog = "jslog"
    /// 页面命令（非轮询 fetch）的回话：路径、状态码、耗时、响应体前一段。
    /// 「特征改几次以后改不了」多半是一条 409 的响应体在说话。
    static let hookCmdLog = "cmdlog"
    /// /get_playback_state 变了才报：前台按钮和后台状态对不上时，这里是两边的时间线。
    static let hookPageState = "pagestate"
    /// 页面在推流中要改特征：先发这个动作，让原生按用户点「停止」的同一条握手
    /// 把 PC 停下；页面自己轮询 /get_playback_state，确认 live_mode/edit_locked
    /// 都落了再提交修改。不是按钮挂子，不进 actionNames（就绪对账只对按钮）。
    static let hookStopForEdit = "stopedit"
    static let logButtonSelector = "#live-log-btn"

    /// 跳转没有按钮了：PC 撤掉了「设置视频路径」，现在由这一格的回车触发。
    /// 页面自己的回车会直接 POST /set_video，手机上那是本地文件名，
    /// 必须在捕获阶段截下来改成“跳到第几秒”。
    static let pathSelector = "#video-path"

    /// PC 页面自绘确认框的容器（0.21 起替代原生 confirm/prompt）。
    /// 忙闸只该拦「发给 PC 的命令」；框里的确定/取消/输入是页面自己的界面，
    /// 拦掉的表现就是「点了退出没反应」「重命名特征打不了字」。认 class 不认 id。
    static let dialogSelector = ".qdialog"

    /// 点击挂子只剩两个：三条挂子的选择器就是 PC 页面 templates/index.html 里已有的元素，
    /// 手机上不新增任何控件，只把已有按钮接到原生。跳转走 keydown，不进这张表。
    static let hooks: [LiveHook] = [
        LiveHook(name: hookPick, selector: "#select-file-btn"),
        LiveHook(name: hookPlay, selector: "#start-button"),
    ]

    static var actionNames: [String] { hooks.map { $0.name } + [hookSeek] }

    /// 注入脚本用的 JSON 字面量：引号反斜杠交给 JSONSerialization，不自己拼转义。
    static func jsLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
              var text = String(data: data, encoding: .utf8),
              text.count >= 2 else {
            return "\"\""
        }
        text.removeFirst()
        text.removeLast()
        return text
    }

    /// document 捕获阶段拦点击：页面自己的 onclick 是挂在元素上的，
    /// 在 document 上 stopPropagation 就够不着它了——所以能换掉行为而不动版面。
    static func source() -> String {
        let pairs = hooks.map { "[\(jsLiteral($0.name)),\(jsLiteral($0.selector))]" }
                        .joined(separator: ",")
        return template.replacingOccurrences(of: "__HOOKS__", with: "[" + pairs + "]")
                          .replacingOccurrences(of: "__PATH__", with: jsLiteral(pathSelector))
                          .replacingOccurrences(of: "__SEEK__", with: jsLiteral(hookSeek))
                          .replacingOccurrences(of: "__FULLSCREEN__", with: jsLiteral(hookFullscreen))
                          .replacingOccurrences(of: "__STOPPING__", with: jsLiteral(LiveStopGate.stoppingState))
                          .replacingOccurrences(of: "__FAILED__", with: jsLiteral(LiveStopGate.failedState))
                          .replacingOccurrences(of: "__BRIDGE__", with: jsLiteral(LiveConfig.bridgeName))
                          .replacingOccurrences(of: "__LOG__", with: jsLiteral(hookSendLog))
                          .replacingOccurrences(of: "__JSLOG__", with: jsLiteral(hookJsLog))
                          .replacingOccurrences(of: "__CMDLOG__", with: jsLiteral(hookCmdLog))
                          .replacingOccurrences(of: "__PAGESTATE__", with: jsLiteral(hookPageState))
                          .replacingOccurrences(of: "__LOGSEL__", with: jsLiteral(logButtonSelector))
                          .replacingOccurrences(of: "__DIALOG__", with: jsLiteral(dialogSelector))
    }

    private static let template = #"""
    (function () {
      'use strict';
      var HOOKS = __HOOKS__;
      var BRIDGE = __BRIDGE__;
      var PATH_SEL = __PATH__;
      var SEEK = __SEEK__;
      var FS = __FULLSCREEN__;
      var STOP_STOPPING = __STOPPING__;
      var STOP_FAILED = __FAILED__;
      var LOG_HOOK = __LOG__;
      var JSLOG = __JSLOG__;
      var CMDLOG = __CMDLOG__;
      var PAGESTATE = __PAGESTATE__;
      var LOG_SEL = __LOGSEL__;
      var QD_SEL = __DIALOG__;

      function send(payload) {
        try {
          var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[BRIDGE];
          if (!h) return false;
          h.postMessage(payload);
          return true;
        } catch (e) { return false; }
      }

      function find(sel) {
        try { return document.querySelector(sel); } catch (e) { return null; }
      }

      document.addEventListener('click', function (ev) {
        var t = ev.target;
        if (!t || !t.closest) return;
        // 「发日志」不是 PC 命令，忙的时候也得点得动：它自己有监听，这里放行。
        if (t.closest(LOG_SEL)) return;
        // 页面自绘确认框同理：确定/取消/输入都只是页面自己的界面，不是发给 PC 的命令。
        // 整个框一起放行——只放按钮会让「点遮罩取消」失效，只放遮罩又会让输入框打不了字。
        if (t.closest(QD_SEL)) return;
        // 忙闸先拦：这条监听注册得比后面的忙闸早，不看一眼就会在等 PC 回话时
        // 把「选择文件 / 播放」再送一遍（样式只挡鼠标，挡不住程序化的 click）。
        if (busyNow()) { ev.preventDefault(); ev.stopPropagation(); return; }
        for (var i = 0; i < HOOKS.length; i++) {
          var el = find(HOOKS[i][1]);
          if (!el || !el.contains(t)) continue;
          ev.preventDefault();
          ev.stopPropagation();
          send({ action: HOOKS[i][0] });
          return;
        }
      }, true);

      // 「设置视频路径」那颗按钮 PC 已经撤了，路径格回车会直接 POST /set_video。
      // 手机上那一格填的是本地文件名或跳转秒数，不能让它发给 PC：捕获阶段先拦下，
      // 改成原生的“跳到第几秒”。不带按钮的入口只剩这一条。
      document.addEventListener('keydown', function (ev) {
        if (ev.key !== 'Enter') return;
        var el = find(PATH_SEL);
        if (!el || ev.target !== el) return;
        // 忙的时候路径格可能还留着焦点：回车同样不许把跳转叠进正在等的那一轮。
        if (busyNow()) { ev.preventDefault(); ev.stopPropagation(); return; }
        ev.preventDefault();
        ev.stopPropagation();
        send({ action: SEEK });
      }, true);

      // 手机往页面里写状态一律走页面自己的 showStatus 和 #status-message，
      // 不另外盖一层浮标：界面上看到的字和 PC 上同一格是一个来源。
      //
      // PC 页面自己也有 LiveUI（setPlaying / refreshStream / autoRefresh），
      // 这里只能在它上面补 App 用的几个方法：整个赋一个新对象会把页面那几个冲掉。
      // refreshStream 例外：保留原函数，但包一层重连闸（见下面「/video_feed 重连闸」）。
      var UI = window.LiveUI;
      if (!UI || typeof UI !== 'object') UI = {};
      UI.status = function (msg, kind) {
        try {
          if (typeof showStatus === 'function') { showStatus(msg, kind || 'success'); return 'showStatus'; }
        } catch (e) {}
        var d = document.getElementById('status-message');
        if (d) { d.textContent = msg; return 'status-message'; }
        return 'none';
      };
      UI.path = function (v) {
        var e = document.getElementById('video-path');
        if (!e) return false;
        e.value = v;
        return true;
      };
      UI.readPath = function () {
        var e = document.getElementById('video-path');
        return e ? String(e.value || '') : '';
      };
      UI.report = function () {
        var have = {};
        for (var i = 0; i < HOOKS.length; i++) have[HOOKS[i][0]] = !!find(HOOKS[i][1]);
        have[SEEK] = !!find(PATH_SEL);
        var t = document.querySelector('h1');
        send({ action: 'ready', hooks: have, title: t ? String(t.textContent || '') : '' });
        addLogButton();
      };
      window.LiveUI = UI;

      // —— 界面上的「发日志」 ——
      // 用户不用再一段段截图：点一下，原生把 App 和页面这一轮的运行日志压成几段
      // GET 发到 PC。按钮放左下角，不挡页面顶部状态行和中间的播放区。
      function addLogButton() {
        if (find(LOG_SEL) || !document.body) return;
        var b = document.createElement('button');
        b.id = 'live-log-btn';
        b.type = 'button';
        b.textContent = '发日志';
        b.title = '把 App 的运行日志发到电脑';
        b.setAttribute('style',
          'position:fixed;left:12px;bottom:calc(12px + env(safe-area-inset-bottom));'
          + 'z-index:2147483000;padding:6px 10px;border-radius:14px;'
          + 'border:1px solid rgba(255,255,255,.45);background:rgba(0,0,0,.55);'
          + 'color:#fff;font-size:12px;line-height:1;'
          + '-webkit-user-select:none;user-select:none;touch-action:manipulation;');
        b.addEventListener('click', function (ev) {
          ev.preventDefault();
          ev.stopPropagation();
          send({ action: LOG_HOOK });
        }, true);
        document.body.appendChild(b);
      }
      UI.logSending = function () {
        var b = find(LOG_SEL);
        if (b) { b.disabled = true; b.textContent = '发送中…'; }
      };
      UI.logDone = function (ok, id) {
        var b = find(LOG_SEL);
        if (b) {
          b.disabled = false;
          b.textContent = ok ? ('已发 ' + String(id || '')) : '发日志';
        }
      };

      // 页面自己的 JS 错误也要进同一份日志：很多「点了没反应」是页面脚本抛了异常。
      function jsText(v) {
        try { return typeof v === 'string' ? v : JSON.stringify(v); }
        catch (e) { return String(v); }
      }
      // 页面要是陷在报错循环里，日志不能被它刷爆：10 秒最多 40 条。
      var jsLogWindow = 0;
      var jsLogCount = 0;
      function sendJsLog(level, msg, src, line) {
        var now = Date.now();
        if (now - jsLogWindow > 10000) { jsLogWindow = now; jsLogCount = 0; }
        if (++jsLogCount > 40) return;
        send({ action: JSLOG, level: String(level || ''),
               msg: String(msg || '').slice(0, 600),
               src: String(src || '').slice(0, 160), line: line || 0 });
      }
      window.addEventListener('error', function (ev) {
        if (!ev || !ev.message) return;
        sendJsLog('error', ev.message, ev.filename, ev.lineno);
      }, true);
      window.addEventListener('unhandledrejection', function (ev) {
        var r = ev ? ev.reason : null;
        sendJsLog('reject', (r && (r.message || r)) || 'unhandledrejection');
      });
      try {
        var rawConsoleError = console.error;
        console.error = function () {
          try {
            var parts = [];
            for (var i = 0; i < arguments.length; i++) parts.push(jsText(arguments[i]));
            sendJsLog('console', parts.join(' '));
          } catch (e) {}
          return rawConsoleError.apply(console, arguments);
        };
      } catch (e) {}

      // —— 整页忙闸 ——
      // 手机和 PC 是一问一答的单进程：命令发出到 PC 回话之间，整页不再接点击。
      // 不灰的话用户会一直补点，同一件事在 PC 上排成几份，前后状态互相打架。
      // 只挡命令，不挡每秒轮询——把心跳也挡进去，整页会跟着一秒一闪。
      var BUSY_POLL = ['/get_playback_state', '/api/record/status', '/api/edit/progress'];
      var BUSY_MAX_MS = 15000;  // PC 彻底不回话时别把页面永远锁死，到点放开让用户重试
      var busyFetches = 0;      // 页面自己发出的命令请求
      var busyHold = false;     // 停止握手挂住（原生 setStopPending）
      var busyNative = 0;       // 原生起播/跳转在等 PC（计数：两轮叠在一起也不互相解闸）

      function busyNow() { return busyHold || busyNative > 0 || busyFetches > 0; }

      (function addBusyStyle() {
        try {
          var st = document.createElement('style');
          st.id = 'live-busy-style';
          st.textContent = 'html.pc-busy button,html.pc-busy select,html.pc-busy input,'
            + 'html.pc-busy a[href],html.pc-busy [onclick],html.pc-busy .edit-mode'
            + '{pointer-events:none !important;opacity:.45 !important;}'
            // 下载是顶层导航交给系统的 WKDownload，不是命令，没有“回话”可等：
            // 忙的时候也让它点得动，否则用户点下载会被灰到 15 秒兜底。
            + 'html.pc-busy a[onclick*="downloadFile"]'
            + '{pointer-events:auto !important;opacity:1 !important;}'
            // 发日志同理：它不跟 PC 对话，等回话的时候正好是用户想发日志的时候。
            + 'html.pc-busy #live-log-btn'
            + '{pointer-events:auto !important;opacity:1 !important;}'
            // 页面自绘确认框也不跟 PC 对话。它的确定/取消是 <button>，上面那条
            // pc-busy button 会连 pointer-events 一起关掉，这里按整框恢复（含输入框）。
            + 'html.pc-busy .qdialog,html.pc-busy .qdialog *'
            + '{pointer-events:auto !important;opacity:1 !important;}'
            + 'html.pc-busy,html.pc-busy body{cursor:progress !important;}';
          (document.head || document.documentElement).appendChild(st);
        } catch (e) {}
      })();

      function busySync() {
        try {
          var h = document.documentElement;
          if (busyNow()) h.classList.add('pc-busy');
          else h.classList.remove('pc-busy');
        } catch (e) {}
      }

      // 有些能点的地方不是 button（剪辑页两个模式格是 div，动态加的行也可能不是），
      // 光靠样式挡不干净：忙时在捕获阶段把点击整个截下来，不让它进页面自己的处理。
      document.addEventListener('click', function (ev) {
        if (!busyNow()) return;
        if (ev.target && ev.target.closest
            && (ev.target.closest(LOG_SEL) || ev.target.closest(QD_SEL)
                || ev.target.closest(VR_ROW))) return;
        var a = (ev.target && ev.target.closest) ? ev.target.closest('a') : null;
        // 下载不是命令：页面在 iOS 上把它改成 window.location.href 顶层导航，
        // 交给原生 WKDownload 接，不存在“等 PC 回话”这件事。
        if (a && String(a.getAttribute('onclick') || '').indexOf('downloadFile') >= 0) return;
        ev.preventDefault();
        ev.stopPropagation();
      }, true);

      // —— 全屏时控件平时收起，点一下画面再出来 ——
      // 页面全屏只留播放行、进度条和「发日志」，三样常驻会一直压着画面。
      // 手机上的习惯是点一下才出现，几秒不动再自己收起。只往 <html> 上加一个类，
      // 退出全屏立刻还原，不碰页面自己的 .fs 语义。
      var FS_IDLE = 'live-fs-idle';
      var FS_HIDE_MS = 4000;
      var fsHideTimer = null;
      function fsOn() {
        try { return document.documentElement.classList.contains('fs'); } catch (e) { return false; }
      }
      function fsIdle(on) {
        try {
          if (on && fsOn()) document.documentElement.classList.add(FS_IDLE);
          else document.documentElement.classList.remove(FS_IDLE);
        } catch (e) {}
      }
      function fsShow() {
        if (!fsOn()) return;
        fsIdle(false);
        clearTimeout(fsHideTimer);
        fsHideTimer = setTimeout(function () { fsIdle(true); }, FS_HIDE_MS);
      }
      (function addFsStyle() {
        try {
          var st = document.createElement('style');
          st.id = 'live-fs-style';
          // 页面在全屏里点亮了播放行和进度条，这里只在收起态把它们整行盖掉；
          // 要用 !important：页面那条 visibility:visible 是直接声明，只靠继承压不住。
          st.textContent =
            'html.fs.live-fs-idle .controls.play-row,'
            + 'html.fs.live-fs-idle .controls.play-row *,'
            + 'html.fs.live-fs-idle #live-seek-row.on,'
            + 'html.fs.live-fs-idle #live-seek-row.on *,'
            + 'html.fs.live-fs-idle #live-log-btn'
            + '{visibility:hidden !important;}';
          (document.head || document.documentElement).appendChild(st);
        } catch (e) {}
      })();
      document.addEventListener('click', function (ev) {
        if (!fsOn()) return;
        var t = ev.target;
        // 点在控件上不是“唤画面”：保持展开，只把自动收起往后推。
        if (t && t.closest) {
          if (t.closest('.controls.play-row') || t.closest('#live-seek-row')
              || t.closest(LOG_SEL) || t.closest(VR_ROW)) { fsShow(); return; }
        }
        if (document.documentElement.classList.contains(FS_IDLE)) fsShow();
        else fsIdle(true);
      }, true);
      // 拖进度条不会有 click：手指按着走的时候一直重置收起计时，别把条从手指底下抽走。
      document.addEventListener('input', function (ev) {
        if (!fsOn()) return;
        var t = ev.target;
        if (t && t.closest && (t.closest('.controls.play-row')
            || t.closest('#live-seek-row') || t.closest(LOG_SEL)
            || t.closest(VR_ROW))) fsShow();
      }, true);

      // —— 全屏 VR：鱼眼左右屏（只弯像素，不算深度）——
      // 用户要的「点全屏就把手机塞进眼镜里看」：不换协议、不再多开一条下行长连接，
      // 只把页面那一个 <img> 的当前帧当纹理，一帧画两遍到两半里，每半按 vr3d 那条
      // kSbsFish 的原式预畸变一遍（屏幕这一格 v 读源图 u = v·(1 + k·v²)，半径按自家
      // 半幅对角的一半归一，出界涂黑 ⇒ 整幅往中心挤、源图一个像素都不裁）。
      // 深度那趟没进来：vr3d 实测 CPU 184ms/帧（VRApp.swift:203），推流时再占一颗核
      // 只换来每秒几次跳变的立体感，而这一版用户明确要「最简单的鱼眼左右屏」。
      var VR_ROW = '#live-vr-row';
      var VR_LS = 'live.vr.';
      var VR_DRAW_MS = 66;              // 重画上限 15fps：新内容本来就只有 PC 那 ~5fps
      var VR_ROT_NAME = ['正', '右转', '倒', '左转'];

      function vrGet(key, dflt) {
        try {
          var v = localStorage.getItem(VR_LS + key);
          return v === null ? dflt : Number(v);
        } catch (e) { return dflt; }
      }
      function vrSet(key, val) {
        try { localStorage.setItem(VR_LS + key, String(val)); } catch (e) {}
      }

      var vr = {
        canvas: null, gl: null, prog: null, tex: null, u: {},
        running: false, raf: 0, lastDraw: 0, dead: false,
        startedAt: 0, draws: 0,
        fish: vrGet('fish', 0.35),      // 界面强度 0~1，送进着色器翻倍成 k（和 vr3d 一样）
        gap: vrGet('gap', 0),           // 两半互相推远/拉近，±25% 每眼物理宽
        shift: vrGet('shift', 0),       // 两半一起挪，±12%，对镜片中心用
        zoom: vrGet('zoom', 1.25),      // 整幅放大：鱼眼把画面挤小，这一颗补回来（1~2）
        extra: vrGet('extra', 0),       // 再加几个 90°：眼镜塞手机的方向是硬件定的
      };

      var VR_VS = 'attribute vec2 aPos;'
        + 'void main(){ gl_Position = vec4(aPos, 0.0, 1.0); }';

      var VR_FS = [
        // 坐标要拿到 2^14 以上才不吃得下整块屏幕（dpr 2 时竖屏就是 2000 多），
        // 所以能上 highp 就上；老机器不给就用 mediump，误差 0.1 像素级，看不出来。
        '#ifdef GL_FRAGMENT_PRECISION_HIGH',
        'precision highp float;',
        '#else',
        'precision mediump float;',
        '#endif',
        'uniform vec4 uRect;',      // 这只眼在画布设备像素里的矩形：x, y(从顶量), w, h
        'uniform vec2 uVP;',        // 画布设备像素尺寸
        'uniform vec4 uImg;',       // 源图在那半幅里的 contain 位置：ox, oy, iw, ih
        'uniform vec2 uOff;',       // 画面在这半幅里整体挪多少（已按视口折算到配对轴）
        'uniform float uK;',        // 鱼眼强度 k
        'uniform float uZoom;',     // 整幅再放大几倍：鱼眼本身会把画面往中心挤，这颗补回来
        'uniform int uRot;',        // 内容再转几个 90°（0..3）
        'uniform sampler2D uTex;',
        'void main(){',
        // gl_FragCoord 原点在左下，先换成「从这只眼矩形左上量」的局部坐标
        '  float lx = gl_FragCoord.x - uRect.x;',
        '  float ly = (uVP.y - gl_FragCoord.y) - uRect.y;',
        '  float w = uRect.z, h = uRect.w;',
        '  if (lx < 0.0 || lx >= w || ly < 0.0 || ly >= h) { discard; }',
        '  float dx = lx - w * 0.5 + 0.5 - uOff.x;',
        '  float dy = ly - h * 0.5 + 0.5 - uOff.y;',
        '  float R = 0.5 * sqrt(w * w + h * h);',
        '  float sc = 1.0 + uK * (dx * dx + dy * dy) / (R * R);',
        // 弯曲张量按屏幕位置算（镜片就在那个角度压），放大只改读源图的步幅
        '  float sx = dx * sc / uZoom + w * 0.5;',
        '  float sy = dy * sc / uZoom + h * 0.5;',
        '  if (sx < 0.0 || sx >= w || sy < 0.0 || sy >= h) { gl_FragColor = vec4(0.0,0.0,0.0,1.0); return; }',
        '  float tx = (sx - uImg.x) / uImg.z;',
        '  float ty = (sy - uImg.y) / uImg.w;',
        '  if (tx < 0.0 || tx > 1.0 || ty < 0.0 || ty > 1.0) { gl_FragColor = vec4(0.0,0.0,0.0,1.0); return; }',
        '  vec2 uv = vec2(tx, 1.0 - ty);',      // 纹理按 FLIP_Y 上传，翻回纹理的 v
        '  if (uRot == 1) { uv = vec2(1.0 - uv.y, uv.x); }',
        '  else if (uRot == 2) { uv = vec2(1.0 - uv.x, 1.0 - uv.y); }',
        '  else if (uRot == 3) { uv = vec2(uv.y, 1.0 - uv.x); }',
        '  gl_FragColor = texture2D(uTex, uv);',
        '}'
      ].join('\n');

      function vrShader(gl, type, src) {
        var s = gl.createShader(type);
        gl.shaderSource(s, src);
        gl.compileShader(s);
        if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
          throw new Error(gl.getShaderInfoLog(s) || 'vr shader');
        }
        return s;
      }

      function vrBuild() {
        var c = document.createElement('canvas');
        c.id = 'live-vr-canvas';
        // 夹在页面 #video-stream(9000) 和 .controls.play-row(9001) 之间：盖住原图、
        // 又让底部那两行浮在画面上。pointer-events:none —— 画面上的点击要留给页面，
        // 否则「点一下唤出控件」这套全屏规矩就被这层吞了。
        c.setAttribute('style', 'position:fixed;top:0;left:0;right:0;bottom:0;'
          + 'width:100%;height:100%;z-index:9000;margin:0;border:none;'
          + 'background:#000;pointer-events:none;');
        var gl = null;
        try {
          // preserveDrawingBuffer：这一层不需要每 60 次重画才亮一次，攒着上一次的画面
          // 就能一直显出来。省下的是整屏两遍的 GPU 活儿——手机还在同时编码上行。
          gl = c.getContext('webgl', { alpha: false, antialias: false,
                                       preserveDrawingBuffer: true });
        } catch (e) { gl = null; }
        if (!gl) return false;
        var p;
        try {
          p = gl.createProgram();
          gl.attachShader(p, vrShader(gl, gl.VERTEX_SHADER, VR_VS));
          gl.attachShader(p, vrShader(gl, gl.FRAGMENT_SHADER, VR_FS));
          gl.linkProgram(p);
          if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
            throw new Error(gl.getProgramInfoLog(p) || 'vr link');
          }
        } catch (e) {
          send({ action: JSLOG, level: 'warn', msg: 'VR 着色器没编出来：' + String(e && e.message || e) });
          return false;
        }
        gl.useProgram(p);
        var buf = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, buf);
        // 一个盖满视口的三角形就够：省掉索引缓冲，越界那圈靠 discard 收
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
        var loc = gl.getAttribLocation(p, 'aPos');
        gl.enableVertexAttribArray(loc);
        gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
        var names = ['uRect', 'uVP', 'uImg', 'uOff', 'uK', 'uZoom', 'uRot', 'uTex'];
        for (var i = 0; i < names.length; i++) vr.u[names[i]] = gl.getUniformLocation(p, names[i]);
        var tex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.clearColor(0, 0, 0, 1);
        vr.canvas = c; vr.gl = gl; vr.prog = p; vr.tex = tex;
        document.body.appendChild(c);
        return true;
      }

      // 竖屏视口 ⇒ 两半上下摞（手机横过来塞进眼镜就是左右两眼），内容必须再转 90°；
      // 横屏视口 ⇒ 直接左右两半。配对轴跟着视口换，百分比的基准都按「物理每眼宽」算。
      function vrLayout() {
        var vw = window.innerWidth, vh = window.innerHeight;
        var portrait = vh > vw;
        // 竖屏时上半就是物理左眼：内容基准转 90°（顶边朝左手那边），朝向那挡再往上叠
        var base = portrait ? 1 : 0;
        return {
          portrait: portrait, vw: vw, vh: vh,
          eyeW: portrait ? vw : vw / 2,
          eyeH: portrait ? vh / 2 : vh,
          axis: portrait ? 'y' : 'x',
          rot: (base + vr.extra) % 4
        };
      }

      function vrDraw(force) {
        var gl = vr.gl;
        if (!gl) return;
        var now = Date.now();
        // 画面在眼镜里是跟着头一起动的，刷新率不产生流畅度，要紧的只有「新内容」；
        // PC 流水线本来就 ~5fps 新帧，所以没到 15fps 那一档直接跳过这一帧不重画
        // （preserveDrawingBuffer 留着上一次的画面）。省下的是每秒两遍全屏的 GPU，
        // 手机这会儿还在同时抽帧、编码、发上行——那才是真瓶颈所在的另一颗核。
        if (!force && now - vr.lastDraw < VR_DRAW_MS) return;
        vr.lastDraw = now;
        vr.draws++;
        var img = find('#video-stream') || document.getElementById('video-stream');
        if (!img) return;
        var dpr = Math.min(2, window.devicePixelRatio || 1);
        var lay = vrLayout();
        var cw = Math.round(lay.vw * dpr), ch = Math.round(lay.vh * dpr);
        if (vr.canvas.width !== cw || vr.canvas.height !== ch) {
          vr.canvas.width = cw; vr.canvas.height = ch;
        }
        var sw = img.naturalWidth || 16, sh = img.naturalHeight || 9;
        if (img.complete && img.naturalWidth > 0) {
          try { gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img); }
          catch (e) { return; }
        }
        var ewD = lay.eyeW * dpr, ehD = lay.eyeH * dpr;
        // 源图在那半幅里等比 contain（跟页面 #video-stream 的 object-fit:contain 同规矩）；
        // 内容转了 90° 的奇数倍时宽高比互换
        var odd = (lay.rot % 2) === 1;
        var ar = (odd ? sh / sw : sw / sh);
        var iw = ewD, ih = ewD / ar;
        if (ih > ehD) { ih = ehD; iw = ehD * ar; }
        var ox = (ewD - iw) / 2, oy = (ehD - ih) / 2;
        var span = lay.axis === 'y' ? ehD : ewD;
        var shiftPx = vr.shift * span, gapPx = vr.gap * span;

        gl.viewport(0, 0, cw, ch);
        gl.useProgram(vr.prog);
        gl.uniform2f(vr.u.uVP, cw, ch);
        gl.uniform1f(vr.u.uK, vr.fish * 2);
        gl.uniform1f(vr.u.uZoom, vr.zoom);
        gl.uniform1i(vr.u.uTex, 0);
        gl.uniform1i(vr.u.uRot, lay.rot);
        // slot=-1 那一半是物理左眼（横屏=左半、竖屏=上半）：间距正号把它往物理左推=推远。
        // 竖屏里 rect 向下就是物理向右，所以两根轴上符号约定是同一套
        var eyes = lay.portrait
          ? [{ x: 0, y: 0, slot: -1 }, { x: 0, y: lay.eyeH, slot: 1 }]
          : [{ x: 0, y: 0, slot: -1 }, { x: lay.eyeW, y: 0, slot: 1 }];
        gl.clear(gl.COLOR_BUFFER_BIT);
        for (var i = 0; i < 2; i++) {
          var e = eyes[i];
          var offPair = shiftPx + e.slot * gapPx;
          gl.uniform4f(vr.u.uRect, e.x * dpr, e.y * dpr, ewD, ehD);
          gl.uniform4f(vr.u.uImg, ox, oy, iw, ih);
          gl.uniform2f(vr.u.uOff, lay.axis === 'y' ? 0 : offPair,
                                   lay.axis === 'y' ? offPair : 0);
          gl.drawArrays(gl.TRIANGLES, 0, 3);
        }
      }

      function vrTick() {
        if (!vr.running) return;
        vrDraw(false);
        vr.raf = requestAnimationFrame(vrTick);
      }

      function vrStart() {
        if (vr.running || vr.dead) return;
        if (!vr.gl && !vrBuild()) {
          vr.dead = true;   // 这台 WebView 没给 WebGL：整层放弃，画面就退回页面原来那张 img
          send({ action: JSLOG, level: 'warn', msg: 'VR 层起不来（拿不到 WebGL）：全屏退回普通画面' });
          return;
        }
        // 上下文是挂在 canvas 这个元素上的，摘掉元素再新建就得重编一遍着色器；
        // 所以第二次进全屏只把同一个元素塞回文档。
        if (vr.canvas && !vr.canvas.parentNode) document.body.appendChild(vr.canvas);
        vr.running = true;
        vr.startedAt = Date.now();
        vr.draws = 0;
        vrDraw(true);
        vr.raf = requestAnimationFrame(vrTick);
        // 进/出各记一行：perf 行是每 10 秒一条，没有这两个边界就分不出「开 VR 以前」
        // 和「开 VR 以后」那两段往返谁高——这一次用户说卡，我就只能靠猜。
        var lay = vrLayout();
        send({ action: JSLOG, level: 'info', msg: 'VR 层开：'
          + (lay.portrait ? '竖屏上下两半' : '横屏左右两半')
          + '｜鱼眼' + vr.fish.toFixed(2) + '｜放大' + Math.round(vr.zoom * 100) + '%'
          + '｜间距' + Math.round(vr.gap * 100) + '%｜移' + Math.round(vr.shift * 100) + '%'
          + '｜朝向' + VR_ROT_NAME[vr.extra]
          + '｜画布 ' + vr.canvas.width + '×' + vr.canvas.height });
      }

      function vrStop() {
        if (!vr.running) return;
        vr.running = false;
        if (vr.raf) { cancelAnimationFrame(vr.raf); vr.raf = 0; }
        send({ action: JSLOG, level: 'info', msg: 'VR 层关：这次开了 '
          + Math.round((Date.now() - vr.startedAt) / 100) / 10 + ' 秒、重画 ' + vr.draws + ' 帧' });
        // 退出全屏就把这层从文档里摘掉（元素留着，下次进全屏接着用）：
        // 挂着它，页面自己那张 img 会被压在下面看不见。
        if (vr.canvas && vr.canvas.parentNode) vr.canvas.parentNode.removeChild(vr.canvas);
      }

      // —— VR 参数那一行 ——
      // 只在全屏里出现，跟播放行同一套「点画面才出来、4 秒自己收起」；戴进眼镜前对好参数，
      // 戴上以后它自己收走。忙闸会把这些 input 一起打灰，所以整行豁免（和页面 #thr-bar 同一条口子）。
      function vrAddRow() {
        if (find(VR_ROW) || !document.body) return;
        var row = document.createElement('div');
        row.id = 'live-vr-row';
        row.className = 'controls';
        row.setAttribute('style', 'position:fixed;top:0;left:0;right:0;z-index:9002;'
          + 'margin:0;padding:6px calc(12px + env(safe-area-inset-right)) 6px calc(12px + env(safe-area-inset-left));'
          + 'gap:8px;align-items:center;flex-wrap:wrap;background:rgba(0,0,0,.55);'
          + 'color:#eee;font-size:12px;visibility:hidden;');
        row.innerHTML =
            '<span>VR</span>'
          + '<label>鱼眼<input type="range" id="vr-fish" min="0" max="1" step="0.01" value="' + vr.fish + '" style="width:96px"></label><span id="vr-fish-v"></span>'
          + '<label>放大<input type="range" id="vr-zoom" min="1" max="2" step="0.05" value="' + vr.zoom + '" style="width:88px"></label><span id="vr-zoom-v"></span>'
          + '<label>间距<input type="range" id="vr-gap" min="-0.25" max="0.25" step="0.01" value="' + vr.gap + '" style="width:88px"></label><span id="vr-gap-v"></span>'
          + '<label>一起移<input type="range" id="vr-shift" min="-0.12" max="0.12" step="0.01" value="' + vr.shift + '" style="width:88px"></label><span id="vr-shift-v"></span>'
          + '<button type="button" id="vr-rot">朝向·' + VR_ROT_NAME[vr.extra] + '</button>';
        document.body.appendChild(row);
        function bind(id, key, fmt) {
          var el = document.getElementById(id);
          var lab = document.getElementById(id + '-v');
          var paint = function () { if (lab) lab.textContent = fmt(el.value); };
          paint();
          el.addEventListener('input', paint);
          el.addEventListener('change', function () {
            vr[key] = Number(el.value);
            vrSet(key, vr[key]);
            paint();
            if (vr.running) vrDraw(true);
          });
        }
        bind('vr-fish', 'fish', function (v) { return Number(v).toFixed(2); });
        bind('vr-zoom', 'zoom', function (v) { return (Number(v) * 100).toFixed(0) + '%'; });
        bind('vr-gap', 'gap', function (v) { return (Number(v) * 100).toFixed(0) + '%'; });
        bind('vr-shift', 'shift', function (v) { return (Number(v) * 100).toFixed(0) + '%'; });
        var rot = document.getElementById('vr-rot');
        if (rot) rot.addEventListener('click', function (ev) {
          ev.preventDefault();
          ev.stopPropagation();
          vr.extra = (vr.extra + 1) % 4;
          vrSet('extra', vr.extra);
          rot.textContent = '朝向·' + VR_ROT_NAME[vr.extra];
          if (vr.running) vrDraw(true);
        }, true);
      }

      // 参数那一行跟着收起态走：进全屏先收着，点画面才和播放行一起出来。
      // 平时（非全屏）整行 display:none —— 它是 fixed 在顶上的，不挡住普通页面才怪。
      function vrSetOn(on) {
        if (on) { vrStart(); vrAddRow(); } else { vrStop(); }
      }

      // 页面全屏把 body 下所有东西都 visibility:hidden，只点名放行 img 和底部两行；
      // 注入层不在它的名单里，必须自己顶回来（用 !important，压的直接是它那条声明）。
      // 忙闸那条 html.pc-busy input 会把参数行打灰，这里连着豁免——它不跟 PC 说话。
      (function addVrStyle() {
        try {
          var st = document.createElement('style');
          st.id = 'live-vr-style';
          st.textContent =
            '#live-vr-row{display:none;}'
            + 'html.fs #live-vr-canvas{visibility:visible !important;}'
            + 'html.fs #live-vr-row{visibility:visible !important;display:flex !important;}'
            + 'html.fs #live-vr-row *{visibility:visible !important;}'
            + 'html.fs.live-fs-idle #live-vr-row,'
            + 'html.fs.live-fs-idle #live-vr-row *{visibility:hidden !important;}'
            + 'html.pc-busy #live-vr-row,html.pc-busy #live-vr-row *'
            + '{pointer-events:auto !important;opacity:1 !important;}';
          (document.head || document.documentElement).appendChild(st);
        } catch (e) {}
      })();

      // —— 页面侧日志 ——
      // 1) 命令回话：非轮询 fetch 的路径/状态码/耗时/响应体前一段。
      //    「特征改几次以后改不了」时，PC 的 409 响应体里写的才是原因。
      // 2) 播放状态：/get_playback_state 只在变化时上报，前台按钮和后台对不上时留时间线。
      function pathOnly(url) {
        try { return new URL(String(url || ''), location.href).pathname.slice(0, 120); }
        catch (e) { return String(url || '').slice(0, 120); }
      }
      function isStateCall(url) {
        try { return new URL(String(url || ''), location.href).pathname === '/get_playback_state'; }
        catch (e) { return false; }
      }
      var lastPageState = '';
      function observeState(r) {
        try {
          r.clone().json().then(function (j) {
            var sig = [(j.live_mode ? 1 : 0), (j.playing ? 1 : 0), (j.edit_locked ? 1 : 0),
                       (j.plan_count || 0), (j.live_fps || 0)].join(',');
            if (sig === lastPageState) return;
            lastPageState = sig;
            send({ action: PAGESTATE, live: !!j.live_mode, playing: !!j.playing,
                   locked: !!j.edit_locked, plan: j.plan_count || 0, fps: j.live_fps || 0 });
          }, function () {});
        } catch (e) {}
      }
      function observeCommand(url, r, started) {
        var body = function (text) {
          send({ action: CMDLOG, url: pathOnly(url), status: r.status,
                 ms: Date.now() - started, body: String(text || '').slice(0, 300) });
        };
        try {
          r.clone().text().then(body, function () { body(''); });
        } catch (e) {}
      }

      if (window.fetch) {
        var rawFetch = window.fetch.bind(window);
        var isPoll = function (url) {
          var p = String(url || '');
          for (var i = 0; i < BUSY_POLL.length; i++) {
            if (p.indexOf(BUSY_POLL[i]) >= 0) return true;
          }
          return false;
        };
        window.fetch = function (input, init) {
          var url = '';
          try { url = typeof input === 'string' ? input : (input && input.url) || ''; } catch (e) {}
          var state = isStateCall(url);
          if (isPoll(url)) {
            var rp = rawFetch(input, init);
            if (state) rp.then(function (r) { noteStateOk(); observeState(r); return r; },
                               function () {});
            return rp;
          }
          busyFetches += 1;
          busySync();
          var settled = false;
          var done = function () {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            busyFetches = Math.max(0, busyFetches - 1);
            busySync();
          };
          var timer = setTimeout(done, BUSY_MAX_MS);
          var started = Date.now();
          var p;
          try { p = rawFetch(input, init); }
          catch (e) {
            done();
            send({ action: CMDLOG, url: pathOnly(url), status: 0,
                   ms: Date.now() - started, body: 'ERR ' + String(e && (e.message || e)) });
            return Promise.reject(e);
          }
          return p.then(function (r) {
            done();
            observeCommand(url, r, started);
            return r;
          }, function (e) {
            done();
            send({ action: CMDLOG, url: pathOnly(url), status: 0,
                   ms: Date.now() - started,
                   body: 'ERR ' + String((e && (e.name || e.message)) || e).slice(0, 200) });
            throw e;
          });
        };
      }

      UI.setBusy = function (on) {
        busyNative = Math.max(0, busyNative + (on ? 1 : -1));
        busySync();
        return busyNative;
      };

      // —— 停止握手 ——
      // 页面每秒才轮询一次 /get_playback_state，最长晚一秒才认「停了」。原生在点停止的
      // 那一刻调 setStopPending('stopping')：按钮灰着写「停止中…」、特征下拉框全灰；
      // /live_stop 回成功再调 '' 交回页面按 edit_locked 判；没送到就调 'failed'，
      // 按钮变「重试停止」、下拉框继续锁着。
      var STOP_HOLD = null;

      function stopButton(text, enabled) {
        var b = document.getElementById('start-button');
        if (!b) return;
        if (text) b.textContent = text;
        b.disabled = !enabled;
      }

      function stopSelects(lock) {
        try {
          if (typeof faceSetPlaying === 'function') { faceSetPlaying(!!lock); return; }
        } catch (e) {}
        try {
          var l = document.querySelectorAll('#face-pick-list select');
          for (var i = 0; i < l.length; i++) l[i].disabled = !!lock;
        } catch (e) {}
      }

      function stopFaceNote(stage) {
        try {
          var el = document.getElementById('face-pick-state');
          if (!el) return;
          if (stage === 'hold') {
            el.textContent = '正在停推流：等 PC 确认停下再改特征';
            el.style.color = '#c60';
          } else if (stage === 'failed') {
            el.textContent = '停止没送到 PC：推流可能还在跑，先点「重试停止」';
            el.style.color = '#c00';
          } else {
            var t = String(el.textContent || '');
            if (t.indexOf('正在停推流') === 0 || t.indexOf('停止没送到') === 0) {
              el.textContent = '';
              el.style.color = '#666';
            }
          }
        } catch (e) {}
      }

      UI.setStopPending = function (state) {
        var s = String(state || '');
        if (s === STOP_STOPPING || s === STOP_FAILED) {
          STOP_HOLD = s;
          // 只有「还在等 PC 回话」才把整页灰上；失败态已经不在等，
          // 灰住的话用户点不到「重试停止」，就真卡死了。
          busyHold = (s === STOP_STOPPING);
          busySync();
          stopButton(s === STOP_FAILED ? '重试停止' : '停止中…', s === STOP_FAILED);
          stopSelects(true);
          stopFaceNote(s === STOP_FAILED ? 'failed' : 'hold');
          return s;
        }
        // 确认停了：按钮马上回到「播放」，下拉框解不解交给页面按 PC 的 edit_locked 判。
        STOP_HOLD = null;
        busyHold = false;
        busySync();
        stopButton('播放', true);
        stopFaceNote('release');
        try {
          if (typeof checkPlaybackState === 'function') { checkPlaybackState(); return 'sync'; }
        } catch (e) {}
        stopSelects(false);
        return 'released';
      };

      // 握手期间轮询来的 setPlaying 一律不落地：它读到的是 PC 上一秒的状态，
      // 会把「停止中…」改回「停止」、把刚锁上的下拉框又解开，用户会以为没点上。
      if (typeof UI.setPlaying === 'function') {
        var pageSetPlaying = UI.setPlaying;
        UI.setPlaying = function (on, manual, lock) {
          if (STOP_HOLD) {
            stopButton(STOP_HOLD === STOP_FAILED ? '重试停止' : '停止中…',
                       STOP_HOLD === STOP_FAILED);
            stopSelects(true);
            stopFaceNote(STOP_HOLD === STOP_FAILED ? 'failed' : 'hold');
            return;
          }
          return pageSetPlaying.call(UI, on, manual, lock);
        };
      }

      function refreshFeed() {
        try {
          if (window.LiveUI && LiveUI.refreshStream) { LiveUI.refreshStream(); return true; }
        } catch (e) {}
        return false;
      }

      // 页面自带的 30 秒盲重连会让画面整块闪一下，也救不了真断掉时该立刻重连的场景。
      // PC 给了开关就关掉它，改由下面的 error 钩子按需重连；没有这个接口（老页面）
      // 就保留原样，宁可按老节奏闪，也别让画面永远不回来。
      try { if (UI.autoRefresh) UI.autoRefresh(false); } catch (e) {}

      // —— /video_feed 重连闸 ——
      // 页面在停止态每改完一次特征（re_rendered）都会调 LiveUI.refreshStream() 想
      // 「马上看到重画的那帧」。但 iOS WebKit 换掉 img.src 时，旧的多部分流连接
      // 不会马上释放：改一次就多占一条（每主机上限 6 条）。0.23 实测 17:05:42–17:06:59
      // 连续改 5 次正好攒满 6 条，之后页面所有 fetch 都排队不返回——轮询停、下拉框灰死、
      // 按钮文案冻住，而原生 URLSession 照常推流。旧连接的生成器还在 15fps 编码发送，
      // 白占 CPU 和 Wi-Fi，画面也就跟着卡。
      // 帧已经在来就说明这条长连接活着，PC 补投的新帧本来就会沿它推下来，不用重连。
      // 只在三种情况下真的换一条：img 报 error、退后台回来（系统可能挂断了长连接）、
      // 或者连第一帧都还没到。页面自己那次 re_rendered 重连从此不再新开连接。
      var feedImg = document.getElementById('video-stream');
      var feedOk = false;        // 这条流至少到过一帧
      var feedBroken = false;    // 上一条流报了 error，下一次必须重连
      var feedAllow = false;     // 回前台放行一次
      if (feedImg) {
        feedImg.addEventListener('load', function () { feedOk = true; feedBroken = false; });
        feedImg.addEventListener('error', function () { feedOk = false; feedBroken = true; });
        if (feedImg.complete && feedImg.naturalWidth > 0) { feedOk = true; }
      }
      document.addEventListener('visibilitychange', function () {
        if (document.visibilityState !== 'visible') return;
        stateAt = Date.now();   // 回前台先给轮询一个宽限，别一回来就判卡死
        feedAllow = true;
        // 系统可能在后台把长连接挂断又不报 error：回前台补一次重连，
        // 由上面的闸放行这一次。页面自己没有「恢复时主动刷新」的钩子。
        setTimeout(function () {
          if (document.visibilityState === 'visible' && feedAllow) refreshFeed();
        }, 800);
      });
      if (typeof UI.refreshStream === 'function') {
        var pageRefreshStream = UI.refreshStream;
        UI.refreshStream = function () {
          // 多部分流的 load 事件在 WebKit 上不一定每帧都发；有一帧进来了
          // naturalWidth 就会大于 0，用它兜住「事件没来但画面确实在动」。
          if (!feedOk && feedImg && feedImg.naturalWidth > 0) feedOk = true;
          if (feedOk && !feedBroken && !feedAllow) {
            send({ action: JSLOG, level: 'info',
                   msg: '画面还在来帧，跳过重连（不再多占一条 /video_feed）' });
            return;
          }
          feedAllow = false;
          feedOk = false;
          feedBroken = false;
          return pageRefreshStream.apply(UI, arguments);
        };
      }

      // —— 页面网络卡死自愈 ——
      // 0.23 实测：六条 /video_feed 占满每主机连接池后，页面所有 fetch 排队不返回，
      // 轮询停、下拉框永久灰住，而 JS 还活着（桥接消息照发），只有重开 App 能救。
      // 这里盯「最近一次 /get_playback_state 有回话」：曾经通过、又超过 10 秒没有一次
      // 成功，就整页重载（重载会关掉旧连接）；30 秒内不重复，退后台和刚回前台都不算。
      var stateAt = Date.now();
      var stateEver = false;
      var lastSelfReload = 0;
      function noteStateOk() { stateAt = Date.now(); stateEver = true; }
      setInterval(function () {
        if (document.visibilityState !== 'visible') return;
        if (!stateEver) return;   // 一次都没通过：那是连不上 PC，重载也救不了
        if (Date.now() - stateAt < 10000) return;
        if (Date.now() - lastSelfReload < 30000) return;
        lastSelfReload = Date.now();
        send({ action: JSLOG, level: 'warn', msg: '状态轮询 10 秒没回话：整页重载自愈' });
        try { location.reload(); } catch (e) {}
      }, 3000);

      // /video_feed 是长连接：WebView 退后台、网络抖一下都会让它报 error 且不自恢复。
      // 0.11 起全屏不再 clone 第二个 img（页面只给 <html> 加 .fs），所以只有这一路要重连。
      // 1.5 秒内只试一次，免得 error 连环把长连接打成轮询。
      function retryFeed(img) {
        if (img.__liveRetry) return;
        img.__liveRetry = setTimeout(function () {
          img.__liveRetry = null;
          refreshFeed();
        }, 1500);
      }

      document.addEventListener('error', function (ev) {
        var img = ev.target;
        if (!img || img.tagName !== 'IMG') return;
        if (img.id !== 'video-stream') return;
        retryFeed(img);
      }, true);

      // 全屏只靠 <html class="fs"> 表达；页面不会额外调原生，这里盯 class 变化再上报。
      // 原生只拿它来藏/恢复状态栏，不参与画面布局。
      // 进全屏先把控件收起来（点画面才出来）；退出去时把收起态和定时器一起还原。
      // VR 层跟着这一个开关走：用户要的就是「点全屏 = 塞进眼镜看」，不另设入口。
      var lastFs = null;
      function noteFullscreen() {
        var on = false;
        try { on = document.documentElement.classList.contains('fs'); } catch (e) {}
        if (on === lastFs) return;
        lastFs = on;
        if (on) fsIdle(true);
        else {
          clearTimeout(fsHideTimer);
          fsIdle(false);
        }
        try { vrSetOn(on); } catch (e) {
          send({ action: JSLOG, level: 'warn', msg: 'VR 层没起来：' + String(e && e.message || e) });
        }
        send({ action: FS, on: on });
      }
      try {
        new MutationObserver(noteFullscreen).observe(document.documentElement, {
          attributes: true, attributeFilter: ['class']
        });
      } catch (e) {}
      noteFullscreen();

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', UI.report);
      } else {
        UI.report();
      }
    })();
    """#
}
