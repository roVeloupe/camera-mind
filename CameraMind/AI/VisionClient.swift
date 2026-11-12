import Foundation

/// OpenAI 兼容客户端：流式接收模型自身的 thinking 与正文（纯 JSON）。
final class VisionClient {

    struct Config {
        var baseURL: String = "http://cheap-host1.cheapyun.com:20033/v1"
        var apiKey: String = ""
        var model: String = "hy4free"
        var maxTokens: Int = 8000
        var temperature: Double = 0.35
        /// 思考开关：none | qwen | reasoning（该网关默认就返回 reasoning，选 none 即可）
        var thinkingStyle: String = "none"
    }

    enum Event {
        case reasoning(String)   // 模型自身 thinking 增量
        case content(String)     // JSON 正文增量
        case done
    }

    private(set) var config: Config
    init(config: Config) { self.config = config }
    func update(_ config: Config) { self.config = config }

    // MARK: - 发起请求
    func analyze(imageJPEG: Data, snapshot: CameraSnapshot) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [config] in
                do {
                    do {
                        try await Self.stream(config: config, imageJPEG: imageJPEG,
                                              snapshot: snapshot, jsonMode: true,
                                              into: continuation)
                    } catch let error as ClientError {
                        // 有些服务不支持 response_format + 图片，去掉后重试一次
                        if case .http(let code, _) = error, code == 400 || code == 422 {
                            try await Self.stream(config: config, imageJPEG: imageJPEG,
                                                  snapshot: snapshot, jsonMode: false,
                                                  into: continuation)
                        } else {
                            throw error
                        }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func stream(config: Config,
                               imageJPEG: Data,
                               snapshot: CameraSnapshot,
                               jsonMode: Bool,
                               into continuation: AsyncThrowingStream<Event, Error>.Continuation) async throws {
        let request = try buildRequest(config: config, imageJPEG: imageJPEG,
                                       snapshot: snapshot, jsonMode: jsonMode)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw ClientError.http(http.statusCode, String(body.prefix(800)))
        }

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any]
            else { continue }

            for key in ["reasoning_content", "reasoning", "thinking", "reasoning_text"] {
                if let s = delta[key] as? String, !s.isEmpty {
                    continuation.yield(.reasoning(s))
                }
            }
            if let s = delta["content"] as? String, !s.isEmpty {
                continuation.yield(.content(s))
            }
        }
    }

    // MARK: - 连通性探测
    /// 返回 (是否可用, 描述)。只请求 /models，不消耗额度。
    static func probe(_ config: Config) async -> (Bool, String) {
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        guard let url = URL(string: base + "/models") else {
            return (false, "Base URL 格式错误")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return (false, "无 HTTP 响应") }
            let text = String(data: data, encoding: .utf8) ?? ""
            if (200..<300).contains(http.statusCode) {
                // 尝试提取模型名，方便确认是否支持视觉模型
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let list = obj["data"] as? [[String: Any]] {
                    let ids = list.compactMap { $0["id"] as? String }
                    let vision = ids.filter {
                        let l = $0.lowercased()
                        return l.contains("vl") || l.contains("vision") || l.contains("4v") || l.contains("omni")
                    }
                    let preview = ids.prefix(6).joined(separator: ", ")
                    let note = vision.isEmpty
                        ? "（未发现明显的视觉模型）"
                        : "，视觉候选：\(vision.prefix(4).joined(separator: ", "))"
                    return (true, "连通，\(ids.count) 个模型：\(preview)\(note)")
                }
                return (true, "连通")
            }
            return (false, "HTTP \(http.statusCode)：\(String(text.prefix(200)))")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - 构造请求
    private static func buildRequest(config: Config,
                                     imageJPEG: Data,
                                     snapshot: CameraSnapshot,
                                     jsonMode: Bool) throws -> URLRequest {
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        guard let url = URL(string: base + "/chat/completions") else {
            throw ClientError.badConfig("baseURL 无效：\(config.baseURL)")
        }

        let dataURL = "data:image/jpeg;base64," + imageJPEG.base64EncodedString()
        var body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            "messages": [
                ["role": "system", "content": PromptBuilder.system],
                ["role": "user", "content": [
                    ["type": "text", "text": PromptBuilder.userText(snapshot: snapshot)],
                    ["type": "image_url", "image_url": ["url": dataURL, "detail": "high"]]
                ]]
            ]
        ]
        if jsonMode {
            body["response_format"] = ["type": "json_object"]
        }
        switch config.thinkingStyle {
        case "qwen":
            body["chat_template_kwargs"] = ["enable_thinking": true]
        case "reasoning":
            body["reasoning_effort"] = "high"
        default:
            break
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }
}

// MARK: - 错误
enum ClientError: LocalizedError {
    case badResponse
    case http(Int, String)
    case badConfig(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "服务器无响应"
        case .http(let code, let body): return "HTTP \(code)：\(body)"
        case .badConfig(let msg): return msg
        }
    }
}

// MARK: - 流式 JSON 解析
/// 边收边解析：内容是不完整 JSON 时自动补齐括号，让参数能逐条落入界面。
enum StreamingJSON {

    /// 去掉 markdown 围栏、前后废话，只留最外层对象
    static func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if let fence = s.range(of: "```", options: .backwards) {
                s = String(s[..<fence.lowerBound])
            }
        }
        guard let start = s.firstIndex(of: "{") else { return "" }
        return String(s[start...])
    }

    static func parse(_ raw: String) -> [String: Any]? {
        extract(raw)?.obj
    }

    /// 从任意文本里挖出 JSON 对象。
    /// 关键：模型输出的 hsl 里还有嵌套对象，必须优先取包含 capture/grade 的最外层。
    static func extract(_ raw: String) -> (obj: [String: Any], complete: Bool)? {
        let cleaned = sanitize(raw)
        guard !cleaned.isEmpty else { return nil }

        if let obj = decode(cleaned), isParamObject(obj) {
            return (obj, isBalanced(cleaned))
        }

        let repaired = balance(cleaned)
        if let obj = decode(repaired), isParamObject(obj) {
            return (obj, false)
        }

        // 枚举所有起点，取"含 capture/grade 且最长"的那个
        let chars = Array(cleaned)
        var best: [String: Any]?
        var bestLen = 0
        for i in chars.indices where chars[i] == "{" {
            guard let end = matchBrace(chars, from: i) else { continue }
            let len = end - i
            guard len > bestLen else { continue }
            guard let obj = decode(String(chars[i...end])), isParamObject(obj) else { continue }
            best = obj
            bestLen = len
        }
        if let best { return (best, true) }

        if let obj = decode(repaired) { return (obj, false) }

        for i in chars.indices.reversed() where chars[i] == "{" {
            guard let end = matchBrace(chars, from: i) else { continue }
            if let obj = decode(String(chars[i...end])) { return (obj, true) }
        }
        return nil
    }

    private static func isParamObject(_ obj: [String: Any]) -> Bool {
        obj["capture"] != nil || obj["grade"] != nil
    }

    private static func matchBrace(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for i in start..<chars.count {
            let ch = chars[i]
            if escaped { escaped = false; continue }
            if inString {
                if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            if ch == "\"" { inString = true }
            else if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
        }
        return nil
    }

    private static func decode(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 括号是否闭合（忽略字符串内的括号）
    static func isBalanced(_ s: String) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        var sawBrace = false

        for ch in s {
            if escaped { escaped = false; continue }
            if inString {
                if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{": depth += 1; sawBrace = true
            case "}": depth -= 1
            default: break
            }
            if depth < 0 { return false }
        }
        return sawBrace && depth == 0 && !inString
    }

    /// 补齐未闭合的字符串、数组、对象，并删掉尾逗号
    static func balance(_ s: String) -> String {
        var out = ""
        var stack: [Character] = []
        var inString = false
        var escaped = false
        var lastNonSpace: Character = " "

        for ch in s {
            if escaped { out.append(ch); escaped = false; continue }
            if inString {
                out.append(ch)
                if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true; out.append(ch)
            case "{", "[": stack.append(ch); out.append(ch)
            case "}", "]":
                if let last = stack.last,
                   (last == "{" && ch == "}") || (last == "[" && ch == "]") {
                    stack.removeLast()
                }
                out.append(ch)
            default: out.append(ch)
            }
            if !ch.isWhitespace { lastNonSpace = ch }
        }

        if inString { out.append("\"") }
        if lastNonSpace == "," { out.removeLast() }

        // 去掉悬空的 key（形如 "foo":）
        while let colon = out.lastIndex(of: ":"),
              String(out[out.index(after: colon)...]).trimmingCharacters(in: .whitespaces).isEmpty {
            if let quote = out[..<colon].lastIndex(of: "\"") {
                let before = out[..<quote].lastIndex(of: "\"")
                if let start = before {
                    out = String(out[..<start])
                    if out.hasSuffix(",") { out.removeLast() }
                } else { break }
            } else { break }
        }

        for ch in stack.reversed() {
            out.append(ch == "{" ? "}" : "]")
        }
        return out
    }
}
