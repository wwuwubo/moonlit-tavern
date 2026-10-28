import XCTest
@testable import MoonlitCore

final class PromptBuilderTests: XCTestCase {
    private func context(
        session: ChatSession,
        characters: [TavernCharacter],
        speaker: TavernCharacter,
        lorebooks: [Lorebook] = [],
        memory: ChatMemory? = nil,
        contextLength: Int = 4096,
        maxNew: Int = 200,
        settings: AppSettings = AppSettings()
    ) -> PromptContext {
        PromptContext(
            characters: characters, speaker: speaker, persona: UserPersona(name: "旅人", description: "一个迷路的商人"),
            settings: settings, session: session, lorebooks: lorebooks, memory: memory,
            contextLength: contextLength, maxNewTokens: maxNew, tokenCounter: CharCounter(), roll: { _ in 0 }
        )
    }

    private var erin: TavernCharacter {
        var c = TavernCharacter(name: "艾琳")
        c.description = "{{char}}是酒馆老板娘，认识{{user}}很久了。"
        c.personality = "嘴硬心软"
        c.background = "前密探"
        c.speakingStyle = "简短"
        c.scenario = "深夜酒馆"
        c.exampleDialogue = "<START>\n{{user}}: 有房间吗\n{{char}}: 有。\n<START>\n{{user}}: 多少钱\n{{char}}: 看心情。"
        c.postHistoryInstructions = "保持{{char}}的口吻。"
        return c
    }

    func testSectionOrderAndMacros() {
        let c = erin
        let book = Lorebook(name: "世界", entries: [
            LoreEntry(comment: "前", content: "【前置世界观】", constant: true, position: .beforeCharacter),
            LoreEntry(comment: "后", keys: ["钟楼"], content: "【钟楼设定】", position: .afterCharacter)
        ])
        let session = chat(with: [(.assistant, "欢迎"), (.user, "钟楼怎么走？")], characterID: c.id)
        var memory = ChatMemory(chatID: session.id)
        memory.items = [MemoryItem(kind: .summary, content: "【旧摘要】", messageIndex: 1)]
        var settings = AppSettings()
        settings.defaultSystemPrompt = "你扮演{{char}}，对象是{{user}}。"
        let plan = PromptBuilder().build(context(session: session, characters: [c], speaker: c, lorebooks: [book], memory: memory, settings: settings))

        let system = plan.messages[0].content
        XCTAssertEqual(plan.messages[0].role, .system)
        XCTAssertTrue(system.hasPrefix("你扮演艾琳，对象是旅人。"))
        XCTAssertTrue(system.contains("艾琳是酒馆老板娘，认识旅人很久了。"), "宏应被替换")
        func pos(_ s: String) -> Int { system.range(of: s).map { system.distance(from: system.startIndex, to: $0.lowerBound) } ?? -1 }
        XCTAssertGreaterThan(pos("【前置世界观】"), 0)
        XCTAssertLessThan(pos("【前置世界观】"), pos("艾琳是酒馆老板娘"))
        XCTAssertLessThan(pos("艾琳是酒馆老板娘"), pos("【钟楼设定】"))
        XCTAssertLessThan(pos("【钟楼设定】"), pos("一个迷路的商人"))
        XCTAssertLessThan(pos("一个迷路的商人"), pos("【旧摘要】"))
        XCTAssertLessThan(pos("【旧摘要】"), pos("示例对话"))

        // 历史在中间，post-history 在最后
        XCTAssertEqual(plan.messages[1].content, "欢迎")
        XCTAssertEqual(plan.messages[2].content, "钟楼怎么走？")
        XCTAssertEqual(plan.messages.last?.content, "保持艾琳的口吻。")
        XCTAssertEqual(plan.prefill, "", "单人聊天不加名字预填")
        XCTAssertEqual(plan.report.exampleBlocksIncluded, 2)
    }

    func testCharacterSystemPromptWithOriginalMacro() {
        var c = erin
        c.systemPrompt = "{{original}}\n额外：用古风。"
        var settings = AppSettings()
        settings.defaultSystemPrompt = "基础提示，角色{{char}}"
        let session = chat(with: [(.user, "你好")], characterID: c.id)
        let plan = PromptBuilder().build(context(session: session, characters: [c], speaker: c, settings: settings))
        XCTAssertTrue(plan.messages[0].content.hasPrefix("基础提示，角色艾琳\n额外：用古风。"))
    }

    func testGroupChatIdentityIsolation() {
        let a = erin
        var b = TavernCharacter(name: "莱恩")
        b.description = "流浪骑士"
        b.background = "被除名的骑士"
        var session = ChatSession(title: "g", characterIDs: [a.id, b.id])
        session.append(ChatMessage(role: .assistant, speakerID: a.id, speakerName: "艾琳", content: "坐吧"))
        session.append(ChatMessage(role: .user, speakerName: "旅人", content: "莱恩你怎么看"))
        let plan = PromptBuilder().build(context(session: session, characters: [a, b], speaker: b))

        XCTAssertEqual(plan.prefill, "莱恩：")
        XCTAssertTrue(plan.messages.contains { $0.content == "艾琳：坐吧" }, "群聊历史带名字前缀")
        XCTAssertTrue(plan.messages.contains { $0.content == "旅人：莱恩你怎么看" })
        XCTAssertTrue(plan.stopSequences.contains("\n艾琳："))
        XCTAssertTrue(plan.stopSequences.contains("\n旅人："))
        XCTAssertFalse(plan.stopSequences.contains("\n莱恩："))
        let system = plan.messages[0].content
        XCTAssertTrue(system.contains("【角色：莱恩】"))
        XCTAssertTrue(system.contains("【角色：艾琳】"))
        XCTAssertLessThan(system.range(of: "【角色：莱恩】")!.lowerBound, system.range(of: "【角色：艾琳】")!.lowerBound,
                          "当前发言者的设定排在前面")
        XCTAssertTrue(system.contains("被除名的骑士"), "发言者的背景完整注入")
        XCTAssertFalse(system.contains("前密探"), "非发言角色的背景不注入，减少串台")
        XCTAssertTrue(plan.messages.last!.content.contains("现在轮到莱恩发言"))
    }

    func testHistoryTruncationAnchorIsStable() {
        let c = TavernCharacter(name: "A")
        var session = ChatSession(title: "t", characterIDs: [c.id])
        for i in 0..<40 {
            session.append(ChatMessage(role: i % 2 == 0 ? .user : .assistant, speakerID: i % 2 == 0 ? nil : c.id,
                                       speakerName: i % 2 == 0 ? "旅人" : "A", content: String(repeating: "字", count: 50)))
        }
        var settings = AppSettings()
        settings.defaultSystemPrompt = "S"
        settings.includeExampleDialogue = false
        let plan1 = PromptBuilder().build(context(session: session, characters: [c], speaker: c, contextLength: 1500, maxNew: 200, settings: settings))
        XCTAssertGreaterThan(plan1.historyAnchor, 0, "放不下时应截断")
        XCTAssertLessThanOrEqual(plan1.report.totalTokens, 1500 - 200)
        XCTAssertEqual(plan1.truncatedMessages.count, plan1.historyAnchor)

        // 再加两条后，锚点保持不变（前缀稳定，可复用 KV 缓存）
        session.historyAnchor = plan1.historyAnchor
        session.append(ChatMessage(role: .user, speakerName: "旅人", content: "新的一句"))
        session.append(ChatMessage(role: .assistant, speakerID: c.id, speakerName: "A", content: "新的回复"))
        let plan2 = PromptBuilder().build(context(session: session, characters: [c], speaker: c, contextLength: 1500, maxNew: 200, settings: settings))
        XCTAssertEqual(plan2.historyAnchor, plan1.historyAnchor)

        // 已被摘要的消息不再列入待摘要
        var memory = ChatMemory(chatID: session.id)
        memory.summarizedMessageIDs = Set(plan1.truncatedMessages.map(\.id))
        let plan3 = PromptBuilder().build(context(session: session, characters: [c], speaker: c, memory: memory, contextLength: 1500, maxNew: 200, settings: settings))
        XCTAssertTrue(plan3.truncatedMessages.isEmpty)
    }

    func testExamplesDroppedBeforeHistory() {
        var c = erin
        c.exampleDialogue = "<START>\n" + String(repeating: "例", count: 600)
        let session = chat(with: [(.user, String(repeating: "史", count: 300))], characterID: c.id)
        let plan = PromptBuilder().build(context(session: session, characters: [c], speaker: c, contextLength: 1100, maxNew: 100))
        XCTAssertEqual(plan.report.includedHistoryCount, 1)
        XCTAssertEqual(plan.report.exampleBlocksIncluded, 0)
        XCTAssertEqual(plan.report.exampleBlocksTotal, 1)
    }

    func testDepthInjectionsAndHiddenMessages() {
        let c = TavernCharacter(name: "A")
        var session = chat(with: [(.user, "m1"), (.assistant, "m2"), (.user, "m3"), (.assistant, "m4")], characterID: c.id, name: "A")
        session.authorsNote = AuthorsNote(text: "气氛紧张", depth: 1, enabled: true)
        let hiddenID = session.activePath()[1].id
        session.setHidden(hiddenID, hidden: true)
        let book = Lorebook(name: "b", entries: [LoreEntry(comment: "d", content: "深度0", constant: true, position: .atDepth, depth: 0)])
        let plan = PromptBuilder().build(context(session: session, characters: [c], speaker: c, lorebooks: [book]))
        let contents = plan.messages.map(\.content)
        XCTAssertFalse(contents.contains("m2"), "隐藏消息不进提示词")
        // m1, m3, [作者注释], m4, 深度0
        let idxNote = contents.firstIndex { $0.contains("气氛紧张") }!
        let idxM4 = contents.firstIndex(of: "m4")!
        let idxDepth0 = contents.firstIndex(of: "深度0")!
        XCTAssertEqual(idxNote + 1, idxM4)
        XCTAssertGreaterThan(idxDepth0, idxM4)
    }

    func testLoreStateAdvancesInPlan() {
        let c = TavernCharacter(name: "A")
        let entry = LoreEntry(keys: ["火"], content: "篝火", sticky: 2)
        let session = chat(with: [(.user, "生火")], characterID: c.id)
        let plan = PromptBuilder().build(context(session: session, characters: [c], speaker: c, lorebooks: [Lorebook(name: "b", entries: [entry])]))
        XCTAssertEqual(plan.lore.nextState.stickyRemaining[entry.id], 1)
    }
}

final class HistoryWindowTests: XCTestCase {
    func testChooseStart() {
        XCTAssertEqual(HistoryWindow.chooseStart(costs: [10, 10, 10], budget: 100, previousAnchor: 0), 0)
        XCTAssertEqual(HistoryWindow.chooseStart(costs: [], budget: 100, previousAnchor: 3), 0)
        // 总量 100 > 预算 50：目标 35 → 保留最后 3 条（30）
        XCTAssertEqual(HistoryWindow.chooseStart(costs: Array(repeating: 10, count: 10), budget: 50, previousAnchor: 0), 7)
        // 旧锚点仍放得下就不动
        XCTAssertEqual(HistoryWindow.chooseStart(costs: Array(repeating: 10, count: 10), budget: 50, previousAnchor: 6), 6)
        // 单条超长也至少保留最后一条
        XCTAssertEqual(HistoryWindow.chooseStart(costs: [10, 500], budget: 50, previousAnchor: 0), 1)
    }
}

final class ChatTemplateTests: XCTestCase {
    let messages = [
        PromptMessage(role: .system, content: "SYS"),
        PromptMessage(role: .user, content: "U1"),
        PromptMessage(role: .assistant, content: "A1"),
        PromptMessage(role: .user, content: "U2"),
        PromptMessage(role: .user, content: "U3")
    ]

    func testChatMLWithThinkingDisabled() {
        let r = ChatTemplateRenderer.render(messages, format: .chatml, prefill: "艾琳：", disableThinking: true, modelSupportsThinking: true)
        XCTAssertEqual(r.text, """
        <|im_start|>system
        SYS<|im_end|>
        <|im_start|>user
        U1<|im_end|>
        <|im_start|>assistant
        A1<|im_end|>
        <|im_start|>user
        U2

        U3<|im_end|>
        <|im_start|>assistant
        <think>

        </think>

        艾琳：
        """)
        XCTAssertTrue(r.stopSequences.contains("<|im_end|>"))
        let noThink = ChatTemplateRenderer.render(messages, format: .chatml, disableThinking: true, modelSupportsThinking: false)
        XCTAssertFalse(noThink.text.contains("<think>"))
    }

    func testGemmaMergesSystemIntoFirstUser() {
        let r = ChatTemplateRenderer.render(messages, format: .gemma)
        XCTAssertTrue(r.text.hasPrefix("<start_of_turn>user\nSYS\n\nU1<end_of_turn>\n<start_of_turn>model\nA1<end_of_turn>\n"))
        XCTAssertTrue(r.text.hasSuffix("<start_of_turn>model\n"))
        XCTAssertFalse(r.text.contains("system"))
    }

    func testLlama3AndMistral() {
        let l = ChatTemplateRenderer.render(messages, format: .llama3)
        XCTAssertTrue(l.text.hasPrefix("<|start_header_id|>system<|end_header_id|>\n\nSYS<|eot_id|>"))
        XCTAssertTrue(l.text.hasSuffix("<|start_header_id|>assistant<|end_header_id|>\n\n"))
        let m = ChatTemplateRenderer.render(messages, format: .mistral)
        XCTAssertTrue(m.text.hasPrefix("[INST] SYS\n\nU1 [/INST] A1</s>[INST] U2\n\nU3 [/INST]"))
    }

    func testDetect() {
        XCTAssertEqual(PromptFormat.detect(chatTemplate: "{% for m in messages %}<|im_start|>{{m.role}}", architecture: "qwen35"), .chatml)
        XCTAssertEqual(PromptFormat.detect(chatTemplate: "<start_of_turn>user", architecture: nil), .gemma)
        XCTAssertEqual(PromptFormat.detect(chatTemplate: "<|start_header_id|>", architecture: nil), .llama3)
        XCTAssertEqual(PromptFormat.detect(chatTemplate: "[INST]", architecture: nil), .mistral)
        XCTAssertEqual(PromptFormat.detect(chatTemplate: "{{weird}}", architecture: nil), .modelBuiltin)
        XCTAssertEqual(PromptFormat.detect(chatTemplate: nil, architecture: "qwen3"), .chatml)
        XCTAssertTrue(PromptFormat.supportsThinking(chatTemplate: "{%- if enable_thinking %}<think>"))
        XCTAssertFalse(PromptFormat.supportsThinking(chatTemplate: "<|im_start|>"))
    }
}

final class MacroTests: XCTestCase {
    func testExpand() {
        let m = MacroContext(characterName: "艾琳", userName: "旅人", originalSystemPrompt: "原始", groupNames: ["艾琳", "莱恩"])
        XCTAssertEqual(m.expand("{{char}}对{{user}}说，<BOT>与<USER>，{{original}}，{{group}}"), "艾琳对旅人说，艾琳与旅人，原始，艾琳、莱恩")
        XCTAssertEqual(m.expand("无宏"), "无宏")
    }

    func testHeuristicCounter() {
        let c = HeuristicTokenCounter()
        XCTAssertEqual(c.count(""), 0)
        XCTAssertEqual(c.count("你好世界"), 3)
        XCTAssertGreaterThan(c.count("Hello world, this is a test."), 5)
    }
}
