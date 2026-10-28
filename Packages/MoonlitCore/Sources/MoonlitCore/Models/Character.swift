import Foundation

/// 一张角色卡在应用内部的形态。
/// 字段覆盖 TavernCharacter Card V2/V3 的全部标准字段，另加「背景」「说话风格」两个本应用字段；
/// 不认识的扩展字段放在 `extensions` 里原样保留，导出时写回。
public struct TavernCharacter: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var nickname: String
    /// 头像文件名（位于数据目录 avatars/ 下）。为空表示没有头像。
    public var avatarFileName: String?

    /// 人物简介 / 核心设定，对应 V2 的 `description`。
    public var description: String
    public var personality: String
    /// 背景故事。V2 没有独立字段，导出时合并进 description，并在扩展字段里单独保存。
    public var background: String
    /// 说话风格。处理方式同上。
    public var speakingStyle: String
    public var scenario: String
    public var firstMessage: String
    public var alternateGreetings: [String]
    public var exampleDialogue: String
    public var systemPrompt: String
    public var postHistoryInstructions: String

    public var creatorNotes: String
    public var creator: String
    public var characterVersion: String
    public var tags: [String]

    /// 角色自带的世界书（V2 `character_book`）。
    public var characterBook: Lorebook?

    /// 群聊里的发言积极度，0...1，兼容 SillyTavern 的 `extensions.talkativeness`。
    public var talkativeness: Double

    /// 卡片扩展字段原样保留（不含本应用写入的 `moonlit` 键）。
    public var extensions: [String: JSONValue]

    public var createdAt: Date
    public var updatedAt: Date
    /// 是否为内置演示数据。界面上会明确标注「示例」。
    public var isSample: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        nickname: String = "",
        avatarFileName: String? = nil,
        description: String = "",
        personality: String = "",
        background: String = "",
        speakingStyle: String = "",
        scenario: String = "",
        firstMessage: String = "",
        alternateGreetings: [String] = [],
        exampleDialogue: String = "",
        systemPrompt: String = "",
        postHistoryInstructions: String = "",
        creatorNotes: String = "",
        creator: String = "",
        characterVersion: String = "",
        tags: [String] = [],
        characterBook: Lorebook? = nil,
        talkativeness: Double = 0.5,
        extensions: [String: JSONValue] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isSample: Bool = false
    ) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.avatarFileName = avatarFileName
        self.description = description
        self.personality = personality
        self.background = background
        self.speakingStyle = speakingStyle
        self.scenario = scenario
        self.firstMessage = firstMessage
        self.alternateGreetings = alternateGreetings
        self.exampleDialogue = exampleDialogue
        self.systemPrompt = systemPrompt
        self.postHistoryInstructions = postHistoryInstructions
        self.creatorNotes = creatorNotes
        self.creator = creator
        self.characterVersion = characterVersion
        self.tags = tags
        self.characterBook = characterBook
        self.talkativeness = talkativeness
        self.extensions = extensions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isSample = isSample
    }

    /// 界面上显示的名字。
    public var displayName: String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : nickname
    }

    /// 所有可选开场白（第一条是 firstMessage）。
    public var allGreetings: [String] {
        ([firstMessage] + alternateGreetings).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // 兼容旧数据：缺字段时给默认值。
    enum CodingKeys: String, CodingKey {
        case id, name, nickname, avatarFileName, description, personality, background, speakingStyle
        case scenario, firstMessage, alternateGreetings, exampleDialogue, systemPrompt, postHistoryInstructions
        case creatorNotes, creator, characterVersion, tags, characterBook, talkativeness, extensions
        case createdAt, updatedAt, isSample
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名角色"
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        avatarFileName = try c.decodeIfPresent(String.self, forKey: .avatarFileName)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        personality = try c.decodeIfPresent(String.self, forKey: .personality) ?? ""
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? ""
        speakingStyle = try c.decodeIfPresent(String.self, forKey: .speakingStyle) ?? ""
        scenario = try c.decodeIfPresent(String.self, forKey: .scenario) ?? ""
        firstMessage = try c.decodeIfPresent(String.self, forKey: .firstMessage) ?? ""
        alternateGreetings = try c.decodeIfPresent([String].self, forKey: .alternateGreetings) ?? []
        exampleDialogue = try c.decodeIfPresent(String.self, forKey: .exampleDialogue) ?? ""
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        postHistoryInstructions = try c.decodeIfPresent(String.self, forKey: .postHistoryInstructions) ?? ""
        creatorNotes = try c.decodeIfPresent(String.self, forKey: .creatorNotes) ?? ""
        creator = try c.decodeIfPresent(String.self, forKey: .creator) ?? ""
        characterVersion = try c.decodeIfPresent(String.self, forKey: .characterVersion) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        characterBook = try c.decodeIfPresent(Lorebook.self, forKey: .characterBook)
        talkativeness = try c.decodeIfPresent(Double.self, forKey: .talkativeness) ?? 0.5
        extensions = try c.decodeIfPresent([String: JSONValue].self, forKey: .extensions) ?? [:]
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        isSample = try c.decodeIfPresent(Bool.self, forKey: .isSample) ?? false
    }
}

/// 用户在故事里的身份（SillyTavern 里叫 Persona）。
public struct UserPersona: Codable, Hashable, Sendable {
    public var name: String
    public var description: String

    public init(name: String = "旅人", description: String = "") {
        self.name = name
        self.description = description
    }
}
