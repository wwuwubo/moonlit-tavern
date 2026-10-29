import Foundation

/// 采样参数。默认值偏向角色扮演：比问答略高的温度，加轻微重复惩罚。
public struct SamplingParams: Codable, Hashable, Sendable {
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var minP: Double
    public var repeatPenalty: Double
    public var repeatLastN: Int
    public var presencePenalty: Double
    public var frequencyPenalty: Double
    /// 单次回复的最大 token 数（即「回复长度」）。
    public var maxNewTokens: Int
    /// 为空表示每次随机。
    public var seed: UInt32?

    public init(
        temperature: Double = 0.8,
        topP: Double = 0.9,
        topK: Int = 40,
        minP: Double = 0.05,
        repeatPenalty: Double = 1.05,
        repeatLastN: Int = 256,
        presencePenalty: Double = 0.0,
        frequencyPenalty: Double = 0.0,
        maxNewTokens: Int = 400,
        seed: UInt32? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repeatPenalty = repeatPenalty
        self.repeatLastN = repeatLastN
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.maxNewTokens = maxNewTokens
        self.seed = seed
    }

    /// 写摘要时用的保守参数。
    public static let summarization = SamplingParams(
        temperature: 0.3, topP: 0.9, topK: 40, minP: 0.05,
        repeatPenalty: 1.05, repeatLastN: 128, maxNewTokens: 360
    )
}

public enum ProviderMode: String, Codable, CaseIterable, Sendable {
    case local
    case cloud
}

public enum KVCacheType: String, Codable, CaseIterable, Sendable {
    case f16
    case q8_0

    /// 每个元素的字节数（q8_0 为 32 元素块 34 字节）。
    public var bytesPerElement: Double {
        switch self {
        case .f16: return 2.0
        case .q8_0: return 34.0 / 32.0
        }
    }
}

/// 回复长度预设。
public enum ReplyLength: String, Codable, CaseIterable, Sendable {
    case short, medium, long, custom

    public var tokens: Int? {
        switch self {
        case .short: return 160
        case .medium: return 320
        case .long: return 640
        case .custom: return nil
        }
    }

    public var label: String {
        switch self {
        case .short: return "简短"
        case .medium: return "适中"
        case .long: return "详细"
        case .custom: return "自定义"
        }
    }
}

public struct LocalModelSettings: Codable, Hashable, Sendable {
    /// 当前选择的模型文件名（位于模型目录）。
    public var selectedModelFile: String?
    public var contextLength: Int
    public var kvCacheType: KVCacheType
    /// -1 表示全部层放到 GPU（Metal）。
    public var gpuLayers: Int
    /// 0 表示自动。
    public var threads: Int
    public var batchSize: Int
    public var flashAttention: Bool
    /// 提示词模板。auto 表示按模型元数据自动识别。
    public var promptFormat: PromptFormat
    /// 关闭「思考模式」（Qwen3 / Qwen3.5 等）。角色扮演默认关闭。
    public var disableThinking: Bool
    /// 切到后台时卸载模型，释放内存。
    public var unloadOnBackground: Bool

    public init(
        selectedModelFile: String? = nil,
        contextLength: Int = 8192,
        kvCacheType: KVCacheType = .q8_0,
        gpuLayers: Int = -1,
        threads: Int = 0,
        batchSize: Int = 512,
        flashAttention: Bool = true,
        promptFormat: PromptFormat = .auto,
        disableThinking: Bool = true,
        unloadOnBackground: Bool = false
    ) {
        self.selectedModelFile = selectedModelFile
        self.contextLength = contextLength
        self.kvCacheType = kvCacheType
        self.gpuLayers = gpuLayers
        self.threads = threads
        self.batchSize = batchSize
        self.flashAttention = flashAttention
        self.promptFormat = promptFormat
        self.disableThinking = disableThinking
        self.unloadOnBackground = unloadOnBackground
    }
}

/// 云端设置。API Key 不在这里，单独存进钥匙串。
public struct CloudSettings: Codable, Hashable, Sendable {
    public var baseURL: String
    public var model: String
    public var extraHeaders: [String: String]
    public var timeoutSeconds: Double

    public init(
        baseURL: String = "https://openrouter.ai/api/v1",
        model: String = "",
        extraHeaders: [String: String] = [:],
        timeoutSeconds: Double = 120
    ) {
        self.baseURL = baseURL
        self.model = model
        self.extraHeaders = extraHeaders
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct MemorySettings: Codable, Hashable, Sendable {
    public var autoSummarize: Bool
    /// 有这么多条消息掉出上下文窗口后，触发一次摘要。
    public var summarizeBatch: Int
    /// 长期记忆在提示词里的 token 预算。
    public var tokenBudget: Int
    /// 每次最多检索几条记忆（不含常驻与最新摘要）。
    public var maxRetrieved: Int

    public init(autoSummarize: Bool = true, summarizeBatch: Int = 12, tokenBudget: Int = 700, maxRetrieved: Int = 6) {
        self.autoSummarize = autoSummarize
        self.summarizeBatch = summarizeBatch
        self.tokenBudget = tokenBudget
        self.maxRetrieved = maxRetrieved
    }
}

/// 剧情选项：角色回复后，替用户想几个下一步的选择。
public struct SuggestionSettings: Codable, Hashable, Sendable {
    /// 每次回复后自动生成
    public var enabled: Bool
    /// 选项个数（2–4）
    public var count: Int

    public init(enabled: Bool = true, count: Int = 3) {
        self.enabled = enabled
        self.count = count
    }

    enum CodingKeys: String, CodingKey { case enabled, count }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        count = min(max(try c.decodeIfPresent(Int.self, forKey: .count) ?? 3, 2), 4)
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var providerMode: ProviderMode
    public var local: LocalModelSettings
    public var cloud: CloudSettings
    public var sampling: SamplingParams
    public var replyLength: ReplyLength
    public var persona: UserPersona
    /// 全局角色扮演系统提示词。角色卡自带 system prompt 时，可用 {{original}} 引用它。
    public var defaultSystemPrompt: String
    public var memory: MemorySettings
    /// 世界书默认 token 预算。
    public var loreTokenBudget: Int
    /// 是否在提示词中放入示例对话。
    public var includeExampleDialogue: Bool
    /// 剧情选项
    public var suggestions: SuggestionSettings

    public init(
        providerMode: ProviderMode = .local,
        local: LocalModelSettings = LocalModelSettings(),
        cloud: CloudSettings = CloudSettings(),
        sampling: SamplingParams = SamplingParams(),
        replyLength: ReplyLength = .medium,
        persona: UserPersona = UserPersona(),
        defaultSystemPrompt: String = AppSettings.builtinSystemPrompt,
        memory: MemorySettings = MemorySettings(),
        loreTokenBudget: Int = 900,
        includeExampleDialogue: Bool = true,
        suggestions: SuggestionSettings = SuggestionSettings()
    ) {
        self.providerMode = providerMode
        self.local = local
        self.cloud = cloud
        self.sampling = sampling
        self.replyLength = replyLength
        self.persona = persona
        self.defaultSystemPrompt = defaultSystemPrompt
        self.memory = memory
        self.loreTokenBudget = loreTokenBudget
        self.includeExampleDialogue = includeExampleDialogue
        self.suggestions = suggestions
    }

    /// 实际使用的回复长度。
    public var effectiveMaxNewTokens: Int {
        replyLength.tokens ?? sampling.maxNewTokens
    }

    public static let builtinSystemPrompt = """
    你正在参与一场与{{user}}的沉浸式角色扮演，你扮演{{char}}。
    规则：
    1. 只以{{char}}的身份说话和行动，绝不替{{user}}说话、行动或做决定。
    2. 严格遵循{{char}}的性格、背景与说话风格，保持前后一致。
    3. 推动剧情发展，描写具体的动作、神态和环境，避免空洞的重复。
    4. 动作和心理描写放在 *星号* 里，对白直接写出。
    5. 使用与{{user}}相同的语言回复。
    """

    enum CodingKeys: String, CodingKey {
        case providerMode, local, cloud, sampling, replyLength, persona, defaultSystemPrompt, memory
        case loreTokenBudget, includeExampleDialogue, suggestions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providerMode = try c.decodeIfPresent(ProviderMode.self, forKey: .providerMode) ?? .local
        local = try c.decodeIfPresent(LocalModelSettings.self, forKey: .local) ?? LocalModelSettings()
        cloud = try c.decodeIfPresent(CloudSettings.self, forKey: .cloud) ?? CloudSettings()
        sampling = try c.decodeIfPresent(SamplingParams.self, forKey: .sampling) ?? SamplingParams()
        replyLength = try c.decodeIfPresent(ReplyLength.self, forKey: .replyLength) ?? .medium
        persona = try c.decodeIfPresent(UserPersona.self, forKey: .persona) ?? UserPersona()
        defaultSystemPrompt = try c.decodeIfPresent(String.self, forKey: .defaultSystemPrompt) ?? AppSettings.builtinSystemPrompt
        memory = try c.decodeIfPresent(MemorySettings.self, forKey: .memory) ?? MemorySettings()
        loreTokenBudget = try c.decodeIfPresent(Int.self, forKey: .loreTokenBudget) ?? 900
        includeExampleDialogue = try c.decodeIfPresent(Bool.self, forKey: .includeExampleDialogue) ?? true
        suggestions = try c.decodeIfPresent(SuggestionSettings.self, forKey: .suggestions) ?? SuggestionSettings()
    }
}
