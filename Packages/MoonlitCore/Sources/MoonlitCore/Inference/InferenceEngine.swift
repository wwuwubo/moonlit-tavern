import Foundation

/// 本地模型与云端服务共同遵循的推理接口。界面和聊天逻辑只认这个协议。
public protocol InferenceEngine: AnyObject, Sendable {
    /// 例如 "llama.cpp (Metal)" 或 "OpenAI 兼容 API"
    var engineName: String { get }
    /// 本地引擎为 true。界面据此显示「离线」标记。
    var isLocal: Bool { get }

    /// 开始一次生成。取消 Task 或调用 `cancel()` 都会尽快停止。
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>

    func cancel()

    /// 用模型自己的分词器计数；拿不到时返回 nil，由调用方估算。
    func tokenCounter() -> TokenCounter?
}

public struct GenerationRequest: Sendable {
    /// 结构化消息（云端直接使用；本地按模板渲染）。
    public var messages: [PromptMessage]
    public var prefill: String
    public var sampling: SamplingParams
    public var maxNewTokens: Int
    /// 角色扮演层面的停止词。模板自身的结束标记由引擎补充。
    public var stopSequences: [String]
    /// 用途标记：普通回复、摘要或剧情选项。后两者不作为角色发言显示。
    public var purpose: Purpose
    /// 至少生成多少 token 才允许模型收尾（本地模型在此之前屏蔽结束符；云端忽略）。
    public var minNewTokens: Int
    /// 开头有几条消息在之后的请求里会原样保留（系统设定 + 聊天历史）。
    /// 后面跟着的是只用这一次的指令（回复前提醒、剧情选项说明）。
    /// 本地引擎在这几条的结尾处存一个缓存检查点，下一轮从这里接着算。nil 表示全部消息都会保留。
    public var stableMessageCount: Int?

    public enum Purpose: String, Sendable {
        case reply
        case summary
        case suggestions
    }

    public init(
        messages: [PromptMessage],
        prefill: String = "",
        sampling: SamplingParams,
        maxNewTokens: Int,
        stopSequences: [String] = [],
        purpose: Purpose = .reply,
        minNewTokens: Int = 0,
        stableMessageCount: Int? = nil
    ) {
        self.messages = messages
        self.prefill = prefill
        self.sampling = sampling
        self.maxNewTokens = maxNewTokens
        self.stopSequences = stopSequences
        self.purpose = purpose
        self.minNewTokens = minNewTokens
        self.stableMessageCount = stableMessageCount
    }
}

public enum GenerationPhase: String, Sendable {
    case loadingModel = "加载模型"
    case processingPrompt = "读取上下文"
    case generating = "生成中"
    case connecting = "连接中"
}

public enum GenerationEvent: Sendable {
    /// 进度：阶段与 0...1 的比例（未知时为 nil）。
    case progress(GenerationPhase, Double?)
    /// 新增的可见文本。
    case text(String)
    /// 结束，附带真实统计。
    case finished(GenerationStats)
}

public enum InferenceError: Error, LocalizedError, Equatable {
    case noModelSelected
    case modelFileMissing(String)
    case modelLoadFailed(String)
    case contextCreationFailed(String)
    case insufficientMemory(requiredMB: Int, availableMB: Int)
    case promptTooLong(tokens: Int, context: Int)
    case decodeFailed(Int32)
    case backendUnavailable(String)
    case cloudNotConfigured
    case cloudHTTP(status: Int, message: String)
    case cloudProtocol(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return "还没有选择本地模型。请到「设置 → 模型管理」导入或下载一个 GGUF 模型。"
        case .modelFileMissing(let name):
            return "找不到模型文件 \(name)，它可能已被删除或移动。"
        case .modelLoadFailed(let detail):
            return "模型加载失败：\(detail)"
        case .contextCreationFailed(let detail):
            return "无法创建推理上下文：\(detail)。可以尝试把上下文长度降到 4096。"
        case .insufficientMemory(let required, let available):
            return "内存不足：预计需要约 \(required) MB，当前应用可用约 \(available) MB。请换更小的量化版本，或降低上下文长度。"
        case .promptTooLong(let tokens, let context):
            return "提示词有 \(tokens) 个 token，超过了上下文长度 \(context)。"
        case .decodeFailed(let code):
            return "推理过程出错（llama_decode 返回 \(code)）。"
        case .backendUnavailable(let detail):
            return detail
        case .cloudNotConfigured:
            return "云端模式还没配置好：需要填写 API 地址、模型名和 API Key。"
        case .cloudHTTP(let status, let message):
            return "云端服务返回错误 \(status)：\(message)"
        case .cloudProtocol(let detail):
            return "云端响应格式异常：\(detail)"
        case .cancelled:
            return "已停止生成"
        }
    }
}
