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
    static let defaultPort = 5000

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

    /// PC 输出帧 age 超过这个数就认定流水线停了（它那边 21fps 上限，正常 age 约 50ms）。
    static let watchdogMs = 1500

    /// 自动重连的节奏：两次之间至少隔这么久，最多试这几次就交回用户处理。
    /// PC 有 10 秒空闲看门狗，掉出推流模式是常事，不试不行；无脑重试会变成打转。
    static let restartGapSeconds: Double = 3.0
    static let maxRestartTries = 3

    /// 追加到 WKWebView 默认 UA 末尾：PC 那边看 access log 就知道是手机 app 在访问，
    /// 而不是有人在浏览器里手点。
    static let userAgentSuffix = "LiveSwap/0.1"
}

// MARK: - PC 地址

enum LiveHost {
    /// 把那一格里可能出现的写法归一成 base URL：
    /// "192.168.1.20"、"192.168.1.20:5000"、"http://192.168.1.20:5000/" 都收，
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

    /// 给状态行回显用的 "192.168.1.20:5000"
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

// MARK: - 跳转输入

enum LiveTime {
    /// 手机上「设置视频路径」那一格兼作跳转输入：接受 "75"、"75.5"、"1:15"、"01:15:30"。
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
    /// 不是按钮，是页面加载完主动报上来的一行：界面挂子上没对上号就在这里说出口
    static let hookReady = "ready"

    /// 三条挂子的选择器就是 PC 页面 templates/index.html 里已有的元素：
    /// 手机上不新增任何控件，只把这三个已有按钮接到原生。
    static let hooks: [LiveHook] = [
        LiveHook(name: hookPick, selector: "#select-file-btn"),
        LiveHook(name: hookPlay, selector: "#start-button"),
        LiveHook(name: hookSeek, selector: "[onclick^=\"setVideoPath\"]"),
    ]

    static var actionNames: [String] { hooks.map { $0.name } }

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
                          .replacingOccurrences(of: "__BRIDGE__", with: jsLiteral(LiveConfig.bridgeName))
    }

    private static let template = #"""
    (function () {
      'use strict';
      var HOOKS = __HOOKS__;
      var BRIDGE = __BRIDGE__;

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

      // 手机往页面里写状态一律走页面自己的 showStatus 和 #status-message，
      // 不另外盖一层浮标：界面上看到的字和 PC 上同一格是一个来源。
      window.LiveUI = {
        status: function (msg, kind) {
          try {
            if (typeof showStatus === 'function') { showStatus(msg, kind || 'success'); return 'showStatus'; }
          } catch (e) {}
          var d = document.getElementById('status-message');
          if (d) { d.textContent = msg; return 'status-message'; }
          return 'none';
        },
        path: function (v) {
          var e = document.getElementById('video-path');
          if (!e) return false;
          e.value = v;
          return true;
        },
        readPath: function () {
          var e = document.getElementById('video-path');
          return e ? String(e.value || '') : '';
        },
        report: function () {
          var have = {};
          for (var i = 0; i < HOOKS.length; i++) have[HOOKS[i][0]] = !!find(HOOKS[i][1]);
          var t = document.querySelector('h1');
          send({ action: 'ready', hooks: have, title: t ? String(t.textContent || '') : '' });
        }
      };

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', window.LiveUI.report);
      } else {
        window.LiveUI.report();
      }
    })();
    """#
}
