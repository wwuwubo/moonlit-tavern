import Foundation

/// 提示词模板。不同模型家族的对话格式不同，格式错了模型会胡言乱语。
public enum PromptFormat: String, Codable, CaseIterable, Sendable {
    /// 根据 GGUF 里的 `tokenizer.chat_template` 自动识别
    case auto
    /// Qwen 系列等使用的 ChatML
    case chatml
    /// Gemma 2 / 3 风格
    case gemma
    /// Llama 3 风格
    case llama3
    /// Mistral [INST] 风格
    case mistral
    /// 交给 llama.cpp 的内置模板引擎（识别不了的模型走这里）
    case modelBuiltin
    /// 无模板的纯文本续写
    case plain

    public var label: String {
        switch self {
        case .auto: return "自动识别"
        case .chatml: return "ChatML（Qwen 等）"
        case .gemma: return "Gemma"
        case .llama3: return "Llama 3"
        case .mistral: return "Mistral"
        case .modelBuiltin: return "模型内置模板"
        case .plain: return "纯文本"
        }
    }

    /// 根据 GGUF 元数据里的模板文本识别格式。
    public static func detect(chatTemplate: String?, architecture: String?) -> PromptFormat {
        if let t = chatTemplate, !t.isEmpty {
            if t.contains("<|im_start|>") { return .chatml }
            if t.contains("<start_of_turn>") { return .gemma }
            if t.contains("<|start_header_id|>") { return .llama3 }
            if t.contains("[INST]") { return .mistral }
            return .modelBuiltin
        }
        switch architecture?.lowercased() ?? "" {
        case let a where a.hasPrefix("qwen"): return .chatml
        case "gemma", "gemma2", "gemma3": return .gemma
        case "llama": return .llama3
        default: return .plain
        }
    }

    /// 模板里出现 <think> 说明模型支持思考模式。
    public static func supportsThinking(chatTemplate: String?) -> Bool {
        guard let t = chatTemplate else { return false }
        return t.contains("<think>") || t.contains("enable_thinking")
    }
}

/// 发给模型的一条消息（已完成宏替换、名字前缀等处理）。
public struct PromptMessage: Hashable, Sendable {
    public var role: MessageRole
    public var content: String

    public init(role: MessageRole, content: String) {
        self.role = role
        self.content = content
    }
}

public struct RenderedPrompt: Sendable {
    public var text: String
    /// 模型应在这些字符串处停下（模板自身的结束标记）。
    public var stopSequences: [String]
}

public enum ChatTemplateRenderer {
    /// 把消息渲染为模型输入文本。
    /// - Parameters:
    ///   - prefill: 助手回复的开头（群聊时是「角色名：」），会紧接在助手起始标记之后。
    ///   - disableThinking: 对支持思考模式的模型，预先写入空的思考块，让模型直接作答。
    public static func render(
        _ messages: [PromptMessage],
        format: PromptFormat,
        prefill: String = "",
        disableThinking: Bool = false,
        modelSupportsThinking: Bool = false
    ) -> RenderedPrompt {
        let merged = mergeConsecutive(messages)
        switch format {
        case .chatml, .auto, .modelBuiltin:
            var out = ""
            for m in merged {
                out += "<|im_start|>\(roleName(m.role))\n\(m.content)<|im_end|>\n"
            }
            out += "<|im_start|>assistant\n"
            if disableThinking && modelSupportsThinking {
                out += "<think>\n\n</think>\n\n"
            }
            out += prefill
            return RenderedPrompt(text: out, stopSequences: ["<|im_end|>", "<|im_start|>", "<|endoftext|>"])

        case .gemma:
            // Gemma 没有 system 角色：并入第一条 user 消息
            var turns = merged
            if let first = turns.first, first.role == .system {
                turns.removeFirst()
                if let idx = turns.firstIndex(where: { $0.role == .user }) {
                    turns[idx].content = first.content + "\n\n" + turns[idx].content
                } else {
                    turns.insert(PromptMessage(role: .user, content: first.content), at: 0)
                }
            }
            turns = mergeConsecutive(turns.map { $0.role == .system ? PromptMessage(role: .user, content: $0.content) : $0 })
            // Gemma 要求以 user 开头
            if turns.first?.role == .assistant {
                turns.insert(PromptMessage(role: .user, content: "（继续）"), at: 0)
            }
            var out = ""
            for m in turns {
                let role = m.role == .assistant ? "model" : "user"
                out += "<start_of_turn>\(role)\n\(m.content)<end_of_turn>\n"
            }
            out += "<start_of_turn>model\n" + prefill
            return RenderedPrompt(text: out, stopSequences: ["<end_of_turn>", "<start_of_turn>"])

        case .llama3:
            var out = ""
            for m in merged {
                out += "<|start_header_id|>\(roleName(m.role))<|end_header_id|>\n\n\(m.content)<|eot_id|>"
            }
            out += "<|start_header_id|>assistant<|end_header_id|>\n\n" + prefill
            return RenderedPrompt(text: out, stopSequences: ["<|eot_id|>", "<|start_header_id|>", "<|end_of_text|>"])

        case .mistral:
            var system = ""
            var turns = merged
            if let first = turns.first, first.role == .system {
                system = first.content
                turns.removeFirst()
            }
            turns = mergeConsecutive(turns.map { $0.role == .system ? PromptMessage(role: .user, content: $0.content) : $0 })
            var out = ""
            var systemPending = !system.isEmpty
            for m in turns {
                if m.role == .user {
                    let body = systemPending ? system + "\n\n" + m.content : m.content
                    systemPending = false
                    out += "[INST] \(body) [/INST]"
                } else {
                    out += " \(m.content)</s>"
                }
            }
            if systemPending { out += "[INST] \(system) [/INST]" }
            out += prefill
            return RenderedPrompt(text: out, stopSequences: ["</s>", "[INST]"])

        case .plain:
            var out = ""
            for m in merged {
                switch m.role {
                case .system: out += m.content + "\n\n"
                case .user, .assistant: out += m.content + "\n"
                }
            }
            out += prefill
            return RenderedPrompt(text: out, stopSequences: [])
        }
    }

    static func roleName(_ role: MessageRole) -> String {
        switch role {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        }
    }

    /// 合并相邻同角色消息。多数模板不允许连续两条 user 或 assistant。
    public static func mergeConsecutive(_ messages: [PromptMessage]) -> [PromptMessage] {
        var result: [PromptMessage] = []
        for m in messages where !m.content.isEmpty {
            if let last = result.last, last.role == m.role {
                result[result.count - 1].content += "\n\n" + m.content
            } else {
                result.append(m)
            }
        }
        return result
    }
}
