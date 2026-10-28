import XCTest
@testable import MoonlitCore

final class LorebookEngineTests: XCTestCase {
    private let engine = LorebookEngine()

    private func run(
        _ entries: [LoreEntry],
        messages: [String],
        budget: Int = 10_000,
        state: LorebookRuntimeState = LorebookRuntimeState(),
        plot: [String: String] = [:],
        name: String = "艾琳",
        roll: Int = 0,
        recursive: Bool = true,
        scanDepth: Int = 4
    ) -> LorebookEngine.Result {
        let book = Lorebook(name: "测试", scanDepth: scanDepth, recursiveScanning: recursive, entries: entries)
        return engine.evaluate(.init(
            books: [book], recentMessages: messages, activeCharacterName: name, plotState: plot,
            messageCount: messages.count, state: state, tokenBudget: budget, tokenCounter: CharCounter(),
            roll: { _ in roll }
        ))
    }

    func testConstantAndKeywordActivation() {
        let constant = LoreEntry(comment: "世界", content: "长夜", constant: true)
        let tavern = LoreEntry(comment: "酒馆", keys: ["酒馆"], content: "十字路口的酒馆")
        let tower = LoreEntry(comment: "钟楼", keys: ["钟楼"], content: "十三声钟")
        let result = run([constant, tavern, tower], messages: ["旅人: 这家酒馆还开着吗？"])
        XCTAssertEqual(Set(result.included.map(\.entry.comment)), ["世界", "酒馆"])
        XCTAssertEqual(result.included.first { $0.entry.comment == "酒馆" }?.reason, .keyword("酒馆"))
    }

    func testScanDepthLimitsHistory() {
        let e = LoreEntry(keys: ["龙"], content: "龙的设定")
        let messages = ["说到龙", "a", "b", "c", "d"]
        XCTAssertTrue(run([e], messages: messages, scanDepth: 4).included.isEmpty, "第 5 条之前的消息不在扫描范围")
        XCTAssertEqual(run([e], messages: messages, scanDepth: 5).included.count, 1)
    }

    func testCaseSensitivityAndWholeWords() {
        let insensitive = LoreEntry(comment: "a", keys: ["Dragon"], content: "x")
        let sensitive = LoreEntry(comment: "b", keys: ["Dragon"], content: "y", caseSensitive: true)
        let whole = LoreEntry(comment: "c", keys: ["cat"], content: "z", matchWholeWords: true)
        let r = run([insensitive, sensitive, whole], messages: ["a dragon flew over the category"])
        XCTAssertEqual(Set(r.included.map(\.entry.comment)), ["a"])
        let r2 = run([whole], messages: ["the cat sat"])
        XCTAssertEqual(r2.included.count, 1)
    }

    func testRegexKey() {
        let e = LoreEntry(keys: ["/第[一二三]章/"], content: "章节开始")
        XCTAssertEqual(run([e], messages: ["现在进入第二章"]).included.count, 1)
        XCTAssertTrue(run([e], messages: ["第五章"]).included.isEmpty)
    }

    func testSelectiveLogic() {
        func entry(_ logic: SelectiveLogic) -> LoreEntry {
            LoreEntry(comment: "\(logic)", keys: ["市场"], secondaryKeys: ["价格", "交易"], selective: true, selectiveLogic: logic, content: "c")
        }
        let text = ["月亮市场的价格"]
        XCTAssertEqual(run([entry(.andAny)], messages: text).included.count, 1)
        XCTAssertEqual(run([entry(.andAll)], messages: text).included.count, 0)
        XCTAssertEqual(run([entry(.notAny)], messages: text).included.count, 0)
        XCTAssertEqual(run([entry(.notAll)], messages: text).included.count, 1)
        XCTAssertEqual(run([entry(.notAny)], messages: ["月亮市场"]).included.count, 1)
    }

    func testProbability() {
        let e = LoreEntry(keys: ["雨"], content: "下雨了", probability: 30)
        XCTAssertEqual(run([e], messages: ["雨"], roll: 10).included.count, 1)
        XCTAssertEqual(run([e], messages: ["雨"], roll: 50).included.count, 0)
    }

    func testRecursionAndRecursionFlags() {
        let a = LoreEntry(comment: "A", keys: ["王都"], content: "王都里住着龙")
        let b = LoreEntry(comment: "B", keys: ["龙"], content: "龙怕月光")
        let c = LoreEntry(comment: "C", keys: ["月光"], content: "月光来自月亮")
        let r = run([a, b, c], messages: ["我们去王都"])
        XCTAssertEqual(Set(r.included.map(\.entry.comment)), ["A", "B", "C"])
        XCTAssertEqual(r.included.first { $0.entry.comment == "B" }?.reason, .recursion("龙"))

        var bExcluded = b; bExcluded.excludeRecursion = true
        XCTAssertEqual(Set(run([a, bExcluded, c], messages: ["我们去王都"]).included.map(\.entry.comment)), ["A"])

        var aPrevent = a; aPrevent.preventRecursion = true
        XCTAssertEqual(Set(run([aPrevent, b, c], messages: ["我们去王都"]).included.map(\.entry.comment)), ["A"])

        XCTAssertEqual(Set(run([a, b, c], messages: ["我们去王都"], recursive: false).included.map(\.entry.comment)), ["A"])
    }

    func testInclusionGroupKeepsHighestPriority() {
        let low = LoreEntry(comment: "低", keys: ["天气"], content: "晴", priority: 1, group: "weather")
        let high = LoreEntry(comment: "高", keys: ["天气"], content: "暴雨", priority: 9, group: "weather")
        let r = run([low, high], messages: ["今天天气"])
        XCTAssertEqual(r.included.map(\.entry.comment), ["高"])
        XCTAssertEqual(r.dropped.first?.reason, .group)
    }

    func testBudgetDropsLowPriorityFirstAndConstantsWin() {
        let constant = LoreEntry(comment: "常驻", content: String(repeating: "c", count: 40), constant: true, priority: 0)
        let important = LoreEntry(comment: "重要", keys: ["k"], content: String(repeating: "i", count: 40), priority: 50)
        let minor = LoreEntry(comment: "次要", keys: ["k"], content: String(repeating: "m", count: 40), priority: 5)
        let r = run([minor, important, constant], messages: ["k"], budget: 90)
        XCTAssertEqual(Set(r.included.map(\.entry.comment)), ["常驻", "重要"])
        XCTAssertEqual(r.dropped.map(\.activation.entry.comment), ["次要"])
        XCTAssertEqual(r.dropped.first?.reason, .budget)
        XCTAssertEqual(r.tokensUsed, 80)
    }

    func testOutputOrderByPositionThenInsertionOrder() {
        let e1 = LoreEntry(comment: "after-200", keys: ["x"], content: "1", insertionOrder: 200, position: .afterCharacter)
        let e2 = LoreEntry(comment: "after-10", keys: ["x"], content: "2", insertionOrder: 10, position: .afterCharacter)
        let e3 = LoreEntry(comment: "before", keys: ["x"], content: "3", insertionOrder: 999, position: .beforeCharacter)
        let e4 = LoreEntry(comment: "depth", keys: ["x"], content: "4", insertionOrder: 1, position: .atDepth)
        let r = run([e1, e2, e3, e4], messages: ["x"])
        XCTAssertEqual(r.included.map(\.entry.comment), ["before", "after-10", "after-200", "depth"])
    }

    func testStickyAndCooldownStateMachine() {
        let e = LoreEntry(comment: "粘", keys: ["火"], content: "篝火", sticky: 3, cooldown: 2)
        // 第 1 回合：关键词激活，开始粘滞
        var r = run([e], messages: ["生火"])
        XCTAssertEqual(r.included.count, 1)
        XCTAssertEqual(r.nextState.stickyRemaining[e.id], 2)
        // 第 2、3 回合：没有关键词，仍因粘滞生效
        r = run([e], messages: ["别的话题"], state: r.nextState)
        XCTAssertEqual(r.included.first?.reason, .sticky)
        r = run([e], messages: ["别的话题"], state: r.nextState)
        XCTAssertEqual(r.included.first?.reason, .sticky)
        XCTAssertNil(r.nextState.stickyRemaining[e.id])
        XCTAssertEqual(r.nextState.cooldownRemaining[e.id], 2)
        // 冷却期间，即使命中关键词也不激活
        r = run([e], messages: ["火"], state: r.nextState)
        XCTAssertTrue(r.included.isEmpty)
        r = run([e], messages: ["火"], state: r.nextState)
        XCTAssertTrue(r.included.isEmpty)
        // 冷却结束
        r = run([e], messages: ["火"], state: r.nextState)
        XCTAssertEqual(r.included.count, 1)
    }

    func testDelayConditionsAndCharacterFilter() {
        let delayed = LoreEntry(comment: "延迟", keys: ["门"], content: "门后", delay: 3)
        XCTAssertTrue(run([delayed], messages: ["门"]).included.isEmpty)
        XCTAssertEqual(run([delayed], messages: ["a", "b", "门"]).included.count, 1)

        let conditional = LoreEntry(comment: "满月", keys: ["钟声"], content: "满月夜",
                                    conditions: [StateCondition(key: "月相", op: .equals, value: "满月")])
        XCTAssertTrue(run([conditional], messages: ["钟声"], plot: ["月相": "新月"]).included.isEmpty)
        XCTAssertEqual(run([conditional], messages: ["钟声"], plot: ["月相": "满月"]).included.count, 1)

        let numeric = LoreEntry(comment: "好感", content: "信任", constant: true,
                                conditions: [StateCondition(key: "好感度", op: .greaterOrEqual, value: "5")])
        XCTAssertTrue(run([numeric], messages: [], plot: ["好感度": "3"]).included.isEmpty)
        XCTAssertEqual(run([numeric], messages: [], plot: ["好感度": "7"]).included.count, 1)

        let onlyLyon = LoreEntry(comment: "私有", content: "莱恩的秘密", constant: true, characterFilter: ["莱恩"])
        XCTAssertTrue(run([onlyLyon], messages: [], name: "艾琳").included.isEmpty)
        XCTAssertEqual(run([onlyLyon], messages: [], name: "莱恩").included.count, 1)
        var exceptLyon = onlyLyon; exceptLyon.characterFilterExclude = true
        XCTAssertEqual(run([exceptLyon], messages: [], name: "艾琳").included.count, 1)
    }

    func testDisabledAndEmptyEntriesIgnored() {
        let disabled = LoreEntry(keys: ["x"], content: "c", enabled: false)
        let empty = LoreEntry(keys: ["x"], content: "  ")
        XCTAssertTrue(run([disabled, empty], messages: ["x"]).included.isEmpty)
    }
}

final class WorldInfoFormatTests: XCTestCase {
    func testImportSillyTavernWorld() throws {
        let book = try WorldInfoFormats.importLorebook(from: Fixture.data("st_world.json"), fallbackName: "测试世界")
        XCTAssertEqual(book.name, "测试世界")
        XCTAssertEqual(book.entries.count, 3)
        let dragon = try XCTUnwrap(book.entries.first { $0.comment == "龙" })
        XCTAssertEqual(dragon.position, .atDepth)
        XCTAssertEqual(dragon.depth, 2)
        XCTAssertEqual(dragon.selectiveLogic, .andAll)
        XCTAssertEqual(dragon.secondaryKeys, ["王都"])
        XCTAssertEqual(dragon.extensions["automationId"]?.stringValue, "abc", "未知字段保留")
        let constant = try XCTUnwrap(book.entries.first { $0.constant })
        XCTAssertEqual(constant.position, .beforeCharacter)
    }

    func testSillyTavernExportRoundTrip() throws {
        let original = try WorldInfoFormats.importLorebook(from: Fixture.data("st_world.json"), fallbackName: "世界")
        let exported = try WorldInfoFormats.sillyTavernWorldData(original)
        let again = try WorldInfoFormats.importLorebook(from: exported, fallbackName: "x")
        XCTAssertEqual(again.entries.count, original.entries.count)
        for (a, b) in zip(original.entries, again.entries) {
            XCTAssertEqual(a.keys, b.keys)
            XCTAssertEqual(a.content, b.content)
            XCTAssertEqual(a.position, b.position)
            XCTAssertEqual(a.selectiveLogic, b.selectiveLogic)
            XCTAssertEqual(a.constant, b.constant)
            XCTAssertEqual(a.insertionOrder, b.insertionOrder)
        }
    }

    func testCharacterBookRoundTripKeepsMoonlitFields() throws {
        let book = Lorebook(name: "B", entries: [
            LoreEntry(comment: "e", category: .faction, keys: ["k"], content: "c", priority: 77,
                      conditions: [StateCondition(key: "章节", op: .notEquals, value: "一")])
        ])
        guard case .object(let object) = WorldInfoFormats.characterBookObject(book) else { return XCTFail() }
        let back = WorldInfoFormats.fromCharacterBook(object, fallbackName: "x")
        XCTAssertEqual(back.entries.first?.category, .faction)
        XCTAssertEqual(back.entries.first?.priority, 77)
        XCTAssertEqual(back.entries.first?.conditions.first?.op, .notEquals)
    }

    func testMoonlitNativeFormatImport() throws {
        let book = Lorebook(name: "原生", scanDepth: 7, entries: [LoreEntry(keys: ["a"], content: "b")])
        let data = try JSONEncoder().encode(book)
        let imported = try WorldInfoFormats.importLorebook(from: data)
        XCTAssertEqual(imported.scanDepth, 7)
        XCTAssertNotEqual(imported.id, book.id, "导入后应分配新 id")
    }
}
