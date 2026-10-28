import Foundation

/// 世界书（Lorebook / World Info）。
public struct Lorebook: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var description: String
    /// 关键词扫描最近多少条消息。
    public var scanDepth: Int
    /// 世界书内容在提示词里最多占多少 token。0 表示使用全局默认值。
    public var tokenBudget: Int
    /// 是否允许已激活条目的内容继续触发其他条目。
    public var recursiveScanning: Bool
    public var maxRecursionSteps: Int
    public var entries: [LoreEntry]
    public var extensions: [String: JSONValue]
    public var isSample: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        scanDepth: Int = 4,
        tokenBudget: Int = 0,
        recursiveScanning: Bool = true,
        maxRecursionSteps: Int = 3,
        entries: [LoreEntry] = [],
        extensions: [String: JSONValue] = [:],
        isSample: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.scanDepth = scanDepth
        self.tokenBudget = tokenBudget
        self.recursiveScanning = recursiveScanning
        self.maxRecursionSteps = maxRecursionSteps
        self.entries = entries
        self.extensions = extensions
        self.isSample = isSample
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, scanDepth, tokenBudget, recursiveScanning, maxRecursionSteps, entries, extensions, isSample
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "世界书"
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        scanDepth = try c.decodeIfPresent(Int.self, forKey: .scanDepth) ?? 4
        tokenBudget = try c.decodeIfPresent(Int.self, forKey: .tokenBudget) ?? 0
        recursiveScanning = try c.decodeIfPresent(Bool.self, forKey: .recursiveScanning) ?? true
        maxRecursionSteps = try c.decodeIfPresent(Int.self, forKey: .maxRecursionSteps) ?? 3
        entries = try c.decodeIfPresent([LoreEntry].self, forKey: .entries) ?? []
        extensions = try c.decodeIfPresent([String: JSONValue].self, forKey: .extensions) ?? [:]
        isSample = try c.decodeIfPresent(Bool.self, forKey: .isSample) ?? false
    }
}

/// 条目在提示词里的位置。
public enum LorePosition: String, Codable, CaseIterable, Sendable {
    /// 角色设定之前（常放世界观）。
    case beforeCharacter
    /// 角色设定之后（常放地点、关系）。
    case afterCharacter
    /// 插入到聊天记录中、距离末尾 depth 条消息的位置。离生成点越近，模型越重视。
    case atDepth
}

/// 次要关键词的组合逻辑，与 SillyTavern 的 selectiveLogic 对应。
public enum SelectiveLogic: Int, Codable, CaseIterable, Sendable {
    /// 任意一个次要关键词命中
    case andAny = 0
    /// 次要关键词没有全部命中
    case notAll = 1
    /// 次要关键词一个都没命中
    case notAny = 2
    /// 次要关键词全部命中
    case andAll = 3
}

/// 用于界面分类，也会作为提示词里的小标题。
public enum LoreCategory: String, Codable, CaseIterable, Sendable {
    case world = "世界观"
    case location = "地点"
    case relationship = "角色关系"
    case faction = "势力"
    case item = "物品"
    case event = "事件"
    case other = "其他"
}

/// 剧情状态条件：只有满足时条目才可能激活。
public struct StateCondition: Codable, Hashable, Sendable {
    public enum Operator: String, Codable, CaseIterable, Sendable {
        case equals, notEquals, exists, notExists, greaterOrEqual, lessOrEqual
    }

    public var key: String
    public var op: Operator
    public var value: String

    public init(key: String, op: Operator, value: String = "") {
        self.key = key
        self.op = op
        self.value = value
    }

    public func isSatisfied(by state: [String: String]) -> Bool {
        let current = state[key]
        switch op {
        case .exists: return current != nil && current?.isEmpty == false
        case .notExists: return current == nil || current?.isEmpty == true
        case .equals: return current == value
        case .notEquals: return current != value
        case .greaterOrEqual:
            guard let a = current.flatMap(Double.init), let b = Double(value) else { return false }
            return a >= b
        case .lessOrEqual:
            guard let a = current.flatMap(Double.init), let b = Double(value) else { return false }
            return a <= b
        }
    }
}

public struct LoreEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// SillyTavern 的整数 uid，导入导出时保留。
    public var uid: Int
    public var comment: String
    public var category: LoreCategory
    public var keys: [String]
    public var secondaryKeys: [String]
    public var selective: Bool
    public var selectiveLogic: SelectiveLogic
    public var content: String
    public var enabled: Bool
    /// 常驻：不需要关键词，始终注入。
    public var constant: Bool
    public var caseSensitive: Bool
    public var matchWholeWords: Bool
    /// 插入顺序：同一位置内按升序排列，数值大的更靠后（更接近生成点）。
    public var insertionOrder: Int
    /// 预算不够时的保留优先级：数值越大越先保留。
    public var priority: Int
    public var position: LorePosition
    public var depth: Int
    /// 激活概率（0...100）。
    public var probability: Int
    /// 同组条目只保留一个（优先级最高者）。
    public var group: String
    public var excludeRecursion: Bool
    public var preventRecursion: Bool
    /// 激活后持续生效的回合数。
    public var sticky: Int
    /// 失效后冷却的回合数。
    public var cooldown: Int
    /// 对话至少有这么多条消息后才允许激活。
    public var delay: Int
    /// 覆盖世界书的扫描深度。
    public var scanDepth: Int?
    /// 只对这些角色名生效（群聊时用于角色私有设定）。为空表示全部。
    public var characterFilter: [String]
    public var characterFilterExclude: Bool
    /// 剧情状态条件。全部满足才可能激活。
    public var conditions: [StateCondition]
    public var extensions: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        uid: Int = 0,
        comment: String = "",
        category: LoreCategory = .other,
        keys: [String] = [],
        secondaryKeys: [String] = [],
        selective: Bool = false,
        selectiveLogic: SelectiveLogic = .andAny,
        content: String = "",
        enabled: Bool = true,
        constant: Bool = false,
        caseSensitive: Bool = false,
        matchWholeWords: Bool = false,
        insertionOrder: Int = 100,
        priority: Int = 10,
        position: LorePosition = .afterCharacter,
        depth: Int = 4,
        probability: Int = 100,
        group: String = "",
        excludeRecursion: Bool = false,
        preventRecursion: Bool = false,
        sticky: Int = 0,
        cooldown: Int = 0,
        delay: Int = 0,
        scanDepth: Int? = nil,
        characterFilter: [String] = [],
        characterFilterExclude: Bool = false,
        conditions: [StateCondition] = [],
        extensions: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.uid = uid
        self.comment = comment
        self.category = category
        self.keys = keys
        self.secondaryKeys = secondaryKeys
        self.selective = selective
        self.selectiveLogic = selectiveLogic
        self.content = content
        self.enabled = enabled
        self.constant = constant
        self.caseSensitive = caseSensitive
        self.matchWholeWords = matchWholeWords
        self.insertionOrder = insertionOrder
        self.priority = priority
        self.position = position
        self.depth = depth
        self.probability = probability
        self.group = group
        self.excludeRecursion = excludeRecursion
        self.preventRecursion = preventRecursion
        self.sticky = sticky
        self.cooldown = cooldown
        self.delay = delay
        self.scanDepth = scanDepth
        self.characterFilter = characterFilter
        self.characterFilterExclude = characterFilterExclude
        self.conditions = conditions
        self.extensions = extensions
    }

    public var title: String {
        if !comment.isEmpty { return comment }
        if let first = keys.first { return first }
        return "未命名条目"
    }

    enum CodingKeys: String, CodingKey {
        case id, uid, comment, category, keys, secondaryKeys, selective, selectiveLogic, content, enabled, constant
        case caseSensitive, matchWholeWords, insertionOrder, priority, position, depth, probability, group
        case excludeRecursion, preventRecursion, sticky, cooldown, delay, scanDepth, characterFilter
        case characterFilterExclude, conditions, extensions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        uid = try c.decodeIfPresent(Int.self, forKey: .uid) ?? 0
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        category = try c.decodeIfPresent(LoreCategory.self, forKey: .category) ?? .other
        keys = try c.decodeIfPresent([String].self, forKey: .keys) ?? []
        secondaryKeys = try c.decodeIfPresent([String].self, forKey: .secondaryKeys) ?? []
        selective = try c.decodeIfPresent(Bool.self, forKey: .selective) ?? false
        selectiveLogic = try c.decodeIfPresent(SelectiveLogic.self, forKey: .selectiveLogic) ?? .andAny
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        constant = try c.decodeIfPresent(Bool.self, forKey: .constant) ?? false
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        matchWholeWords = try c.decodeIfPresent(Bool.self, forKey: .matchWholeWords) ?? false
        insertionOrder = try c.decodeIfPresent(Int.self, forKey: .insertionOrder) ?? 100
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 10
        position = try c.decodeIfPresent(LorePosition.self, forKey: .position) ?? .afterCharacter
        depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 4
        probability = try c.decodeIfPresent(Int.self, forKey: .probability) ?? 100
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        excludeRecursion = try c.decodeIfPresent(Bool.self, forKey: .excludeRecursion) ?? false
        preventRecursion = try c.decodeIfPresent(Bool.self, forKey: .preventRecursion) ?? false
        sticky = try c.decodeIfPresent(Int.self, forKey: .sticky) ?? 0
        cooldown = try c.decodeIfPresent(Int.self, forKey: .cooldown) ?? 0
        delay = try c.decodeIfPresent(Int.self, forKey: .delay) ?? 0
        scanDepth = try c.decodeIfPresent(Int.self, forKey: .scanDepth)
        characterFilter = try c.decodeIfPresent([String].self, forKey: .characterFilter) ?? []
        characterFilterExclude = try c.decodeIfPresent(Bool.self, forKey: .characterFilterExclude) ?? false
        conditions = try c.decodeIfPresent([StateCondition].self, forKey: .conditions) ?? []
        extensions = try c.decodeIfPresent([String: JSONValue].self, forKey: .extensions) ?? [:]
    }
}

/// 每个聊天存档里世界书的运行时状态（粘滞、冷却），保证跨回合一致。
public struct LorebookRuntimeState: Codable, Hashable, Sendable {
    /// 条目 id → 粘滞剩余回合
    public var stickyRemaining: [UUID: Int]
    /// 条目 id → 冷却剩余回合
    public var cooldownRemaining: [UUID: Int]

    public init(stickyRemaining: [UUID: Int] = [:], cooldownRemaining: [UUID: Int] = [:]) {
        self.stickyRemaining = stickyRemaining
        self.cooldownRemaining = cooldownRemaining
    }
}
