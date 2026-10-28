import Foundation

/// OpenAI Chat Completions 兼容协议的请求构造与流式响应解析（与网络层分离，便于测试）。
public enum OpenAICompatible {
    /// 构造请求体。群聊的发言提示以 system 消息形式附在末尾，因为多数服务不支持助手预填。
    public static func requestBody(model: String, request: GenerationRequest) throws -> Data {
        var messages: [[String: Any]] = ChatTemplateRenderer.mergeConsecutive(request.messages).map {
            ["role": roleName($0.role), "content": $0.content]
        }
        if !request.prefill.isBlank {
            let name = request.prefill.trimmingCharacters(in: CharacterSet(charactersIn: "：: "))
            messages.append(["role": "system", "content": "以「\(name)」的身份直接回复，不要加名字前缀。"])
        }
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "temperature": request.sampling.temperature,
            "top_p": request.sampling.topP,
            "max_tokens": request.maxNewTokens
        ]
        if request.sampling.presencePenalty != 0 { body["presence_penalty"] = request.sampling.presencePenalty }
        if request.sampling.frequencyPenalty != 0 { body["frequency_penalty"] = request.sampling.frequencyPenalty }
        // OpenAI 官方接口最多 4 个停止词
        let stops = Array(request.stopSequences.filter { !$0.isEmpty }.prefix(4))
        if !stops.isEmpty { body["stop"] = stops }
        if let seed = request.sampling.seed { body["seed"] = Int(seed) }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func roleName(_ role: MessageRole) -> String {
        switch role {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        }
    }

    public static func chatCompletionsURL(base: String) -> URL? {
        var trimmed = base.trimmed
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/chat/completions") { return URL(string: trimmed) }
        return URL(string: trimmed + "/chat/completions")
    }

    public enum StreamEvent: Equatable, Sendable {
        case delta(String)
        case done(finishReason: String?)
        case error(String)
    }

    /// Server-Sent Events 行解析器。逐行输入，输出增量文本。
    public struct SSEParser: Sendable {
        public private(set) var promptTokens: Int?
        public private(set) var completionTokens: Int?

        public init() {}

        public mutating func parse(line rawLine: String) -> StreamEvent? {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { return nil }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return .done(finishReason: nil) }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if let error = json["error"] as? [String: Any] {
                return .error((error["message"] as? String) ?? "未知错误")
            }
            if let usage = json["usage"] as? [String: Any] {
                promptTokens = usage["prompt_tokens"] as? Int ?? promptTokens
                completionTokens = usage["completion_tokens"] as? Int ?? completionTokens
            }
            guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else { return nil }
            if let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String, !content.isEmpty {
                return .delta(content)
            }
            if let reason = first["finish_reason"] as? String {
                return .done(finishReason: reason)
            }
            return nil
        }
    }

    /// 从错误响应体中取出可读信息。不包含请求头，因此不会泄露 API Key。
    public static func errorMessage(from body: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = json["message"] as? String { return message }
        }
        let text = String(decoding: body.prefix(300), as: UTF8.self)
        return text.isBlank ? "无响应内容" : text
    }
}
