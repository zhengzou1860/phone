import Foundation

/// ⑥「和 AI 聊天」到电脑上那个「AI Local Model Manager」代理的三条 HTTP。
///
/// 请求体和事件解析逐字照它前端 `index.html` 的形状（那边发的是 `POST /v1/chat/completions`，
/// body 里有 `chat_template_kwargs.enable_thinking` 和代理私有的 `web_search` 开关）。
/// 同一个代理不许有第二套方言，所以这边不自己发明字段：
///   GET  /api/dashboard  → models[]（带 state，就绪的那个才是能选的）
///   GET  /api/queue      → 这条还没进队时的排队预估
///   POST /v1/chat/completions → SSE 里 `delta.content` 是回答、`delta.reasoning_content` 是思考，
///                               `:` 开头的注释行给联网进度和排队校正。
enum ChatNet {
    struct Failure: LocalizedError {
        var text: String
        var errorDescription: String? { text }
    }

    struct ModelRow {
        var name: String
        var state: String
        var online: Bool
        /// 代理 `info.vision`：true = 投影器已加载能读图，false = 没加载，nil = 那个后端不上报模态。
        /// 网页在 Models 页卡片上写「读图（截图问答）」那一行（index.html:1635），这边发图前要用它拦一句。
        var vision: Bool? = nil
        /// 网页那条 select 括号里的话，一字不改。
        var tag: String { ready ? "（就绪）" : (online ? "（后端在线 · 未加载）" : "（离线）") }
        var ready: Bool { state == "busy" || state == "idle" }
    }

    struct Src: Codable {
        var url: String
        var title: String
        var query: String
        var rank: Int
    }

    struct Queue {
        var occupied = false
        var ahead = 0
        var waitS: Double? = nil
        var note = ""
    }

    /// answer/think 给的是**累积后**的全文：气泡整块替换，两边不用各拼一份。
    enum Event {
        case answer(String)
        case think(String)
        case search(String)
        case sources([Src])
        /// 代理注释里的 wait_s；nil = 它自己说「未知」。
        case queue(Double?)
    }

    struct Answer {
        var text = ""
        var think = ""
        var sources: [Src] = []
        /// 非空 = 这一回合没拿到回答，气泡要改写成红条（网页那个 `failed`）。
        var note = ""
    }

    /// 手填地址最常见的漏法是只写 IP:端口。补 http://，尾巴的斜杠去掉。
    static func normalized(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func endpoint(_ base: String, _ path: String) -> URL? {
        let n = normalized(base)
        guard !n.isEmpty else { return nil }
        return URL(string: n + path)
    }

    static func dashboard(_ base: String) async throws -> [ModelRow] {
        let (data, http) = try await get(base, "/api/dashboard", 12)
        guard http.statusCode == 200 else {
            throw Failure(text: "Error: /api/dashboard HTTP \(http.statusCode)")
        }
        let obj = try? JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any], let arr = root["models"] as? [[String: Any]] else {
            throw Failure(text: "Network error: /api/dashboard 回来的不是那个形状")
        }
        return arr.compactMap { m in
            guard let n = m["name"] as? String, !n.isEmpty else { return nil }
            let info = m["info"] as? [String: Any] ?? [:]
            return ModelRow(name: n,
                            state: (m["state"] as? String) ?? "",
                            online: (m["online"] as? Bool) ?? false,
                            vision: info["vision"] as? Bool)
        }
    }

    static func queue(_ base: String, model: String) async throws -> Queue {
        let enc = model.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? model
        let (data, http) = try await get(base, "/api/queue?model=" + enc, 8)
        guard http.statusCode == 200 else {
            throw Failure(text: "Error: /api/queue HTTP \(http.statusCode)")
        }
        let obj = try? JSONSerialization.jsonObject(with: data)
        let d = obj as? [String: Any] ?? [:]
        var q = Queue()
        q.occupied = (d["occupied"] as? Bool) ?? false
        q.ahead = (d["ahead"] as? Int) ?? 0
        q.note = (d["note"] as? String) ?? ""
        if let n = d["wait_s"] as? NSNumber { q.waitS = n.doubleValue }
        return q
    }

    /// 发一条。失败不抛：网页就是把失败当成一条红气泡（`Error: …` / `Network error: …`），
    /// 这边照样，`Answer.note` 非空即红条。
    /// `history` 的 content 是 `Any`：没附件时是字符串，有图时是 OpenAI 的多模态 parts 数组
    /// （网页 userContent，index.html:798），同一个代理两种形状都得能收。
    static func chat(base: String, model: String, history: [[String: Any]], stream: Bool,
                     thinking: Bool, web: Bool, onEvent: @escaping (Event) -> Void) async -> Answer {
        var a = Answer()
        guard let url = endpoint(base, "/v1/chat/completions") else {
            a.note = "Network error: 地址非法"
            return a
        }
        var payload: [String: Any] = [
            "model": model,
            "messages": history,
            "stream": stream,
            "temperature": 0.8,
            "max_tokens": 8192,
            "chat_template_kwargs": ["enable_thinking": thinking],
        ]
        if web { payload["web_search"] = true }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            a.note = "Network error: 请求体拼不出来"
            return a
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        // 排队那几分钟一个字节都不回来，默认「60 s 不活跃就断」会天天误报 ⇒ 给到 5 分钟。
        req.timeoutInterval = 300

        var text = ""
        var think = ""
        var errText = ""

        if stream {
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    a.note = "Network error: 回来的不是 HTTP 响应"
                    return a
                }
                if http.statusCode != 200 {
                    var msg = ""
                    for try await line in bytes.lines {
                        msg += line
                        if msg.count > 400 { break }
                    }
                    a.note = "Error: " + String(msg.prefix(200))
                    return a
                }
                for try await line in bytes.lines {
                    let l = line.hasSuffix("\r") ? String(line.dropLast()) : line
                    if l.isEmpty { continue }
                    if l.hasPrefix(":") {
                        comment(l, into: &a, onEvent: onEvent)
                        continue
                    }
                    guard l.hasPrefix("data:") else { continue }
                    let raw = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if raw == "[DONE]" { break }
                    guard let d = raw.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: d) else { continue }
                    let o = obj as? [String: Any] ?? [:]
                    if let e = o["error"] as? [String: Any] {
                        errText = (e["message"] as? String) ?? "后端或代理返回了错误"
                        continue
                    }
                    let choices = o["choices"] as? [[String: Any]] ?? []
                    let delta = choices.first?["delta"] as? [String: Any] ?? [:]
                    if let rc = delta["reasoning_content"] as? String, !rc.isEmpty {
                        think += rc
                        onEvent(.think(think))
                    }
                    if let c = delta["content"] as? String, !c.isEmpty {
                        text += c
                        onEvent(.answer(text))
                    }
                }
            } catch {
                a.note = "Network error: " + error.localizedDescription
                return a
            }
        } else {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    a.note = "Network error: 回来的不是 HTTP 响应"
                    return a
                }
                if http.statusCode != 200 {
                    let msg = String(data: data, encoding: .utf8) ?? "?"
                    a.note = "Error: " + String(msg.prefix(200))
                    return a
                }
                let obj = try? JSONSerialization.jsonObject(with: data)
                let o = obj as? [String: Any] ?? [:]
                if let e = o["error"] as? [String: Any] {
                    errText = (e["message"] as? String) ?? "后端或代理返回了错误"
                }
                let choices = o["choices"] as? [[String: Any]] ?? []
                let msg = choices.first?["message"] as? [String: Any] ?? [:]
                think = (msg["reasoning_content"] as? String) ?? ""
                text = (msg["content"] as? String) ?? ""
                for raw in (o["search_sources"] as? [[String: Any]]) ?? [] {
                    a.sources.append(source(raw, query: (raw["query"] as? String) ?? ""))
                }
                if !a.sources.isEmpty {
                    let q = Set(a.sources.map { $0.query }).count
                    onEvent(.search("联网问答：查了 \(q) 次（整段返回，看不到实时进度）"))
                    onEvent(.sources(a.sources))
                }
            } catch {
                a.note = "Network error: " + error.localizedDescription
                return a
            }
        }

        a.think = think
        a.text = text
        if text.isEmpty {
            if !errText.isEmpty { a.text = "[联网问答失败] " + errText }
            else if !think.isEmpty { a.text = "[仅思考、无最终回答 — 可能被 max_tokens 截断，请再试]" }
            else { a.text = "[Empty response]" }
        }
        return a
    }

    /// SSE 的注释行（`:` 开头）：联网进度、搜索结果、排队校正。口径和网页那段一致。
    private static func comment(_ line: String, into a: inout Answer, onEvent: (Event) -> Void) {
        let s = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("web_search query=") {
            var q = String(s.dropFirst("web_search query=".count))
            if q.hasPrefix("\"") { q.removeFirst() }
            if q.hasSuffix("\"") { q.removeLast() }
            onEvent(.search("正在联网搜索 " + q + " …"))
            return
        }
        if s.hasPrefix("web_results ") {
            let js = String(s.dropFirst("web_results ".count))
            guard let d = js.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) else { return }
            let o = obj as? [String: Any] ?? [:]
            let query = (o["query"] as? String) ?? ""
            let list = ((o["sources"] as? [[String: Any]]) ?? []).map { source($0, query: query) }
            a.sources.append(contentsOf: list)
            let n = (o["n"] as? Int) ?? list.count
            onEvent(.sources(a.sources))
            onEvent(.search(n > 0 ? "联网搜到 \(n) 条，正在据此作答…" : "这次联网没查到，模型会照实说查不到"))
            return
        }
        if let r = s.range(of: "wait_s=") {
            let tail = String(s[r.upperBound...])
            if tail.hasPrefix("unknown") {
                onEvent(.queue(nil))
                return
            }
            let digits = tail.prefix(while: { $0.isNumber })
            if digits.isEmpty { onEvent(.queue(nil)) } else { onEvent(.queue(Double(digits) ?? 0)) }
        }
    }

    private static func source(_ d: [String: Any], query: String) -> Src {
        Src(url: (d["url"] as? String) ?? "",
            title: (d["title"] as? String) ?? "",
            query: query,
            rank: (d["rank"] as? Int) ?? 1)
    }

    private static func get(_ base: String, _ path: String, _ timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        guard let url = endpoint(base, path) else { throw Failure(text: "地址非法：\(base)") }
        let req = URLRequest(url: url, timeoutInterval: timeout)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw Failure(text: "Network error: 回来的不是 HTTP 响应")
        }
        return (data, http)
    }
}