import Foundation

/// OpenAI 兼容客户端：优先用 tool call 拿结构化参数，失败退回 JSON 正文。
final class VisionClient {

    struct Config {
        var baseURL: String = "http://cheap-host1.cheapyun.com:20033/v1"
        var apiKey: String = ""
        var model: String = "hy4free"
        var maxTokens: Int = 8000
        var temperature: Double = 0.35
        /// 思考开关：none | qwen | reasoning
        var thinkingStyle: String = "none"
        /// 是否优先使用 tool call（比裸 JSON 稳，尤其是 only_reasoning 模型）
        var useTools: Bool = true
    }

    enum Event {
        case reasoning(String)   // 模型自身 thinking 增量
        case toolArgs(String)    // tool call 的 arguments 增量（JSON 片段）
        case content(String)     // 正文增量（JSON 模式下才有）
        case reset              // 换一种请求形态重试，清空已收内容
        case done
    }

    /// 一次请求的形态，按可靠性从高到低重试
    private enum Mode {
        case toolAuto     // tools + tool_choice=auto
        case prefill      // 预填 assistant="{"，逼模型接着写 JSON
        case jsonObject   // response_format=json_object
        case plain        // 什么都不加
    }

    private(set) var config: Config
    init(config: Config) { self.config = config }
    func update(_ config: Config) { self.config = config }

    static let toolName = "apply_camera_settings"

    // MARK: - 发起请求
    func analyze(imageJPEG: Data, snapshot: CameraSnapshot) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [config] in
                var modes: [Mode] = []
                if config.useTools { modes.append(.toolAuto) }
                modes += [.prefill, .jsonObject, .plain]

                for (index, mode) in modes.enumerated() {
                    if index > 0 { continuation.yield(.reset) }
                    do {
                        let usable = try await Self.stream(config: config,
                                                           imageJPEG: imageJPEG,
                                                           snapshot: snapshot,
                                                           mode: mode,
                                                           into: continuation)
                        if usable { break }
                    } catch let error as ClientError {
                        if case .http(let code, _) = error, code == 400 || code == 422 {
                            continue
                        }
                        continuation.finish(throwing: error)
                        return
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func stream(config: Config,
                               imageJPEG: Data,
                               snapshot: CameraSnapshot,
                               mode: Mode,
                               into continuation: AsyncThrowingStream<Event, Error>.Continuation) async throws -> Bool {
        var argsBuffer = ""
        var contentBuffer = (mode == .prefill ? "{" : "")
        let request = try buildRequest(config: config, imageJPEG: imageJPEG,
                                       snapshot: snapshot, mode: mode)
        if mode == .prefill {
            // 补回被我们预填掉的那个 "{"
            continuation.yield(.content("{"))
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }
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

            // tool call 的 arguments 是分片到达的
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    if let fn = call["function"] as? [String: Any],
                       let args = fn["arguments"] as? String, !args.isEmpty {
                        argsBuffer += args
                        continuation.yield(.toolArgs(args))
                    }
                }
            }

            if let s = delta["content"] as? String, !s.isEmpty {
                contentBuffer += s
                continuation.yield(.content(s))
            }
        }

        // 只有拿到"含 capture/grade 的 JSON"或工具参数，才算这次尝试成功
        if !argsBuffer.isEmpty, StreamingJSON.looksLikeParams(argsBuffer) { return true }
        return StreamingJSON.looksLikeParams(contentBuffer)
    }

    // MARK: - 构造请求
    private static func buildRequest(config: Config,
                                     imageJPEG: Data,
                                     snapshot: CameraSnapshot,
                                     mode: Mode) throws -> URLRequest {
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

        switch mode {
        case .toolAuto:
            body["tools"] = tools
            body["tool_choice"] = "auto"
        case .prefill:
            // assistant 预填一个左括号，模型只能接着把 JSON 写完
            var msgs = body["messages"] as? [[String: Any]] ?? []
            msgs.append(["role": "assistant", "content": "{"])
            body["messages"] = msgs
        case .jsonObject:
            body["response_format"] = ["type": "json_object"]
        case .plain:
            break
        }

        switch config.thinkingStyle {
        case "qwen": body["chat_template_kwargs"] = ["enable_thinking": true]
        case "reasoning": body["reasoning_effort"] = "high"
        default: break
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - 工具定义
    private static func num(_ lo: Double, _ hi: Double) -> [String: Any] {
        ["type": "number", "minimum": lo, "maximum": hi]
    }

    private static var captureSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "lens": ["type": "string", "enum": ["ultraWide", "wide", "tele"]],
                "zoom": num(1, 20),
                "iso": num(20, 6400),
                "shutterSeconds": num(0.0001, 2),
                "exposureMode": ["type": "string", "enum": ["auto", "manual"]],
                "exposureBias": num(-8, 8),
                "focusMode": ["type": "string", "enum": ["auto", "locked"]],
                "lensPosition": num(0, 1),
                "whiteBalanceMode": ["type": "string", "enum": ["auto", "locked"]],
                "temperature": num(2000, 10000),
                "tint": num(-150, 150),
                "torch": num(0, 1),
                "hdr": ["type": "boolean"],
                "stabilization": ["type": "string", "enum": ["off", "standard", "cinematic"]],
                "aspect": ["type": "string", "enum": ["4:3", "16:9", "1:1"]]
            ],
            "required": ["zoom", "exposureMode", "focusMode", "whiteBalanceMode",
                         "temperature", "tint", "aspect"]
        ]
    }

    private static var gradeSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "exposureEV": num(-3, 3),
                "brightness": num(-1, 1),
                "contrast": num(-1, 1),
                "highlights": num(-1, 1),
                "shadows": num(-1, 1),
                "blacks": num(-1, 1),
                "whites": num(-1, 1),
                "gamma": num(0.5, 2.0),
                "clarity": num(-1, 1),
                "texture": num(-1, 1),
                "dehaze": num(-1, 1),
                "fade": num(0, 1),
                "curveShadows": num(-1, 1),
                "curveMidtones": num(-1, 1),
                "curveHighlights": num(-1, 1),
                "temperature": num(-100, 100),
                "tint": num(-100, 100),
                "vibrance": num(-1, 1),
                "saturation": num(-1, 1),
                "hueShift": num(-180, 180),
                "monochromeMix": num(0, 1),
                "splitShadowHue": num(0, 360),
                "splitShadowSat": num(0, 1),
                "splitHighlightHue": num(0, 360),
                "splitHighlightSat": num(0, 1),
                "sharpness": num(0, 1),
                "noiseReduction": num(0, 1),
                "noiseReductionDetail": num(0, 1),
                "grain": num(0, 1),
                "grainSize": num(0, 1),
                "vignette": num(-1, 1),
                "vignetteFeather": num(0, 1),
                "bloom": num(0, 1),
                "halation": num(0, 1),
                "chromaticAberration": num(-1, 1),
                "straightenAngle": num(-45, 45),
                "cropZoom": num(1, 2),
                "perspectiveVertical": num(-1, 1),
                "perspectiveHorizontal": num(-1, 1),
                "rotate90": ["type": "integer", "enum": [0, 1, 2, 3]],
                "style": ["type": "string",
                          "enum": ["natural", "cinematic", "portrait", "landscape",
                                   "street", "film", "moody", "vivid"]],
                "styleStrength": num(0, 1),
                "hsl": [
                    "type": "array",
                    "minItems": 8,
                    "maxItems": 8,
                    "items": [
                        "type": "object",
                        "properties": [
                            "center": num(0, 360),
                            "hue": num(-30, 30),
                            "saturation": num(-1, 1),
                            "luminance": num(-1, 1)
                        ],
                        "required": ["center"]
                    ]
                ]
            ],
            "required": ["exposureEV", "contrast", "highlights", "shadows",
                         "temperature", "tint", "vibrance", "saturation",
                         "clarity", "sharpness", "vignette"]
        ]
    }

    private static var tools: [[String: Any]] {
        [[
            "type": "function",
            "function": [
                "name": toolName,
                "description": "把完整的相机参数应用到当前取景画面。capture 控制硬件，grade 控制调色。必须一次性给出 capture 与 grade 两个完整对象。",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "capture": captureSchema,
                        "grade": gradeSchema,
                        "rationale": [
                            "type": "object",
                            "additionalProperties": ["type": "string"],
                            "description": "字段名 -> 一句话理由，至少 8 条"
                        ],
                        "warnings": ["type": "array", "items": ["type": "string"]],
                        "confidence": num(0, 1)
                    ],
                    "required": ["capture", "grade"]
                ]
            ]
        ]]
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
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let list = obj["data"] as? [[String: Any]] {
                    let ids = list.compactMap { $0["id"] as? String }
                    let vision = ids.filter {
                        let l = $0.lowercased()
                        return l.contains("vl") || l.contains("vision") || l.contains("4v") || l.contains("omni")
                    }
                    let note = vision.isEmpty ? "（未发现明显的视觉模型）"
                                              : "，视觉候选：\(vision.prefix(4).joined(separator: ", "))"
                    return (true, "连通，\(ids.count) 个模型：\(ids.prefix(6).joined(separator: ", "))\(note)")
                }
                return (true, "连通")
            }
            return (false, "HTTP \(http.statusCode)：\(String(text.prefix(200)))")
        } catch {
            return (false, error.localizedDescription)
        }
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
        return normalize(String(s[start...]))
    }

    /// 清理模型输出的"人味"：模板残留（/think、literal> 之类）与全角标点
    static func normalize(_ s: String) -> String {
        guard s.hasPrefix("{") else { return s }
        var chars = Array(s)

        // 跳到第一个真正的 key 引号，丢掉 {"{/think|"capture"...} 里的垃圾
        var i = 1
        while i < chars.count, chars[i] != "\"", chars[i] != "}" { i += 1 }
        if i > 1 { chars = ["{"] + chars[i...] }

        var out = ""
        var inString = false
        var escaped = false
        for ch in chars {
            if escaped { out.append(ch); escaped = false; continue }
            if inString {
                out.append(ch)
                if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true; out.append(ch)
            case "，": out.append(",")
            case "：": out.append(":")
            case "；": out.append(";")
            case "｛": out.append("{")
            case "｝": out.append("}")
            default: out.append(ch)
            }
        }
        return out
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

    /// 文本里是否已出现可用的参数对象（用于判断这次请求是否"成功"）
    static func looksLikeParams(_ raw: String) -> Bool {
        guard let (obj, _) = extract(raw) else { return false }
        return isParamObject(obj)
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
