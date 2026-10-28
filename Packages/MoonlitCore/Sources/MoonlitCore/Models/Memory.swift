import Foundation

public enum MemoryKind: String, Codable, CaseIterable, Sendable {
    /// 剧情摘要（按章节滚动生成）
    case summary = "摘要"
    /// 关键事件
    case event = "事件"
    /// 角色关系状态
    case relationship = "关系"
    /// 固定事实（例如「主角左手有伤」）
    case fact = "事实"
}

public enum MemorySource: String, Codable, Sendable {
    case automatic
    case manual
}

public struct MemoryItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: MemoryKind
    public var content: String
    /// 检索用关键词。为空时按内容自动抽取。
    public var keywords: [String]
    /// 1...5，越大越重要。
    public var importance: Int
    /// 关系类记忆的主体与对象，例如「艾琳」→「旅人」。
    public var subject: String
    public var object: String
    /// 常驻：每次都注入，不参与检索排序。
    public var pinned: Bool
    public var enabled: Bool
    public var source: MemorySource
    /// 这条记忆覆盖到第几条消息（活动路径上的序号），用于排序和显示。
    public var messageIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: MemoryKind,
        content: String,
        keywords: [String] = [],
        importance: Int = 3,
        subject: String = "",
        object: String = "",
        pinned: Bool = false,
        enabled: Bool = true,
        source: MemorySource = .manual,
        messageIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.keywords = keywords
        self.importance = importance
        self.subject = subject
        self.object = object
        self.pinned = pinned
        self.enabled = enabled
        self.source = source
        self.messageIndex = messageIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 写进提示词时的文本。
    public var promptLine: String {
        switch kind {
        case .relationship where !subject.isEmpty && !object.isEmpty:
            return "\(subject)→\(object)：\(content)"
        default:
            return content
        }
    }
}

/// 一个聊天存档的长期记忆。
public struct ChatMemory: Codable, Hashable, Sendable {
    public var chatID: UUID
    public var items: [MemoryItem]
    /// 已经被摘要覆盖的消息 id（活动路径上）。
    public var summarizedMessageIDs: Set<UUID>

    public init(chatID: UUID, items: [MemoryItem] = [], summarizedMessageIDs: Set<UUID> = []) {
        self.chatID = chatID
        self.items = items
        self.summarizedMessageIDs = summarizedMessageIDs
    }

    public var summaries: [MemoryItem] { items.filter { $0.kind == .summary } }
}
