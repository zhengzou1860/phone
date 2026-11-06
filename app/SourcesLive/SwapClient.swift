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
    var outputAgeMs: Int?
    // PC 的纯增量字段：配了目标脸却没换时用它解释原因。老版本没有这几个键。
    var planCount: Int
    var swappedFaces: Int
    var bestSim: Double?
    var matchThr: Double?
}

final class SwapClient: ObservableObject {
    @Published var framesSent = 0
    @Published var framesDroppedLocal = 0      // 在途满了被手机自己丢掉的帧
    @Published var framesRejected = 0          // PC 回了非 2xx（400/413/503/405……）的帧数
    @Published var pcFramesIn = 0
    @Published var pcFramesDropped = 0
    @Published var outputAgeMs: Int?           // PC 最近一帧输出的年龄；超阈值说明流水线停了
    @Published var inputAgeMs: Int?
    @Published var planCount = 0                // 目标脸表里有几格（0 = 一帧都不换）
    @Published var swappedFaces = 0             // 当前帧真正换了几张
    @Published var bestSim: Double?             // 画面里最像绑定表的那张脸的余弦；缺字段就是 nil
    @Published var matchThr: Double?            // PC 下发的判定门槛；手机上不写死
    @Published var pcLiveMode = false          // PC 静默 10 秒会自己退出推流模式，手机靠这个知道要重来
    @Published var saw409 = 0                  // 被 PC 判「不在推流模式」的次数，恢复逻辑的触发信号
    @Published var sessionLost = false          // 搬完 cookie 还吃 401：页面那边得重登了
    @Published var lastError: String?

    /// 本次 /live_start 以来 PC 收下的帧数与字节数：只在停止时报一个「上行均值 KB/帧」，
    /// 给 PC 定出流质量用，不参与控制逻辑。
    private(set) var sessionBytes = 0
    private(set) var sessionFrames = 0
    var averageFrameBytes: Int {
        sessionFrames > 0 ? sessionBytes / sessionFrames : 0
    }

    // 每帧往返账目：URLSession 回调线程写、主线程每 10 秒取，必须加锁。
    private let rttLock = NSLock()
    private var rttSumMs: Double = 0
    private var rttCount = 0
    private var rttMaxMs: Double = 0

    // 每帧被拒时写日志的节流：PC 一旦持续拒帧，15fps 会把同一句刷爆。
    private let logLock = NSLock()
    private var lastLogAt: [String: TimeInterval] = [:]

    private func logThrottled(_ key: String, _ message: String, every: TimeInterval = 2) {
        let now = CFAbsoluteTimeGetCurrent()
        logLock.lock()
        let last = lastLogAt[key] ?? 0
        let write = now - last >= every
        if write { lastLogAt[key] = now }
        logLock.unlock()
        if write { AppLog.shared.log("frame", message) }
    }

    /// 取走一个窗口的往返时延（取完清零）。只算拿到了 HTTP 回应的帧，
    /// 被取消或网络错误的不进来——那不是链路慢，是这一帧没发成。
    func takeNetworkStats() -> (avgMs: Double, maxMs: Double) {
        rttLock.lock()
        let avg = rttCount > 0 ? rttSumMs / Double(rttCount) : 0
        let max = rttMaxMs
        rttSumMs = 0
        rttCount = 0
        rttMaxMs = 0
        rttLock.unlock()
        return (avg, max)
    }

    private func noteRTT(_ ms: Double) {
        rttLock.lock()
        rttSumMs += ms
        rttCount += 1
        if ms > rttMaxMs { rttMaxMs = ms }
        rttLock.unlock()
    }

    let baseURL: URL
    /// /live_start 响应里下发的生效宽度，手机按它缩放（PC 硬上限 800，0.19 主动要 640）。
    private(set) var liveWidth = LiveConfig.fallbackMaxWidth

    private let session: URLSession
    private let inflight = DispatchSemaphore(value: LiveConfig.inflightLimit)
    private var statusTask: Task<Void, Never>?

    // WK 页面那边的会话快照。pageCookies 走锁是因为帧的完成回调在 URLSession 的队列上；
    // 其余三个只在 cookieQueue 上动。
    private let cookieLock = NSLock()
    private let cookieQueue = DispatchQueue(label: "liveswap.cookies")
    private var pageCookies: [HTTPCookie] = []
    private var cookieStore: WKHTTPCookieStore?
    private var cookieRefreshing = false
    private var cookieWaiters: [() -> Void] = []

    init(baseURL: URL) {
        self.baseURL = baseURL
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 6   // 在途帧 + 状态轮询 + 一次性的控制请求
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // cookie 由 CookieBridge 从 WK 的 store 取来、直接挂在 Cookie 头上；
        // 关掉 URLSession 自己的 cookie 处理，免得共享 jar 里的旧值把它盖掉。
        cfg.httpShouldSetCookies = false
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

    /// 页面和原生必须盯同一个 host（connect 时传的就是这个 webView 的 store），
    /// 否则 cookie 按主机匹配根本对不上。
    func attachCookieStore(_ store: WKHTTPCookieStore) {
        cookieQueue.sync { cookieStore = store }
    }

    /// 每加载完一页、点播放前、以及任何 /live_* 回 401 以后都重新取一份。
    /// 并发的多次请求只真正读一次 store，等在后面的回调一起放行。
    func importCookies(then: (() -> Void)? = nil) {
        cookieQueue.async {
            if let then = then { self.cookieWaiters.append(then) }
            guard !self.cookieRefreshing else { return }
            guard let store = self.cookieStore else {
                self.finishCookieRefresh()
                return
            }
            self.cookieRefreshing = true
            store.getAllCookies { [weak self] cookies in
                guard let self = self else { return }
                let host = CookieBridge.hostOf(self.baseURL)
                let prepared = cookies.compactMap { CookieBridge.normalized($0, host: host) }
                self.cookieLock.lock()
                self.pageCookies = prepared
                self.cookieLock.unlock()
                // 一条都没取到就别说会话续上了：这时候 /live_* 去也是 401，宁可让人重登。
                if !prepared.isEmpty {
                    DispatchQueue.main.async { self.sessionLost = false }
                }
                self.cookieQueue.async { self.finishCookieRefresh() }
            }
        }
    }

    private func finishCookieRefresh() {
        cookieRefreshing = false
        let waiters = cookieWaiters
        cookieWaiters = []
        for waiter in waiters { waiter() }
    }

    private func refreshCookies() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            importCookies { cont.resume() }
        }
    }

    private func authHeader(for url: URL) -> String? {
        cookieLock.lock()
        let cookies = pageCookies
        cookieLock.unlock()
        return CookieBridge.header(cookies, for: url)
    }

    /// 页面上到底有没有可用会话：401 时用它决定是「搬一次就该好了」还是「这一页根本没登录」。
    private var hasPageCookies: Bool {
        cookieLock.lock()
        defer { cookieLock.unlock() }
        return !pageCookies.isEmpty
    }

    private func authorize(_ req: inout URLRequest) {
        if let header = authHeader(for: req.url ?? baseURL) {
            req.setValue(header, forHTTPHeaderField: "Cookie")
        }
    }

    // MARK: - 控制面（低频）

    /// 返回 PC 实际生效的帧宽。手机请求 640，PC 可以在硬上限内往下压。
    @discardableResult
    func startLive() async throws -> Int {
        await MainActor.run {
            self.sessionBytes = 0
            self.sessionFrames = 0
        }
        rttLock.lock()
        rttSumMs = 0
        rttCount = 0
        rttMaxMs = 0
        rttLock.unlock()
        let body = try JSONSerialization.data(withJSONObject: ["max_width": LiveConfig.fallbackMaxWidth])
        AppLog.shared.log("pc", "/live_start 请求宽 \(LiveConfig.fallbackMaxWidth)")
        // 登录很可能就发生在刚才那一页：发之前先搬一次，401 再搬一次重试（见 callWithAuthRetry）。
        let (data, resp) = try await callWithAuthRetry("/live_start", body: body,
                                                       contentType: "application/json",
                                                       refreshBefore: true)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        AppLog.shared.log("pc", "/live_start HTTP \(code)")
        if let http = resp as? HTTPURLResponse, LiveAuth.lost(http) {
            await MainActor.run { self.sessionLost = true }
            // 页面 store 里一条 cookie 都没有：多半是在别的浏览器登录的，或者在别的页面上。
            throw SwapError(message: hasPageCookies
                ? LiveAuth.lostMessage
                : "这一页还没登录（原生取不到会话 cookie）：先在 App 打开的页面上登录，再点「播放」")
        }
        let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard code == 200, let j = j, (j["status"] as? String) == "success" else {
            let why = (j?["message"] as? String)
                ?? (j == nil ? "PC 回的不是 JSON（多半是没登录，被弹到登录页）" : "HTTP \(code)")
            AppLog.shared.log("pc", "/live_start 失败：\(why)")
            throw SwapError(message: why)
        }
        if let w = (j["max_width"] as? NSNumber)?.intValue, w > 0 {
            liveWidth = w
        }
        AppLog.shared.log("pc", "/live_start 生效宽 \(liveWidth)")
        await MainActor.run {
            self.pcLiveMode = true
            self.sessionLost = false        // 能进得推流模式就说明 cookie 是好用的
        }
        beginStatusPolling()
        return liveWidth
    }

    /// 只有 PC 明确回了成功才算停：2xx 的 JSON 里 status=success（老接口回 204/空 200
    /// 就认 HTTP 码）。失败不能装作停了——界面那边要靠这个返回值决定锁不放开。
    @discardableResult
    func stopLive() async -> Bool {
        statusTask?.cancel()
        statusTask = nil
        let ok: Bool
        do {
            let (data, resp) = try await callWithAuthRetry("/live_stop", body: Data(),
                                                           contentType: nil)
            if let http = resp as? HTTPURLResponse {
                guard (200..<300).contains(http.statusCode), !LiveAuth.lost(http) else {
                    return false
                }
            } else {
                return false
            }
            if data.isEmpty {
                ok = true
            } else if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                ok = (j["status"] as? String) == "success"
            } else {
                ok = false
            }
        } catch {
            AppLog.shared.log("pc", "/live_stop 没送到：\(error.localizedDescription)")
            return false
        }
        AppLog.shared.log("pc", "/live_stop \(ok ? "成功" : "失败")")
        await MainActor.run { self.pcLiveMode = false }
        return ok
    }

    /// 跳转以后必须调：PC 会丢掉队列里的旧帧和上一姿势的检测缓存，否则糊到跳转之后。
    func seek() async {
        _ = try? await callWithAuthRetry("/live_seek", body: Data(), contentType: nil)
    }

    /// 回前台时先问一次再决定要不要重新 startLive——不看状态就猛推会一路吃 409。
    func fetchStatusOnce() async -> LiveSnapshot? {
        var req = URLRequest(url: url("/live_status"))
        authorize(&req)
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        if LiveAuth.lost(http) {
            // 401：页面那边可能刚重登，搬一次给下一轮用；这一轮按「读不到」处理。
            importCookies()
            return nil
        }
        guard http.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return LiveSnapshot(
            liveMode: (j["live_mode"] as? Bool) ?? false,
            framesIn: (j["frames_in"] as? NSNumber)?.intValue ?? 0,
            framesDropped: (j["frames_dropped"] as? NSNumber)?.intValue ?? 0,
            inputAgeMs: (j["input_age_ms"] as? NSNumber)?.intValue,
            outputAgeMs: (j["output_age_ms"] as? NSNumber)?.intValue,
            planCount: (j["plan_count"] as? NSNumber)?.intValue ?? 0,
            swappedFaces: (j["swapped_faces"] as? NSNumber)?.intValue ?? 0,
            bestSim: (j["best_sim"] as? NSNumber)?.doubleValue,
            matchThr: (j["match_thr"] as? NSNumber)?.doubleValue
        )
    }

    /// 点「播放」而手机还没选片时问一句：PC 自己手上有没有片。
    /// 剪辑页「用于换脸」用 /set_video 写的就是它；空串 / 缺字段 = PC 也没有。
    func fetchVideoPathOnce() async -> String? {
        var req = URLRequest(url: url("/get_video_path"))
        authorize(&req)
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        if LiveAuth.lost(http) {
            importCookies()
            return nil
        }
        guard http.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let p = (j["video_path"] as? String) ?? ""
        return p.isEmpty ? nil : p
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
        planCount = snap.planCount
        swappedFaces = snap.swappedFaces
        bestSim = snap.bestSim
        matchThr = snap.matchThr
    }

    // MARK: - 数据面（每帧一次，回调式，不为每帧起一个 Task）

    /// 满 3 帧在途就丢新帧（丢最新），绝不排队——
    /// PC 入口队列只有 2 格且满则丢最旧，手机这边再排一层只会把延迟堆起来。
    /// authRetried 只给「401 后搬完 cookie 重发这一帧」用，最多一次，不会打转。
    func push(_ jpeg: Data, authRetried: Bool = false) {
        guard inflight.wait(timeout: .now()) == .success else {
            DispatchQueue.main.async { self.framesDroppedLocal += 1 }
            return
        }
        let sentAt = CFAbsoluteTimeGetCurrent()
        var req = URLRequest(url: url("/live_frame"))
        req.httpMethod = "POST"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = jpeg
        authorize(&req)
        session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            self.inflight.signal()
            if let err = err {
                let ns = err as NSError
                // 手机侧网络抖一下不值得占一整行状态栏，计数留给自测和后台日志
                if ns.code != NSURLErrorCancelled {
                    self.logThrottled("neterr", "发帧失败：\(ns.domain) \(ns.code) "
                                                    + ns.localizedDescription, every: 5)
                    DispatchQueue.main.async {
                        self.lastError = "live_frame: \(ns.domain) \(ns.code)"
                    }
                }
                return
            }
            guard let http = resp as? HTTPURLResponse else { return }
            // 拿到回应才记：往返慢说明链路/PC 在拖，和手机编码是两笔账。
            self.noteRTT((CFAbsoluteTimeGetCurrent() - sentAt) * 1000)
            switch LiveAuth.judge(http) {
            case .sessionLost:
                if authRetried {
                    // 搬过一次还是 401：页面那边确实没登录了，停下来让人重登。
                    self.logThrottled("auth", "帧被弹回登录页：会话失效（HTTP \(http.statusCode)）",
                                      every: 10)
                    DispatchQueue.main.async {
                        self.sessionLost = true
                        self.lastError = LiveAuth.lostMessage
                    }
                } else {
                    // 第一回 401 不急着停推流：重新搬一次 cookie，这一帧再发一次。
                    self.importCookies {
                        self.push(jpeg, authRetried: true)
                    }
                }
            case .notLive:
                // 409 = PC 已退出推流模式（10 秒空闲看门狗或那边重启），必须重新 /live_start
                self.logThrottled("409", "发帧吃 409：PC 已退出推流模式")
                DispatchQueue.main.async {
                    self.saw409 += 1
                    self.lastError = "PC 已退出推流模式（静默超时或重启）"
                }
            case .rejected(let code):
                // 400 解不开、413 超 2MB、503 流水线没起、405 方法不对：这些都不算送到。
                // PC 的响应体写着到底是「空帧」还是「JPEG 解码失败」——身体不能扔。
                let body = data.map { String(decoding: $0.prefix(240), as: UTF8.self) } ?? ""
                let why = body.trimmingCharacters(in: .whitespacesAndNewlines)
                self.logThrottled("reject", "PC 拒了这一帧：HTTP \(code)"
                                                + (why.isEmpty ? "" : " \(why)"))
                DispatchQueue.main.async {
                    self.framesRejected += 1
                    self.lastError = "PC 拒了这一帧：HTTP \(code)"
                }
            case .accepted:
                DispatchQueue.main.async {
                    self.framesSent += 1
                    self.sessionBytes += jpeg.count
                    self.sessionFrames += 1
                }
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
        authorize(&req)
        return try await session.data(for: req)
    }

    /// 401 就是「会话没带上/失效了」：重新从页面搬一次 cookie，再按原请求发一遍，最多重试一次。
    /// 重试后还 401 的由调用方判 sessionLost（startLive 会抛，帧会停推流）。
    private func callWithAuthRetry(_ path: String, body: Data, contentType: String?,
                                   refreshBefore: Bool = false) async throws
        -> (Data, URLResponse) {
        if refreshBefore { await refreshCookies() }
        var out = try await call(path, body: body, contentType: contentType)
        if let http = out.1 as? HTTPURLResponse, LiveAuth.lost(http) {
            await refreshCookies()
            out = try await call(path, body: body, contentType: contentType)
        }
        return out
    }
}

struct SwapError: LocalizedError {
    let message: String
    init(message: String) { self.message = message }
    var errorDescription: String? { message }
}
