import XCTest
@testable import MoonlitCore

/// 用户性别、DRY 防复述设置、「继续」续写。
final class PersonaAndContinuationTests: XCTestCase {
    private func plan(persona: UserPersona, history: [ChatMessage] = []) -> PromptPlan {
        let erin = TavernCharacter(name: "艾琳", description: "老板娘")
        var chat = ChatSession(title: "t", characterIDs: [erin.id])
        chat.append(ChatMessage(role: .assistant, speakerID: erin.id, speakerName: "艾琳", content: "这么晚还在外面晃？"))
        for m in history { chat.append(m) }
        let ctx = PromptContext(
            characters: [erin], speaker: erin, persona: persona, settings: AppSettings(),
            session: chat, lorebooks: [], memory: nil, contextLength: 4096, maxNewTokens: 200,
            tokenCounter: HeuristicTokenCounter()
        )
        return PromptBuilder().build(ctx)
    }

    // MARK: - 性别

    func testGenderDetection() {
        XCTAssertEqual(PersonaGender.detect(in: "镇上的男性铁匠"), .male)
        XCTAssertEqual(PersonaGender.detect(in: "刚毕业的女生，话不多"), .female)
        XCTAssertEqual(PersonaGender.detect(in: "有个男朋友的少女"), .female, "「男朋友」不算")
        XCTAssertNil(PersonaGender.detect(in: "喜欢成熟的男人"), "描述偏好的「男人」不算")
        XCTAssertNil(PersonaGender.detect(in: "一个迷路的商人"))
        XCTAssertNil(PersonaGender.detect(in: "男生女生都可以"), "两边都出现时不猜")
        XCTAssertEqual(PersonaGender.detect(in: "A male knight"), .male)
        XCTAssertEqual(PersonaGender.detect(in: "a female mage"), .female, "female 里的 male 不算")
        XCTAssertNil(PersonaGender.detect(in: ""))
    }

    func testExplicitGenderWinsOverDescription() {
        let p = UserPersona(name: "旅人", description: "刚毕业的女生", gender: .male)
        XCTAssertEqual(p.effectiveGender, .male)
        XCTAssertEqual(UserPersona(name: "旅人", description: "刚毕业的女生").effectiveGender, .female)
    }

    func testGenderGoesIntoPersonaBlockAndReminderBeforeReply() {
        let p = plan(persona: UserPersona(name: "旅人", description: "镇上的男性铁匠"),
                     history: [ChatMessage(role: .user, speakerName: "旅人", content: "还有空房吗？")])
        let system = p.messages.first?.content ?? ""
        XCTAssertTrue(system.contains("【旅人（用户）】\n性别：男\n镇上的男性铁匠"), system)
        let last = p.messages.last
        XCTAssertEqual(last?.role, .system, "提醒放在最后，紧挨着回复")
        XCTAssertTrue(last?.content.contains("旅人是男性") == true)
        XCTAssertTrue(last?.content.contains("「他」") == true)
        XCTAssertEqual(p.tailCount, 1, "提醒算末尾指令，剧情选项请求会把它去掉")
    }

    func testNoReminderWhenGenderUnknown() {
        let p = plan(persona: UserPersona(name: "旅人", description: "一个迷路的商人"))
        XCTAssertEqual(p.tailCount, 0)
        XCTAssertFalse(p.messages.contains { $0.content.contains("称呼和代词") })
        XCTAssertFalse(p.messages.first?.content.contains("性别：") == true)
    }

    func testGenderWithoutDescriptionStillWritten() {
        let p = plan(persona: UserPersona(name: "旅人", gender: .female))
        XCTAssertTrue(p.messages.first?.content.contains("【旅人（用户）】\n性别：女") == true)
        XCTAssertTrue(p.messages.last?.content.contains("「她」") == true)
    }

    func testPersonaGenderRoundTripAndOldDataDecodes() throws {
        let p = UserPersona(name: "旅人", description: "", gender: .female)
        let decoded = try JSONDecoder().decode(UserPersona.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.gender, .female)
        let old = try JSONDecoder().decode(UserPersona.self, from: Data(#"{"name":"旅人","description":"商人"}"#.utf8))
        XCTAssertNil(old.gender)
    }

    // MARK: - 采样设置与默认值

    func testOldSamplingSettingsGetDryDefaults() throws {
        let json = #"{"temperature":0.7,"topP":0.9,"topK":40,"minP":0.05,"repeatPenalty":1.1,"repeatLastN":256,"presencePenalty":0,"frequencyPenalty":0,"maxNewTokens":400}"#
        let s = try JSONDecoder().decode(SamplingParams.self, from: Data(json.utf8))
        XCTAssertEqual(s.temperature, 0.7)
        XCTAssertEqual(s.repeatPenalty, 1.1)
        XCTAssertEqual(s.dryMultiplier, 0.8, "旧设置升级后直接打开 DRY")
        XCTAssertEqual(s.dryBase, 1.75)
        XCTAssertEqual(s.dryAllowedLength, 3)
        let round = try JSONDecoder().decode(SamplingParams.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(round, s)
        XCTAssertEqual(SamplingParams.summarization.dryMultiplier, 0, "摘要要照抄原话，不开 DRY")
    }

    func testDefaultsForLongerRepliesAndContext() {
        XCTAssertEqual(ReplyLength.medium.tokens, 480)
        XCTAssertEqual(ReplyLength.long.tokens, 960)
        XCTAssertEqual(LocalModelSettings().contextLength, 16384)
    }

    // MARK: - 继续

    func testContinuationPrefillsExistingTextForLocalModels() {
        let p = plan(persona: UserPersona(name: "旅人"),
                     history: [ChatMessage(role: .user, speakerName: "旅人", content: "还有空房吗？")])
        let r = ReplyContinuation.request(plan: p, base: "*她擦着杯子，", supportsPrefill: true,
                                          sampling: SamplingParams(), maxNewTokens: 480)
        XCTAssertEqual(r.messages, p.messages, "提示词和原来的回复一样，本地模型可以复用缓存")
        XCTAssertEqual(r.prefill, "*她擦着杯子，")
        XCTAssertEqual(r.maxNewTokens, 480)
        XCTAssertEqual(r.purpose, .reply)
    }

    func testContinuationForCloudAddsAssistantMessageAndInstruction() {
        let p = plan(persona: UserPersona(name: "旅人"))
        let r = ReplyContinuation.request(plan: p, base: "*她擦着杯子，", supportsPrefill: false,
                                          sampling: SamplingParams(), maxNewTokens: 480)
        XCTAssertEqual(r.messages.count, p.messages.count + 2)
        XCTAssertEqual(r.messages[r.messages.count - 2], PromptMessage(role: .assistant, content: "*她擦着杯子，"))
        XCTAssertEqual(r.messages.last?.content, ReplyContinuation.instruction)
        XCTAssertEqual(r.prefill, "")
    }

    func testContinuationJoinsText() {
        let joined = ReplyContinuation.finalize(base: "*她擦着杯子，", addition: "抬头看了你一眼。*\n「坐吧。」", speakerName: "艾琳")
        XCTAssertEqual(joined.content, "*她擦着杯子，抬头看了你一眼。*\n「坐吧。」")
        let nothing = ReplyContinuation.finalize(base: "坐吧。", addition: "  \n", speakerName: "艾琳")
        XCTAssertEqual(nothing.content, "坐吧。", "什么都没续写出来时保持原样")
        let thinking = ReplyContinuation.finalize(base: "坐吧。", addition: "<think></think>想喝点什么？", speakerName: "艾琳")
        XCTAssertEqual(thinking.content, "坐吧。想喝点什么？")
    }

    func testContinueMessageUpdatesInPlace() {
        var chat = ChatSession(title: "t", characterIDs: [UUID()])
        chat.append(ChatMessage(role: .user, speakerName: "旅人", content: "还有空房吗？"))
        let reply = chat.append(ChatMessage(role: .assistant, speakerName: "艾琳", content: "二楼"))
        chat.setSuggestions(["上楼", "离开"], for: reply.id)
        let stats = GenerationStats(engine: "llama.cpp", modelName: "m", stopReason: "自然结束")
        chat.continueMessage(reply.id, content: "二楼最里面那间。", stats: stats)
        XCTAssertEqual(chat.message(reply.id)?.content, "二楼最里面那间。")
        XCTAssertEqual(chat.message(reply.id)?.stats?.stopReason, "自然结束")
        XCTAssertNil(chat.message(reply.id)?.suggestions, "选项是按旧内容想的，作废")
        XCTAssertNil(chat.message(reply.id)?.editedAt, "续写不算用户编辑")
        XCTAssertEqual(chat.siblingPosition(of: reply.id).count, 1, "不产生新版本")
        XCTAssertEqual(chat.activePath().count, 2)
    }
}
