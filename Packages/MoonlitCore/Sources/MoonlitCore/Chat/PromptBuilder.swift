import Foundation

/// 每一部分在提示词里占了多少 token，界面上用来展示「上下文用量」。
public struct PromptReport: Sendable {
    public var contextLength: Int = 0
    public var reservedForReply: Int = 0
    public var systemTokens: Int = 0
    public var loreTokens: Int = 0
    public var memoryTokens: Int = 0
    public var exampleTokens: Int = 0
    public var historyTokens: Int = 0
    public var injectionTokens: Int = 0
    public var includedHistoryCount: Int = 0
    /// 因为放不下而没进入提示词的早期消息数量（这些内容由长期记忆接替）。
    public var truncatedHistoryCount: Int = 0
    public var exampleBlocksIncluded: Int = 0
    public var exampleBlocksTotal: Int = 0
    public var includedMemoryIDs: [UUID] = []
    /// 固定部分已经超出可用空间。
    public var overflow: Bool = false

    public var totalTokens: Int {
        systemTokens + loreTokens + memoryTokens + exampleTokens + historyTokens + injectionTokens
    }
}

public struct PromptPlan: Sendable {
    public var messages: [PromptMessage]
    /// 助手回复的开头（群聊时为「角色名：」）。
    public var prefill: String
    /// 角色扮演层面的停止词：其他角色或用户的名字前缀，防止模型替别人说话。
    public var stopSequences: [String]
    public var report: PromptReport
    public var lore: LorebookEngine.Result
    /// 新的历史锚点，生成成功后写回存档。
    public var historyAnchor: Int
    /// 掉出窗口、尚未被摘要覆盖的消息，用于触发自动摘要。
    public var truncatedMessages: [ChatMessage]
    /// messages 末尾跟在聊天历史后面的指令条数（历史后指令、群聊发言提示）
    public var tailCount: Int = 0
}

public struct PromptContext {
    public var characters: [TavernCharacter]
    public var speaker: TavernCharacter
    public var persona: UserPersona
    public var settings: AppSettings
    public var session: ChatSession
    public var lorebooks: [Lorebook]
    public var memory: ChatMemory?
    public var contextLength: Int
    public var maxNewTokens: Int
    public var tokenCounter: TokenCounter
    public var roll: (LoreEntry) -> Int
    /// 模板开销估算（每条消息的起止标记）。
    public var perMessageOverhead: Int

    public init(
        characters: [TavernCharacter],
        speaker: TavernCharacter,
        persona: UserPersona,
        settings: AppSettings,
        session: ChatSession,
        lorebooks: [Lorebook],
        memory: ChatMemory?,
        contextLength: Int,
        maxNewTokens: Int,
        tokenCounter: TokenCounter = HeuristicTokenCounter(),
        roll: @escaping (LoreEntry) -> Int = { _ in Int.random(in: 0..<100) },
        perMessageOverhead: Int = 6
    ) {
        self.characters = characters
        self.speaker = speaker
        self.persona = persona
        self.settings = settings
        self.session = session
        self.lorebooks = lorebooks
        self.memory = memory
        self.contextLength = contextLength
        self.maxNewTokens = maxNewTokens
        self.tokenCounter = tokenCounter
        self.roll = roll
        self.perMessageOverhead = perMessageOverhead
    }
}

/// 组装角色扮演提示词。
///
/// 拼接顺序（system 消息内）：
///   系统提示词 → 世界书「角色前」 → 角色设定（群聊时为全部角色，当前发言者在前）
///   → 世界书「角色后」 → 用户身份 → 剧情状态 → 长期记忆 → 示例对话
/// 之后是聊天历史；「深度注入」（世界书 atDepth、作者注释、角色深度提示）按深度插入历史中；
/// 最后是角色的 post_history_instructions 和群聊发言提示。
///
/// 预算分配：先扣掉回复长度，固定部分必须放入；世界书和记忆有各自上限；
/// 剩余空间给历史（从新到旧）；再有剩余才放示例对话。
public struct PromptBuilder {
    public init() {}

    public func build(_ ctx: PromptContext) -> PromptPlan {
        let counter = ctx.tokenCounter
        let overhead = ctx.perMessageOverhead
        var report = PromptReport()
        report.contextLength = ctx.contextLength
        report.reservedForReply = ctx.maxNewTokens

        let isGroup = ctx.characters.count > 1
        let speaker = ctx.speaker
        let macro = MacroContext(
            characterName: speaker.name,
            userName: ctx.persona.name,
            originalSystemPrompt: MacroContext(characterName: speaker.name, userName: ctx.persona.name)
                .expand(ctx.settings.defaultSystemPrompt),
            groupNames: ctx.characters.map(\.name)
        )

        let path = ctx.session.activePath().filter { !$0.isHidden }
        let available = max(ctx.contextLength - ctx.maxNewTokens - 16, 256)

        // ---------- 世界书 ----------
        let scanTexts = path.map { "\($0.speakerName): \($0.content)" }
        let loreBudget = min(ctx.settings.loreTokenBudget, available * 3 / 10)
        let lore = LorebookEngine().evaluate(.init(
            books: ctx.lorebooks,
            recentMessages: scanTexts,
            activeCharacterName: speaker.name,
            plotState: ctx.session.plotState,
            messageCount: path.count,
            state: ctx.session.loreState,
            tokenBudget: loreBudget,
            tokenCounter: counter,
            roll: ctx.roll
        ))
        report.loreTokens = lore.tokensUsed

        // ---------- 固定的 system 部分 ----------
        var systemSections: [String] = []
        let basePrompt = speaker.systemPrompt.isBlank ? ctx.settings.defaultSystemPrompt : speaker.systemPrompt
        systemSections.append(macro.expand(basePrompt).trimmed)

        let loreBefore = lore.entries(at: .beforeCharacter).map { macro.expand($0.entry.content).trimmed }
        if !loreBefore.isEmpty {
            systemSections.append("【世界设定】\n" + loreBefore.joined(separator: "\n"))
        }

        let ordered = [speaker] + ctx.characters.filter { $0.id != speaker.id }
        for character in ordered {
            let m = MacroContext(characterName: character.name, userName: ctx.persona.name)
            systemSections.append(characterBlock(character, macro: m, isGroup: isGroup, isSpeaker: character.id == speaker.id))
        }

        let loreAfter = lore.entries(at: .afterCharacter).map { macro.expand($0.entry.content).trimmed }
        if !loreAfter.isEmpty {
            systemSections.append("【相关设定】\n" + loreAfter.joined(separator: "\n"))
        }

        if !ctx.persona.description.isBlank {
            systemSections.append("【\(ctx.persona.name)（用户）】\n" + macro.expand(ctx.persona.description).trimmed)
        }

        if !ctx.session.plotState.isEmpty {
            let lines = ctx.session.plotState.sorted { $0.key < $1.key }.map { "\($0.key)：\($0.value)" }
            systemSections.append("【剧情状态】\n" + lines.joined(separator: "\n"))
        }

        var systemCore = systemSections.joined(separator: "\n\n")
        var fixedTokens = counter.count(systemCore) + overhead
        report.systemTokens = fixedTokens - lore.tokensUsed

        // post-history 与群聊发言提示
        var tailMessages: [PromptMessage] = []
        if !speaker.postHistoryInstructions.isBlank {
            tailMessages.append(PromptMessage(role: .system, content: macro.expand(speaker.postHistoryInstructions).trimmed))
        }
        if isGroup {
            let others = ctx.characters.filter { $0.id != speaker.id }.map(\.name) + [ctx.persona.name]
            tailMessages.append(PromptMessage(
                role: .system,
                content: "现在轮到\(speaker.name)发言。只写\(speaker.name)的台词、动作和心理，不要替\(others.joined(separator: "、"))说话或行动。"
            ))
        }
        let tailTokens = tailMessages.reduce(0) { $0 + counter.count($1.content) + overhead }
        fixedTokens += tailTokens
        report.systemTokens += tailTokens

        // ---------- 长期记忆 ----------
        var memoryText = ""
        if let memory = ctx.memory {
            let query = path.suffix(6).map(\.content).joined(separator: "\n")
            let selection = MemoryRetriever().select(
                from: memory,
                query: query,
                tokenBudget: min(ctx.settings.memory.tokenBudget, available / 5),
                maxRetrieved: ctx.settings.memory.maxRetrieved,
                tokenCounter: counter
            )
            if !selection.items.isEmpty {
                memoryText = MemoryRetriever.render(selection.items)
                report.memoryTokens = counter.count(memoryText)
                report.includedMemoryIDs = selection.items.map(\.id)
            }
        }

        // ---------- 深度注入 ----------
        var injections: [(depth: Int, message: PromptMessage)] = []
        for item in lore.entries(at: .atDepth) {
            injections.append((item.entry.depth, PromptMessage(role: .system, content: macro.expand(item.entry.content).trimmed)))
        }
        if ctx.session.authorsNote.enabled, !ctx.session.authorsNote.text.isBlank {
            injections.append((ctx.session.authorsNote.depth,
                               PromptMessage(role: .system, content: "[作者注释：\(macro.expand(ctx.session.authorsNote.text).trimmed)]")))
        }
        if let depthPrompt = speaker.extensions["depth_prompt"]?.objectValue,
           let text = depthPrompt.string("prompt"), !text.isBlank {
            injections.append((depthPrompt.int("depth") ?? 4, PromptMessage(role: .system, content: macro.expand(text).trimmed)))
        }
        let injectionTokens = injections.reduce(0) { $0 + counter.count($1.message.content) + overhead }
        report.injectionTokens = injectionTokens

        // ---------- 历史 ----------
        let memoryCost = memoryText.isEmpty ? 0 : report.memoryTokens + 2
        let historyBudget = available - fixedTokens - memoryCost - injectionTokens
        if historyBudget <= 0 { report.overflow = true }

        let messageCosts = path.map { counter.count(renderContent($0, isGroup: isGroup)) + overhead }
        let anchor = HistoryWindow.chooseStart(
            costs: messageCosts,
            budget: max(historyBudget, 0),
            previousAnchor: ctx.session.historyAnchor
        )
        let included = Array(path[anchor...])
        report.includedHistoryCount = included.count
        report.truncatedHistoryCount = anchor
        report.historyTokens = messageCosts[anchor...].reduce(0, +)

        // ---------- 示例对话：用剩余空间 ----------
        var leftover = historyBudget - report.historyTokens
        var exampleText = ""
        if ctx.settings.includeExampleDialogue {
            let blocks = ExampleDialogue.blocks(from: ordered.map { c -> String in
                let m = MacroContext(characterName: c.name, userName: ctx.persona.name)
                return m.expand(c.exampleDialogue)
            }.joined(separator: "\n<START>\n"))
            report.exampleBlocksTotal = blocks.count
            var chosen: [String] = []
            for block in blocks {
                let cost = counter.count(block) + 2
                if cost > leftover { break }
                leftover -= cost
                chosen.append(block)
            }
            if !chosen.isEmpty {
                exampleText = "【示例对话（仅示范语气和格式，并非已发生的剧情）】\n" + chosen.joined(separator: "\n---\n")
                report.exampleBlocksIncluded = chosen.count
                report.exampleTokens = counter.count(exampleText)
            }
        }

        if !memoryText.isEmpty { systemCore += "\n\n" + memoryText }
        if !exampleText.isEmpty { systemCore += "\n\n" + exampleText }

        // ---------- 拼装 ----------
        var historyMessages = included.map { PromptMessage(role: $0.role, content: renderContent($0, isGroup: isGroup)) }
        // 深度注入：depth 0 = 最后一条之后
        for (depth, message) in injections.sorted(by: { $0.depth > $1.depth }) {
            let position = max(0, historyMessages.count - max(depth, 0))
            historyMessages.insert(message, at: position)
        }

        var messages = [PromptMessage(role: .system, content: systemCore)]
        messages += historyMessages
        messages += tailMessages

        let prefill = isGroup ? "\(speaker.name)：" : ""
        var stops: [String] = ["\n\(ctx.persona.name):", "\n\(ctx.persona.name)："]
        for other in ctx.characters where other.id != speaker.id {
            stops.append("\n\(other.name):")
            stops.append("\n\(other.name)：")
        }

        // 掉出窗口、尚未摘要的消息
        let summarized = ctx.memory?.summarizedMessageIDs ?? []
        let truncated = path[..<anchor].filter { !summarized.contains($0.id) }

        return PromptPlan(
            messages: messages,
            prefill: prefill,
            stopSequences: stops,
            report: report,
            lore: lore,
            historyAnchor: anchor,
            truncatedMessages: Array(truncated),
            tailCount: tailMessages.count
        )
    }

    /// 历史消息写进提示词的文本。群聊时加名字前缀，让模型分清是谁说的。
    func renderContent(_ m: ChatMessage, isGroup: Bool) -> String {
        switch m.role {
        case .system:
            return m.content
        case .user, .assistant:
            return isGroup ? "\(m.speakerName)：\(m.content)" : m.content
        }
    }

    func characterBlock(_ c: TavernCharacter, macro: MacroContext, isGroup: Bool, isSpeaker: Bool) -> String {
        var lines: [String] = []
        let header = isGroup ? "【角色：\(c.name)】" : "【\(c.name)的设定】"
        lines.append(header)
        if !c.description.isBlank { lines.append(macro.expand(c.description).trimmed) }
        if !c.personality.isBlank { lines.append("性格：" + macro.expand(c.personality).trimmed) }
        // 群聊中非发言角色只保留核心设定，省 token，也减少人设串台
        if !isGroup || isSpeaker {
            if !c.background.isBlank { lines.append("背景：" + macro.expand(c.background).trimmed) }
            if !c.speakingStyle.isBlank { lines.append("说话风格：" + macro.expand(c.speakingStyle).trimmed) }
        } else if !c.speakingStyle.isBlank {
            lines.append("说话风格：" + macro.expand(c.speakingStyle).trimmed)
        }
        if !c.scenario.isBlank && (!isGroup || isSpeaker) {
            lines.append("场景：" + macro.expand(c.scenario).trimmed)
        }
        return lines.joined(separator: "\n")
    }
}

/// 历史窗口选择。锚点尽量保持不动，这样提示词前缀不变，本地模型能复用 KV 缓存；
/// 只有放不下时才前移，并一次性留出 30% 余量，避免每轮都移动。
public enum HistoryWindow {
    public static func chooseStart(costs: [Int], budget: Int, previousAnchor: Int, headroom: Double = 0.7) -> Int {
        guard !costs.isEmpty else { return 0 }
        let total = costs.reduce(0, +)
        if total <= budget { return 0 }
        let anchor = min(max(previousAnchor, 0), costs.count - 1)
        if costs[anchor...].reduce(0, +) <= budget { return anchor }
        let target = Int(Double(budget) * headroom)
        var sum = 0
        var start = costs.count
        while start > 0 {
            let next = sum + costs[start - 1]
            if next > target { break }
            sum = next
            start -= 1
        }
        // 至少保留最后一条
        return min(start, costs.count - 1)
    }
}

/// 示例对话解析：按 <START> 分块。
public enum ExampleDialogue {
    public static func blocks(from text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized.components(separatedBy: "<START>")
        return parts.map { $0.trimmed }.filter { !$0.isEmpty }
    }
}
