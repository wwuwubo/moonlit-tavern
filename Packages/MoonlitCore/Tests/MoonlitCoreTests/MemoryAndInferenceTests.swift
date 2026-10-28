import XCTest
@testable import MoonlitCore

final class MemoryTests: XCTestCase {
    func testKeywordExtractor() {
        let terms = KeywordExtractor.terms(in: "艾琳的钟楼 and the Dragon")
        XCTAssertTrue(terms.contains("艾琳"))
        XCTAssertTrue(terms.contains("钟楼"))
        XCTAssertTrue(terms.contains("dragon"))
        XCTAssertFalse(terms.contains("the"))
    }

    func testRetrieverPrioritiesAndBudget() {
        var memory = ChatMemory(chatID: UUID())
        let pinned = MemoryItem(kind: .fact, content: "旅人左手有伤", pinned: true)
        let oldSummary = MemoryItem(kind: .summary, content: "第一章摘要", messageIndex: 10)
        let newSummary = MemoryItem(kind: .summary, content: "第二章摘要", messageIndex: 40)
        let oldestSummary = MemoryItem(kind: .summary, content: "序章摘要", messageIndex: 2)
        let relevant = MemoryItem(kind: .event, content: "在钟楼地下发现了封印", importance: 3, messageIndex: 20)
        let irrelevant = MemoryItem(kind: .event, content: "买了一匹马", importance: 3, messageIndex: 21)
        let disabled = MemoryItem(kind: .event, content: "钟楼着火", enabled: false)
        memory.items = [irrelevant, relevant, oldSummary, newSummary, oldestSummary, pinned, disabled]

        let sel = MemoryRetriever().select(from: memory, query: "我们再去钟楼看看", tokenBudget: 1000, maxRetrieved: 1, tokenCounter: CharCounter())
        let contents = sel.items.map(\.content)
        XCTAssertEqual(contents.first, "旅人左手有伤", "常驻最先")
        XCTAssertTrue(contents.contains("第二章摘要"))
        XCTAssertTrue(contents.contains("第一章摘要"))
        XCTAssertFalse(contents.contains("序章摘要"), "只取最新两条摘要")
        XCTAssertTrue(contents.contains("在钟楼地下发现了封印"), "关键词相关的事件被检索到")
        XCTAssertFalse(contents.contains("买了一匹马"), "maxRetrieved = 1")
        XCTAssertFalse(contents.contains("钟楼着火"), "停用的记忆不注入")

        let tiny = MemoryRetriever().select(from: memory, query: "钟楼", tokenBudget: 10, maxRetrieved: 5, tokenCounter: CharCounter())
        XCTAssertLessThanOrEqual(tiny.tokens, 10)

        let rendered = MemoryRetriever.render(sel.items)
        XCTAssertTrue(rendered.contains("前情提要："))
        XCTAssertLessThan(rendered.range(of: "第一章摘要")!.lowerBound, rendered.range(of: "第二章摘要")!.lowerBound)
    }

    func testSummaryParserStandardFormat() {
        let output = """
        摘要：旅人在满月夜来到酒馆，艾琳收留了他。两人谈到钟楼的传说。
        事件：
        - 旅人用一枚旧金币付了房钱
        - 艾琳警告旅人满月夜不要开窗
        关系：
        - 艾琳→旅人：从戒备转为好奇
        - 莱恩->艾琳：欠她一条命
        状态：
        - 地点=月下酒馆，时间=深夜
        - 月相=满月
        """
        let r = Summarizer.parse(output)
        XCTAssertTrue(r.summary.hasPrefix("旅人在满月夜来到酒馆"))
        XCTAssertEqual(r.events.count, 2)
        XCTAssertEqual(r.relationships, [
            .init(subject: "艾琳", object: "旅人", state: "从戒备转为好奇"),
            .init(subject: "莱恩", object: "艾琳", state: "欠她一条命")
        ])
        XCTAssertEqual(r.stateUpdates, ["地点": "月下酒馆", "时间": "深夜", "月相": "满月"])
    }

    func testSummaryParserTolerance() {
        let r = Summarizer.parse("<think>嗯</think>**摘要**: A happened.\n事件：无\n关系：无\n状态：无")
        XCTAssertEqual(r.summary, "A happened.")
        XCTAssertTrue(r.events.isEmpty)
        XCTAssertTrue(r.relationships.isEmpty)
        XCTAssertTrue(r.stateUpdates.isEmpty)

        let plain = Summarizer.parse("没有标签的一段话。\n第二行。")
        XCTAssertEqual(plain.summary, "没有标签的一段话。\n第二行。")
        XCTAssertTrue(Summarizer.parse("   ").isEmpty)
    }

    func testMergeRelationshipsKeepsLatest() {
        var memory = ChatMemory(chatID: UUID())
        let first = Summarizer.memoryItems(from: .init(summary: "s1", events: ["e1"], relationships: [.init(subject: "A", object: "B", state: "陌生")], stateUpdates: [:]), messageIndex: 10)
        Summarizer.merge(first, into: &memory)
        let second = Summarizer.memoryItems(from: .init(summary: "s2", events: [], relationships: [.init(subject: "A", object: "B", state: "信任")], stateUpdates: [:]), messageIndex: 20)
        Summarizer.merge(second, into: &memory)
        let relations = memory.items.filter { $0.kind == .relationship }
        XCTAssertEqual(relations.count, 1)
        XCTAssertEqual(relations.first?.content, "信任")
        XCTAssertEqual(memory.summaries.count, 2)
    }

    func testSummaryPromptContainsTranscript() {
        let msgs = [ChatMessage(role: .user, speakerName: "旅人", content: "你好"), ChatMessage(role: .assistant, speakerName: "艾琳", content: "欢迎")]
        let p = Summarizer.prompt(messages: msgs, previousSummary: "之前", characterNames: ["艾琳"], userName: "旅人")
        XCTAssertEqual(p.count, 2)
        XCTAssertTrue(p[1].content.contains("旅人：你好\n艾琳：欢迎"))
        XCTAssertTrue(p[1].content.contains("之前"))
    }
}

final class GGUFTests: XCTestCase {
    /// 按 GGUF v3 规范手工拼一个只有元数据的文件头。
    private func makeGGUF(_ kvs: [(String, UInt32, (inout Data) -> Void)]) -> Data {
        var d = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32(3); u64(0); u64(UInt64(kvs.count))
        for (key, type, writer) in kvs {
            u64(UInt64(key.utf8.count)); d.append(contentsOf: key.utf8)
            u32(type)
            writer(&d)
        }
        return d
    }

    private func str(_ s: String) -> (inout Data) -> Void {
        { d in
            withUnsafeBytes(of: UInt64(s.utf8.count).littleEndian) { d.append(contentsOf: $0) }
            d.append(contentsOf: s.utf8)
        }
    }

    private func u32(_ v: UInt32) -> (inout Data) -> Void {
        { d in withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    }

    private func u32Array(_ values: [UInt32]) -> (inout Data) -> Void {
        { d in
            withUnsafeBytes(of: UInt32(4).littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt64(values.count).littleEndian) { d.append(contentsOf: $0) }
            for v in values { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        }
    }

    private func bigStringArray(_ count: Int) -> (inout Data) -> Void {
        { d in
            withUnsafeBytes(of: UInt32(8).littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt64(count).littleEndian) { d.append(contentsOf: $0) }
            for i in 0..<count {
                let s = "t\(i)"
                withUnsafeBytes(of: UInt64(s.utf8.count).littleEndian) { d.append(contentsOf: $0) }
                d.append(contentsOf: s.utf8)
            }
        }
    }

    func testParseStandardTransformer() throws {
        let data = makeGGUF([
            ("general.architecture", 8, str("qwen3")),
            ("general.name", 8, str("Qwen3 4B Instruct")),
            ("general.file_type", 4, u32(15)),
            ("qwen3.block_count", 4, u32(36)),
            ("qwen3.context_length", 4, u32(262144)),
            ("qwen3.embedding_length", 4, u32(2560)),
            ("qwen3.attention.head_count", 4, u32(32)),
            ("qwen3.attention.head_count_kv", 4, u32(8)),
            ("qwen3.attention.key_length", 4, u32(128)),
            ("qwen3.attention.value_length", 4, u32(128)),
            ("tokenizer.ggml.tokens", 9, bigStringArray(5000)),
            ("tokenizer.chat_template", 8, str("<|im_start|>{% if enable_thinking %}<think>"))
        ])
        let meta = try GGUFReader.parse(data)
        XCTAssertEqual(meta.architecture, "qwen3")
        XCTAssertEqual(meta.blockCount, 36)
        XCTAssertEqual(meta.contextLength, 262144)
        XCTAssertEqual(meta.headCountKV, [8])
        XCTAssertEqual(meta.quantizationLabel, "Q4_K_M")
        XCTAssertEqual(PromptFormat.detect(chatTemplate: meta.chatTemplate, architecture: meta.architecture), .chatml)
        if case .skippedArray(let n)? = meta.values["tokenizer.ggml.tokens"] { XCTAssertEqual(n, 5000) } else { XCTFail("大数组应跳过") }

        let shape = try XCTUnwrap(MemoryPlanner.shape(from: meta))
        XCTAssertEqual(shape.attentionLayers, 36)
        XCTAssertEqual(shape.kvElementsPerToken, 36 * 8 * 256)
        // 8192 上下文 f16：36 层 × 8 头 × 256 × 8192 × 2 字节 = 1152 MiB
        XCTAssertEqual(MemoryPlanner.kvCacheMB(shape: shape, contextLength: 8192, cacheType: .f16), 1152, accuracy: 0.01)
        XCTAssertEqual(MemoryPlanner.kvCacheMB(shape: shape, contextLength: 8192, cacheType: .q8_0), 612, accuracy: 0.01)
    }

    func testHybridArchitectureCountsOnlyAttentionLayers() throws {
        let data = makeGGUF([
            ("general.architecture", 8, str("qwen35")),
            ("qwen35.block_count", 4, u32(32)),
            ("qwen35.embedding_length", 4, u32(2560)),
            ("qwen35.attention.head_count", 4, u32(16)),
            ("qwen35.attention.head_count_kv", 4, u32(4)),
            ("qwen35.attention.key_length", 4, u32(256)),
            ("qwen35.attention.value_length", 4, u32(256)),
            ("qwen35.full_attention_interval", 4, u32(4))
        ])
        let shape = try XCTUnwrap(MemoryPlanner.shape(from: GGUFReader.parse(data)))
        XCTAssertEqual(shape.attentionLayers, 8)
        // 8 层 × 4 头 × 512 × 8192 × 2 字节 = 256 MiB
        XCTAssertEqual(MemoryPlanner.kvCacheMB(shape: shape, contextLength: 8192, cacheType: .f16), 256, accuracy: 0.01)
    }

    func testPerLayerKVArray() throws {
        let data = makeGGUF([
            ("general.architecture", 8, str("hybrid")),
            ("hybrid.block_count", 4, u32(4)),
            ("hybrid.attention.head_count", 4, u32(8)),
            ("hybrid.embedding_length", 4, u32(1024)),
            ("hybrid.attention.head_count_kv", 9, u32Array([0, 2, 0, 2]))
        ])
        let shape = try XCTUnwrap(MemoryPlanner.shape(from: GGUFReader.parse(data)))
        XCTAssertEqual(shape.attentionLayers, 2)
        XCTAssertEqual(shape.kvElementsPerToken, 2 * 2 * (128 + 128))
    }

    func testEstimateAndRecommendation() {
        let shape = ModelShape(attentionLayers: 36, kvElementsPerToken: 36 * 8 * 256, description: "")
        let size: Int64 = 2_500 * 1_048_576
        let e = MemoryPlanner.estimate(fileSizeBytes: size, shape: shape, contextLength: 8192, cacheType: .q8_0)
        XCTAssertEqual(e.weightsMB, 2500, accuracy: 0.1)
        XCTAssertEqual(e.kvCacheMB, 612, accuracy: 0.1)
        XCTAssertGreaterThan(e.totalMB, 3400)
        XCTAssertEqual(MemoryPlanner.recommendedContext(fileSizeBytes: size, shape: shape, cacheType: .q8_0, availableMB: 6000), 8192)
        let smaller = MemoryPlanner.recommendedContext(fileSizeBytes: size, shape: shape, cacheType: .q8_0, availableMB: 3800)
        XCTAssertNotNil(smaller)
        XCTAssertLessThan(smaller!, 8192)
        XCTAssertNil(MemoryPlanner.recommendedContext(fileSizeBytes: size, shape: shape, cacheType: .q8_0, availableMB: 2000))
    }

    func testRejectsNonGGUF() {
        XCTAssertThrowsError(try GGUFReader.parse(Data("NOPE0000".utf8)))
        XCTAssertThrowsError(try GGUFReader.parse(Data("GGUF".utf8)))
    }
}

final class OpenAICompatibleTests: XCTestCase {
    func testRequestBody() throws {
        var sampling = SamplingParams()
        sampling.temperature = 0.9
        sampling.presencePenalty = 0.5
        let request = GenerationRequest(
            messages: [PromptMessage(role: .system, content: "S"), PromptMessage(role: .user, content: "U"), PromptMessage(role: .user, content: "U2")],
            prefill: "莱恩：", sampling: sampling, maxNewTokens: 300, stopSequences: ["a", "b", "c", "d", "e"]
        )
        let body = try OpenAICompatible.requestBody(model: "m", request: request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "m")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, 300)
        XCTAssertEqual((json["stop"] as? [String])?.count, 4)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 3, "相邻 user 合并 + 一条发言提示")
        XCTAssertEqual(messages[1]["content"], "U\n\nU2")
        XCTAssertTrue(messages[2]["content"]!.contains("莱恩"))
        XCTAssertEqual(json["presence_penalty"] as? Double, 0.5)
    }

    func testURL() {
        XCTAssertEqual(OpenAICompatible.chatCompletionsURL(base: "https://openrouter.ai/api/v1/")?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(OpenAICompatible.chatCompletionsURL(base: "https://x.com/v1/chat/completions")?.absoluteString, "https://x.com/v1/chat/completions")
    }

    func testSSEParser() {
        var p = OpenAICompatible.SSEParser()
        XCTAssertNil(p.parse(line: ": keep-alive"))
        XCTAssertEqual(p.parse(line: #"data: {"choices":[{"delta":{"content":"你"}}]}"#), .delta("你"))
        XCTAssertNil(p.parse(line: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#))
        XCTAssertEqual(p.parse(line: #"data: {"choices":[{"delta":{},"finish_reason":"length"}],"usage":{"prompt_tokens":12,"completion_tokens":34}}"#), .done(finishReason: "length"))
        XCTAssertEqual(p.promptTokens, 12)
        XCTAssertEqual(p.completionTokens, 34)
        XCTAssertEqual(p.parse(line: "data: [DONE]"), .done(finishReason: nil))
        XCTAssertEqual(p.parse(line: #"data: {"error":{"message":"rate limited"}}"#), .error("rate limited"))
    }

    func testErrorMessageNeverEchoesHeaders() {
        let body = Data(#"{"error":{"message":"invalid api key"}}"#.utf8)
        XCTAssertEqual(OpenAICompatible.errorMessage(from: body), "invalid api key")
        XCTAssertEqual(OpenAICompatible.errorMessage(from: Data()), "无响应内容")
    }
}

final class PersistenceTests: XCTestCase {
    func testStoreRoundTripAndBackup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TavernStore(root: dir)
        XCTAssertTrue(store.isFirstLaunch)

        var c = SampleData.erin
        c.avatarFileName = try store.saveAvatar(SolidPNG.make(width: 4, height: 4, r: 1, g: 2, b: 3), for: c.id)
        try store.save(c)
        var chatSession = ChatSession(title: "存档", characterIDs: [c.id])
        chatSession.append(ChatMessage(role: .user, speakerName: "旅人", content: "你好"))
        chatSession.append(ChatMessage(role: .assistant, speakerID: c.id, speakerName: "艾琳", content: "欢迎",
                                       stats: GenerationStats(engine: "e", modelName: "m", generatedTokens: 5, timeToFirstToken: 0.3)))
        chatSession.loreState = LorebookRuntimeState(stickyRemaining: [UUID(): 2])
        try store.save(chatSession)
        try store.save(SampleData.lorebook)
        var memory = ChatMemory(chatID: chatSession.id)
        memory.items = [MemoryItem(kind: .fact, content: "事实")]
        memory.summarizedMessageIDs = [chatSession.messages[0].id]
        try store.save(memory)
        var settings = AppSettings()
        settings.local.contextLength = 4096
        try store.save(settings)

        // 模拟重启：新的 store 实例从磁盘读取
        let reopened = try TavernStore(root: dir)
        XCTAssertFalse(reopened.isFirstLaunch)
        XCTAssertEqual(reopened.loadCharacters().first?.name, "艾琳")
        let loadedChat = try XCTUnwrap(reopened.loadChats().first)
        XCTAssertEqual(loadedChat.activePath().map(\.content), ["你好", "欢迎"])
        XCTAssertEqual(loadedChat.activePath().last?.stats?.generatedTokens, 5)
        XCTAssertEqual(loadedChat.loreState.stickyRemaining.values.first, 2)
        XCTAssertEqual(reopened.loadMemory(chatID: chatSession.id).items.first?.content, "事实")
        XCTAssertEqual(reopened.loadMemory(chatID: chatSession.id).summarizedMessageIDs.count, 1)
        XCTAssertEqual(reopened.loadSettings().local.contextLength, 4096)
        XCTAssertNotNil(reopened.avatarData(c.avatarFileName))

        // 备份 → 恢复到另一个目录
        let backup = try reopened.makeBackup(appVersion: "test")
        let dir2 = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir2) }
        let other = try TavernStore(root: dir2)
        let summary = try other.restore(from: backup, includeSettings: true)
        XCTAssertEqual(summary.characters, 1)
        XCTAssertEqual(summary.chats, 1)
        XCTAssertEqual(summary.lorebooks, 1)
        XCTAssertEqual(summary.memories, 1)
        XCTAssertTrue(summary.settingsRestored)
        XCTAssertEqual(other.loadChats().first?.messages.count, 2)
        XCTAssertNotNil(other.avatarData(c.avatarFileName))
    }

    func testCorruptedFileIsSkipped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TavernStore(root: dir)
        try store.save(TavernCharacter(name: "好的"))
        try Data("{broken".utf8).write(to: dir.appendingPathComponent("characters/bad.json"))
        let chars = store.loadCharacters()
        XCTAssertEqual(chars.map(\.name), ["好的"])
        XCTAssertEqual(store.loadIssues.count, 1)
    }

    func testSettingsDecodeWithMissingFields() throws {
        let json = #"{"providerMode":"cloud","local":{"contextLength":6144},"sampling":{"temperature":1.1}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.providerMode, .cloud)
        XCTAssertEqual(s.local.contextLength, 6144)
        XCTAssertEqual(s.local.kvCacheType, .q8_0)
        XCTAssertEqual(s.sampling.temperature, 1.1, accuracy: 0.0001)
        XCTAssertEqual(s.sampling.topP, 0.9, accuracy: 0.0001)
        XCTAssertEqual(s.persona.name, "旅人")
    }

    func testBackupPathTraversalIsNeutralized() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TavernStore(root: dir)
        let bundle = BackupBundle(appVersion: "x", characters: [], chats: [], lorebooks: [], memories: [], settings: nil,
                                  avatars: ["../../evil.png": Data([1, 2, 3])])
        try store.restore(from: JSONEncoder().encode(bundle), includeSettings: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("avatars/evil.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("evil.png").path))
    }

    func testSampleDataIsMarked() {
        XCTAssertTrue(SampleData.characters.allSatisfy(\.isSample))
        XCTAssertTrue(SampleData.lorebook.isSample)
        XCTAssertEqual(SampleData.erin.allGreetings.count, 2)
    }
}
