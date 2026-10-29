import Foundation

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    /// 旁白 / 系统消息，例如场景切换说明。
    case system
}

/// 一次生成的统计数据，全部来自真实计时，不做估算。
public struct GenerationStats: Codable, Hashable, Sendable {
    public var engine: String
    public var modelName: String
    public var promptTokens: Int
    /// 本次真正参与计算的提示词 token 数（命中缓存的部分不算）。
    public var promptTokensEvaluated: Int
    public var generatedTokens: Int
    /// 首 token 延迟（秒）：从开始处理提示词到第一个 token 产生。
    public var timeToFirstToken: Double
    public var promptSeconds: Double
    public var generationSeconds: Double
    public var contextLength: Int
    public var stopReason: String
    public var peakMemoryMB: Double?

    public init(
        engine: String,
        modelName: String,
        promptTokens: Int = 0,
        promptTokensEvaluated: Int = 0,
        generatedTokens: Int = 0,
        timeToFirstToken: Double = 0,
        promptSeconds: Double = 0,
        generationSeconds: Double = 0,
        contextLength: Int = 0,
        stopReason: String = "",
        peakMemoryMB: Double? = nil
    ) {
        self.engine = engine
        self.modelName = modelName
        self.promptTokens = promptTokens
        self.promptTokensEvaluated = promptTokensEvaluated
        self.generatedTokens = generatedTokens
        self.timeToFirstToken = timeToFirstToken
        self.promptSeconds = promptSeconds
        self.generationSeconds = generationSeconds
        self.contextLength = contextLength
        self.stopReason = stopReason
        self.peakMemoryMB = peakMemoryMB
    }

    public var promptTokensPerSecond: Double {
        promptSeconds > 0 ? Double(promptTokensEvaluated) / promptSeconds : 0
    }

    public var generationTokensPerSecond: Double {
        generationSeconds > 0 ? Double(generatedTokens) / generationSeconds : 0
    }
}

public struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// 父消息。为空表示根消息。消息组成一棵树，用来支持重新生成和分支剧情。
    public var parentID: UUID?
    public var role: MessageRole
    /// 发言角色的 id（assistant 消息）。用户消息为空。
    public var speakerID: UUID?
    public var speakerName: String
    public var content: String
    public var createdAt: Date
    public var editedAt: Date?
    /// 隐藏后不进入提示词，但保留在记录里。
    public var isHidden: Bool
    public var stats: GenerationStats?
    /// 这条角色回复之后给用户的剧情选项。刷新选项只改这里，不动回复正文。
    public var suggestions: [String]?

    public init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        role: MessageRole,
        speakerID: UUID? = nil,
        speakerName: String,
        content: String,
        createdAt: Date = Date(),
        editedAt: Date? = nil,
        isHidden: Bool = false,
        stats: GenerationStats? = nil,
        suggestions: [String]? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.role = role
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.content = content
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.isHidden = isHidden
        self.stats = stats
        self.suggestions = suggestions
    }
}

/// 群聊发言顺序策略。
public enum TurnOrderStrategy: String, Codable, CaseIterable, Sendable {
    /// 优先让刚被点名的角色发言，否则轮流。
    case natural
    /// 严格轮流。
    case roundRobin
    /// 按积极度随机。
    case weightedRandom
    /// 每次由用户指定。
    case manual
}

public struct AuthorsNote: Codable, Hashable, Sendable {
    public var text: String
    public var depth: Int
    public var enabled: Bool

    public init(text: String = "", depth: Int = 3, enabled: Bool = false) {
        self.text = text
        self.depth = depth
        self.enabled = enabled
    }
}

/// 一个聊天存档。一个角色可以有多个存档；一个存档可以有多个角色（群聊）。
public struct ChatSession: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var characterIDs: [UUID]
    public var messages: [ChatMessage]
    public var activeLeafID: UUID?
    public var lorebookIDs: [UUID]
    public var authorsNote: AuthorsNote
    public var turnOrder: TurnOrderStrategy
    /// 剧情状态，例如「章节=第二章」「好感度=3」。可用于世界书条件触发，也会注入提示词。
    public var plotState: [String: String]
    public var loreState: LorebookRuntimeState
    /// 历史截断锚点：提示词从活动路径的第几条消息开始。保持稳定能复用 KV 缓存。
    public var historyAnchor: Int
    public var persona: UserPersona?
    public var createdAt: Date
    public var updatedAt: Date
    public var isSample: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        characterIDs: [UUID],
        messages: [ChatMessage] = [],
        activeLeafID: UUID? = nil,
        lorebookIDs: [UUID] = [],
        authorsNote: AuthorsNote = AuthorsNote(),
        turnOrder: TurnOrderStrategy = .natural,
        plotState: [String: String] = [:],
        loreState: LorebookRuntimeState = LorebookRuntimeState(),
        historyAnchor: Int = 0,
        persona: UserPersona? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isSample: Bool = false
    ) {
        self.id = id
        self.title = title
        self.characterIDs = characterIDs
        self.messages = messages
        self.activeLeafID = activeLeafID
        self.lorebookIDs = lorebookIDs
        self.authorsNote = authorsNote
        self.turnOrder = turnOrder
        self.plotState = plotState
        self.loreState = loreState
        self.historyAnchor = historyAnchor
        self.persona = persona
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isSample = isSample
    }

    public var isGroup: Bool { characterIDs.count > 1 }

    enum CodingKeys: String, CodingKey {
        case id, title, characterIDs, messages, activeLeafID, lorebookIDs, authorsNote, turnOrder
        case plotState, loreState, historyAnchor, persona, createdAt, updatedAt, isSample
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "存档"
        characterIDs = try c.decodeIfPresent([UUID].self, forKey: .characterIDs) ?? []
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        activeLeafID = try c.decodeIfPresent(UUID.self, forKey: .activeLeafID)
        lorebookIDs = try c.decodeIfPresent([UUID].self, forKey: .lorebookIDs) ?? []
        authorsNote = try c.decodeIfPresent(AuthorsNote.self, forKey: .authorsNote) ?? AuthorsNote()
        turnOrder = try c.decodeIfPresent(TurnOrderStrategy.self, forKey: .turnOrder) ?? .natural
        plotState = try c.decodeIfPresent([String: String].self, forKey: .plotState) ?? [:]
        loreState = try c.decodeIfPresent(LorebookRuntimeState.self, forKey: .loreState) ?? LorebookRuntimeState()
        historyAnchor = try c.decodeIfPresent(Int.self, forKey: .historyAnchor) ?? 0
        persona = try c.decodeIfPresent(UserPersona.self, forKey: .persona)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        isSample = try c.decodeIfPresent(Bool.self, forKey: .isSample) ?? false
    }
}
