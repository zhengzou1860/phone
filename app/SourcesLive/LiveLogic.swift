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

    /// PC 那边 /live_start 响应里的 max_width 是权威；这个只在读不到响应时兜底。
    static let fallbackMaxWidth = 640

    /// 640 宽 + q0.7 是 PC 实测过的档位：约 30–50KB/帧，局域网 15fps 不到 4Mbps。
    static let jpegQuality: CGFloat = 0.7
    static let pushFPS: Double = 15

    /// 在途帧上限。PC 明确要求保持 2–3 帧在途：一帧等一个往返会被单次 RTT 限死节奏
    /// （它第一版测试就是这么只跑到 10fps）。满了丢最旧，绝不排队。
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
    static let userAgentSuffix = "LiveSwap/0.11"

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

    /// 给用户看的那一句：重新搬一次 cookie 还是 401，页面那边就得重登了。
    static let lostMessage = "登录失效了（PC 回 401 未登录）：在这一页重新登录，再点「播放」接着推"
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

    /// 跳转没有按钮了：PC 撤掉了「设置视频路径」，现在由这一格的回车触发。
    /// 页面自己的回车会直接 POST /set_video，手机上那是本地文件名，
    /// 必须在捕获阶段截下来改成“跳到第几秒”。
    static let pathSelector = "#video-path"

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
                          .replacingOccurrences(of: "__BRIDGE__", with: jsLiteral(LiveConfig.bridgeName))
    }

    private static let template = #"""
    (function () {
      'use strict';
      var HOOKS = __HOOKS__;
      var BRIDGE = __BRIDGE__;
      var PATH_SEL = __PATH__;
      var SEEK = __SEEK__;
      var FS = __FULLSCREEN__;

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
        ev.preventDefault();
        ev.stopPropagation();
        send({ action: SEEK });
      }, true);

      // 手机往页面里写状态一律走页面自己的 showStatus 和 #status-message，
      // 不另外盖一层浮标：界面上看到的字和 PC 上同一格是一个来源。
      //
      // PC 页面自己也有 LiveUI（setPlaying / refreshStream / autoRefresh），
      // 这里只能在它上面补 App 用的四个方法：整个赋一个新对象会把页面那三个冲掉，
      // 暂停态改完绑定以后那次 re_rendered 自动重连就再也调用不到，画面定在原处。
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
      };
      window.LiveUI = UI;

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
      var lastFs = null;
      function noteFullscreen() {
        var on = false;
        try { on = document.documentElement.classList.contains('fs'); } catch (e) {}
        if (on === lastFs) return;
        lastFs = on;
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
