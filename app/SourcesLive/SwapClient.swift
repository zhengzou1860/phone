//
//  SwapClient.swift
//  手机 → PC 实时换脸的控制面 + 数据面。
//
//  顺序：页面里登录（手机上不另做登录框）→ cookie 搬给原生 → startLive()
//  → 逐帧 push(jpeg) →（跳转时 seek()）→ stopLive()。
//
//  热路径只有 push()：请求体是裸 JPEG，PC 回 204 空响应，手机不解析返回值。
//  统计走每秒一次的 /live_status 轮询，不为每帧多跑一次往返。
//

import Foundation
import Combine
import WebKit

/// /live_status 的一次读数。
struct LiveSnapshot {
    var liveMode: Bool
    var framesIn: Int
    var framesDropped: Int
    var inputAgeMs: Int?
    var hasOutput: Bool
    var outputAgeMs: Int?
}

final class SwapClient: ObservableObject {
    @Published var framesSent = 0
    @Published var framesDroppedLocal = 0      // 在途满了被手机自己丢掉的帧
    @Published var framesRejected = 0          // PC 回了非 2xx（400/413/503/405……）的帧数
    @Published var pcFramesIn = 0
    @Published var pcFramesDropped = 0
    @Published var outputAgeMs: Int?           // PC 最近一帧输出的年龄；超阈值说明流水线停了
    @Published var inputAgeMs: Int?
    @Published var pcLiveMode = false          // PC 静默 10 秒会自己退出推流模式，手机靠这个知道要重来
    @Published var saw409 = 0                  // 被 PC 判「不在推流模式」的次数，恢复逻辑的触发信号
    @Published var sessionLost = false          // cookie 失效：PC 把请求弹回登录页，这边只有重登一条路
    @Published var lastError: String?

    let baseURL: URL
    /// /live_start 响应里下发的生效宽度，手机按它缩放（PC 的硬上限是 640）。
    private(set) var liveWidth = LiveConfig.fallbackMaxWidth

    private let session: URLSession
    private let inflight = DispatchSemaphore(value: LiveConfig.inflightLimit)
    private var statusTask: Task<Void, Never>?

    init(baseURL: URL) {
        self.baseURL = baseURL
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 6   // 在途帧 + 状态轮询 + 一次性的控制请求
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        session = URLSession(configuration: cfg)
    }

    convenience init?(hostText: String) {
        guard let url = LiveHost.base(hostText) else { return nil }
        self.init(baseURL: url)
    }

    var pageURL: URL { baseURL }
    /// 换脸结果的 MJPEG 流；页面里 #video-stream 用的就是它，手机这边不自己拆 boundary。
    var feedURL: URL { url("/video_feed") }

    // MARK: - cookie：页面里登录，原生这边借用

    /// WKWebView 用自己的 cookie 存储，不搬一次的话原生 /live_frame 会被 302 弹回登录页。
    /// 方向是 页面 → 原生：登录用的是 PC 自己的登录页，界面因此和 PC 完全一致。
    /// 每加载完一页都搬一次：用户在这一页重新登录以后，这一搬就是「会话续上了」的信号。
    func importCookies(from store: WKHTTPCookieStore, then: @escaping () -> Void) {
        store.getAllCookies { cookies in
            let jar = HTTPCookieStorage.shared
            for c in cookies { jar.setCookie(c) }
            DispatchQueue.main.async {
                self.sessionLost = false
                then()
            }
        }
    }

    // MARK: - 控制面（低频）

    /// 返回 PC 实际生效的帧宽。手机请求 640，PC 可以在硬上限内往下压。
    @discardableResult
    func startLive() async throws -> Int {
        let body = try JSONSerialization.data(withJSONObject: ["max_width": LiveConfig.fallbackMaxWidth])
        let (data, resp) = try await call("/live_start", body: body, contentType: "application/json")
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if let http = resp as? HTTPURLResponse, LiveAuth.lost(http) {
            await MainActor.run { self.sessionLost = true }
            throw SwapError(message: LiveAuth.lostMessage)
        }
        let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard code == 200, let j = j, (j["status"] as? String) == "success" else {
            // @login_required 会把未登录的 POST 重定向到登录页，跟随后拿回来的是 200 的 HTML：
            // code 好看但 JSON 解析不出来，这一条基本就是没登录
            let why = (j?["message"] as? String)
                ?? (j == nil ? "PC 回的不是 JSON（多半是没登录，被弹到登录页）" : "HTTP \(code)")
            throw SwapError(message: why)
        }
        if let w = (j["max_width"] as? NSNumber)?.intValue, w > 0 {
            liveWidth = w
        }
        await MainActor.run {
            self.pcLiveMode = true
            self.sessionLost = false        // 能进得推流模式就说明 cookie 是好用的
        }
        beginStatusPolling()
        return liveWidth
    }

    func stopLive() async {
        statusTask?.cancel()
        statusTask = nil
        _ = try? await call("/live_stop", body: Data(), contentType: nil)
        await MainActor.run { self.pcLiveMode = false }
    }

    /// 跳转以后必须调：PC 会丢掉队列里的旧帧和上一姿势的检测缓存，否则糊到跳转之后。
    func seek() async {
        _ = try? await call("/live_seek", body: Data(), contentType: nil)
    }

    /// 回前台时先问一次再决定要不要重新 startLive——不看状态就猛推会一路吃 409。
    func fetchStatusOnce() async -> LiveSnapshot? {
        guard let (data, resp) = try? await session.data(from: url("/live_status")),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return LiveSnapshot(
            liveMode: (j["live_mode"] as? Bool) ?? false,
            framesIn: (j["frames_in"] as? NSNumber)?.intValue ?? 0,
            framesDropped: (j["frames_dropped"] as? NSNumber)?.intValue ?? 0,
            inputAgeMs: (j["input_age_ms"] as? NSNumber)?.intValue,
            hasOutput: (j["has_output"] as? Bool) ?? false,
            outputAgeMs: (j["output_age_ms"] as? NSNumber)?.intValue
        )
    }

    private func beginStatusPolling() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.refreshStatus()
            }
        }
    }

    @MainActor
    private func refreshStatus() async {
        guard let snap = await fetchStatusOnce() else { return }
        pcFramesIn = snap.framesIn
        pcFramesDropped = snap.framesDropped
        outputAgeMs = snap.outputAgeMs
        inputAgeMs = snap.inputAgeMs
        pcLiveMode = snap.liveMode
    }

    // MARK: - 数据面（每帧一次，回调式，不为每帧起一个 Task）

    /// 满 3 帧在途就丢新帧（丢最新），绝不排队——
    /// PC 入口队列只有 2 格且满则丢最旧，手机这边再排一层只会把延迟堆起来。
    func push(_ jpeg: Data) {
        guard inflight.wait(timeout: .now()) == .success else {
            DispatchQueue.main.async { self.framesDroppedLocal += 1 }
            return
        }
        var req = URLRequest(url: url("/live_frame"))
        req.httpMethod = "POST"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = jpeg
        session.dataTask(with: req) { [weak self] _, resp, err in
            guard let self = self else { return }
            self.inflight.signal()
            if let err = err {
                let ns = err as NSError
                // 手机侧网络抖一下不值得占一整行状态栏，计数留给自测和后台日志
                if ns.code != NSURLErrorCancelled {
                    DispatchQueue.main.async {
                        self.lastError = "live_frame: \(ns.domain) \(ns.code)"
                    }
                }
                return
            }
            guard let http = resp as? HTTPURLResponse else { return }
            switch LiveAuth.judge(http) {
            case .sessionLost:
                // 跟着 302 拿回来的是登录页：光看状态码像「这一帧被收了」，实际一帧没进
                DispatchQueue.main.async {
                    self.sessionLost = true
                    self.lastError = LiveAuth.lostMessage
                }
            case .notLive:
                // 409 = PC 已退出推流模式（10 秒空闲看门狗或那边重启），必须重新 /live_start
                DispatchQueue.main.async {
                    self.saw409 += 1
                    self.lastError = "PC 已退出推流模式（静默超时或重启）"
                }
            case .rejected(let code):
                // 400 解不开、413 超 2MB、503 流水线没起、405 方法不对：这些都不算送到
                DispatchQueue.main.async {
                    self.framesRejected += 1
                    self.lastError = "PC 拒了这一帧：HTTP \(code)"
                }
            case .accepted:
                DispatchQueue.main.async { self.framesSent += 1 }
            }
        }.resume()
    }

    private func url(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private func call(_ path: String, body: Data, contentType: String?) async throws
        -> (Data, URLResponse) {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        if let ct = contentType { req.setValue(ct, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        return try await session.data(for: req)
    }
}

struct SwapError: LocalizedError {
    let message: String
    init(message: String) { self.message = message }
    var errorDescription: String? { message }
}
