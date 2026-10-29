import XCTest
@testable import MoonlitCore

final class ReplySuggestionTests: XCTestCase {
    func testParseNumberedList() {
        let output = "问她二楼的房间多少钱\n2. *把湿透的斗篷挂到火炉边*\n3. 「最近镇上出什么事了？」\n4. 多余的一条"
        let options = ReplySuggestions.parse(output, userName: "旅人", characterNames: ["艾琳"], limit: 3)
        XCTAssertEqual(options, ["问她二楼的房间多少钱", "*把湿透的斗篷挂到火炉边*", "最近镇上出什么事了？"])
    }

    func testParseToleratesMessyOutput() {
        let output = "旅人：我先坐下歇歇\n\n- 打听钟楼的事\n艾琳：哼，随你。\n2、起身离开酒馆\n以下是选项：\n2. 打听钟楼的事"
        let options = ReplySuggestions.parse(output, userName: "旅人", characterNames: ["艾琳"], limit: 4)
        XCTAssertEqual(options, ["我先坐下歇歇", "打听钟楼的事", "起身离开酒馆"], "去掉说话人前缀、角色台词、说明行和重复项")
    }

    func testParseEmptyOutput() {
        XCTAssertEqual(ReplySuggestions.parse("", userName: "旅人", characterNames: ["艾琳"]), [])
        XCTAssertEqual(ReplySuggestions.parse("   \n  ", userName: "旅人", characterNames: ["艾琳"]), [])
    }

    func testRequestReusesReplyPromptPrefix() {
        let erin = TavernCharacter(name: "艾琳", description: "老板娘", postHistoryInstructions: "保持简短")
        var chat = ChatSession(title: "t", characterIDs: [erin.id])
        chat.append(ChatMessage(role: .assistant, speakerID: erin.id, speakerName: "艾琳", content: "这么晚还在外面晃？"))
        chat.append(ChatMessage(role: .user, speakerName: "旅人", content: "还有空房吗？"))
        chat.append(ChatMessage(role: .assistant, speakerID: erin.id, speakerName: "艾琳", content: "二楼最里面那间。"))
        let ctx = PromptContext(
            characters: [erin], speaker: erin, persona: UserPersona(name: "旅人"), settings: AppSettings(),
            session: chat, lorebooks: [], memory: nil, contextLength: 4096, maxNewTokens: 200,
            tokenCounter: HeuristicTokenCounter()
        )
        let plan = PromptBuilder().build(ctx)
        XCTAssertEqual(plan.tailCount, 1, "历史后指令算一条末尾指令")
        let request = ReplySuggestions.request(plan: plan, userName: "旅人", characterNames: ["艾琳"], count: 3, sampling: SamplingParams())
        let shared = plan.messages.count - plan.tailCount
        XCTAssertEqual(Array(request.messages.prefix(shared)), Array(plan.messages.prefix(shared)),
                       "选项请求与回复请求共享前缀，本地模型可以复用缓存")
        XCTAssertEqual(request.messages.last?.role, .user)
        XCTAssertTrue(request.messages.last?.content.contains("剧情选项") == true)
        XCTAssertFalse(request.messages.contains { $0.content == "保持简短" }, "历史后指令是给角色的，不放进选项请求")
        XCTAssertEqual(request.prefill, "1. ")
        XCTAssertEqual(request.purpose, .suggestions)
        XCTAssertTrue(request.stopSequences.contains("\n4."))
    }

    func testSuggestionsSurviveRoundTripAndEditClearsThem() throws {
        var chat = ChatSession(title: "t", characterIDs: [UUID()])
        let reply = chat.append(ChatMessage(role: .assistant, speakerName: "艾琳", content: "坐吧。"))
        chat.setSuggestions(["坐下", "离开"], for: reply.id)
        XCTAssertEqual(chat.message(reply.id)?.content, "坐吧。", "写入选项不改回复正文")
        let data = try JSONEncoder().encode(chat)
        let decoded = try JSONDecoder().decode(ChatSession.self, from: data)
        XCTAssertEqual(decoded.message(reply.id)?.suggestions, ["坐下", "离开"])
        chat.editMessage(reply.id, content: "站着吧。")
        XCTAssertNil(chat.message(reply.id)?.suggestions)
    }

    func testOldSettingsDecodeWithSuggestionDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"loreTokenBudget": 500}"#.utf8))
        XCTAssertTrue(settings.suggestions.enabled)
        XCTAssertEqual(settings.suggestions.count, 3)
    }
}
