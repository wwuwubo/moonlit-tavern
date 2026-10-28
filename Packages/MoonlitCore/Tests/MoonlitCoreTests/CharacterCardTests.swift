import XCTest
@testable import MoonlitCore

final class CharacterCardTests: XCTestCase {
    func testImportV2JSONKeepsAllFields() throws {
        let result = try CharacterCardCodec.importCard(from: Fixture.data("card_v2.json"))
        let c = result.character
        XCTAssertEqual(result.specVersion, "v2")
        XCTAssertEqual(c.name, "Seraphine")
        XCTAssertTrue(c.description.contains("cartographer"))
        XCTAssertEqual(c.personality, "curious, dry humor, patient")
        XCTAssertTrue(c.scenario.contains("rooftop"))
        XCTAssertTrue(c.firstMessage.hasPrefix("*Seraphine"))
        XCTAssertEqual(c.alternateGreetings.count, 1)
        XCTAssertEqual(ExampleDialogue.blocks(from: c.exampleDialogue).count, 2)
        XCTAssertTrue(c.systemPrompt.contains("{{original}}"))
        XCTAssertEqual(c.postHistoryInstructions, "Stay in character as {{char}}.")
        XCTAssertEqual(c.tags, ["fantasy", "night"])
        XCTAssertEqual(c.creator, "tester")
        XCTAssertEqual(c.characterVersion, "1.2")
        XCTAssertEqual(c.talkativeness, 0.7, accuracy: 0.0001)
        // 未知扩展字段原样保留
        XCTAssertEqual(c.extensions["custom_tool"]?["theme"]?.stringValue, "midnight")
        XCTAssertNotNil(c.extensions["depth_prompt"])
        // 内嵌世界书
        let book = try XCTUnwrap(c.characterBook)
        XCTAssertEqual(book.name, "Night City")
        XCTAssertEqual(book.scanDepth, 3)
        XCTAssertEqual(book.tokenBudget, 400)
        XCTAssertEqual(book.entries.count, 2)
        XCTAssertEqual(book.entries[0].keys, ["rooftop", "roof"])
        XCTAssertEqual(book.entries[0].sticky, 2)
        XCTAssertEqual(book.entries[1].position, .beforeCharacter)
        XCTAssertTrue(book.entries[1].selective)
        XCTAssertEqual(book.entries[1].secondaryKeys, ["price", "cost"])
    }

    func testImportV1FlatJSON() throws {
        let result = try CharacterCardCodec.importCard(from: Fixture.data("card_v1.json"))
        XCTAssertEqual(result.specVersion, "v1")
        XCTAssertEqual(result.character.name, "老周")
        XCTAssertEqual(result.character.firstMessage, "客官里边请，今天讲一段新的。")
        XCTAssertTrue(result.character.exampleDialogue.contains("且听下回分解"))
    }

    func testImportTavernAIAliases() throws {
        let c = try CharacterCardCodec.importCard(from: Fixture.data("card_tavernai.json")).character
        XCTAssertEqual(c.name, "Mira")
        XCTAssertEqual(c.description, "A quiet librarian.")
        XCTAssertEqual(c.scenario, "An old library at closing time.")
        XCTAssertEqual(c.firstMessage, "We're closing soon.")
    }

    func testImportV3PreservesUnknownFieldsOnReexport() throws {
        let json = """
        {"spec":"chara_card_v3","spec_version":"3.0","data":{
          "name":"Vex","description":"d","personality":"p","scenario":"s","first_mes":"hi","mes_example":"",
          "creator_notes":"","system_prompt":"","post_history_instructions":"","alternate_greetings":[],
          "tags":[],"creator":"","character_version":"","extensions":{},
          "nickname":"V","group_only_greetings":["g1"],"assets":[{"type":"icon","uri":"ccdefault:","name":"main","ext":"png"}],
          "creation_date": 1700000000}}
        """
        let result = try CharacterCardCodec.importCard(from: Data(json.utf8))
        XCTAssertEqual(result.specVersion, "v3")
        XCTAssertEqual(result.character.nickname, "V")
        let exported = try CharacterCardCodec.exportJSON(result.character, v3: true)
        let root = try JSONDecoder().decode(JSONValue.self, from: exported)
        XCTAssertEqual(root["spec"]?.stringValue, "chara_card_v3")
        XCTAssertEqual(root["data"]?["group_only_greetings"]?.arrayValue?.first?.stringValue, "g1")
        XCTAssertEqual(root["data"]?["assets"]?.arrayValue?.count, 1)
        XCTAssertNotNil(root["data"]?["creation_date"])
        // V2 导出不应带 V3 专有字段
        let v2 = try JSONDecoder().decode(JSONValue.self, from: CharacterCardCodec.exportJSON(result.character))
        XCTAssertNil(v2["data"]?["assets"])
    }

    func testPNGRoundTripIsLossless() throws {
        var c = TavernCharacter(name: "艾琳")
        c.description = "酒馆老板娘"
        c.background = "曾是密探"
        c.speakingStyle = "说话简短"
        c.personality = "嘴硬心软"
        c.firstMessage = "这么晚还在外面晃？"
        c.alternateGreetings = ["打烊了……算了。"]
        c.tags = ["示例"]
        c.talkativeness = 0.25
        c.extensions = ["other_app": .object(["x": .number(1)])]
        c.characterBook = Lorebook(name: "月下镇", entries: [
            LoreEntry(uid: 3, comment: "钟楼", category: .location, keys: ["钟楼"], content: "满月敲十三下",
                      insertionOrder: 60, priority: 30, position: .atDepth, depth: 2, sticky: 1, cooldown: 2,
                      conditions: [StateCondition(key: "月相", op: .equals, value: "满月")])
        ])

        let png = try CharacterCardCodec.exportPNG(c, basePNG: nil)
        XCTAssertTrue(PNGChunks.isPNG(png))
        // CRC 全部正确
        XCTAssertNoThrow(try PNGChunks.readChunks(png, verifyCRC: true))
        let texts = try PNGChunks.textEntries(png)
        XCTAssertNotNil(texts["chara"])
        XCTAssertNotNil(texts["ccv3"])

        let back = try CharacterCardCodec.importCard(from: png)
        let r = back.character
        XCTAssertEqual(back.specVersion, "v3")
        XCTAssertEqual(r.name, c.name)
        XCTAssertEqual(r.description, c.description, "拆开的字段应从扩展里恢复")
        XCTAssertEqual(r.background, c.background)
        XCTAssertEqual(r.speakingStyle, c.speakingStyle)
        XCTAssertEqual(r.personality, c.personality)
        XCTAssertEqual(r.alternateGreetings, c.alternateGreetings)
        XCTAssertEqual(r.talkativeness, 0.25, accuracy: 0.0001)
        XCTAssertEqual(r.extensions["other_app"]?["x"]?.intValue, 1)
        let entry = try XCTUnwrap(r.characterBook?.entries.first)
        XCTAssertEqual(entry.keys, ["钟楼"])
        XCTAssertEqual(entry.category, .location)
        XCTAssertEqual(entry.position, .atDepth)
        XCTAssertEqual(entry.depth, 2)
        XCTAssertEqual(entry.sticky, 1)
        XCTAssertEqual(entry.cooldown, 2)
        XCTAssertEqual(entry.priority, 30)
        XCTAssertEqual(entry.conditions, [StateCondition(key: "月相", op: .equals, value: "满月")])

        // 其他客户端只读 V2 时，description 里含背景和说话风格
        let v2Data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(texts["chara"])))
        let v2 = try JSONDecoder().decode(JSONValue.self, from: v2Data)
        let mergedDescription = try XCTUnwrap(v2["data"]?["description"]?.stringValue)
        XCTAssertTrue(mergedDescription.contains("曾是密探"))
        XCTAssertTrue(mergedDescription.contains("说话简短"))
    }

    func testPNGWithOnlyCharaChunkAndExistingAvatar() throws {
        let avatar = SolidPNG.make(width: 8, height: 8, r: 200, g: 10, b: 10)
        let json = try CharacterCardCodec.exportJSON(TavernCharacter(name: "Solo", description: "x"))
        let png = try PNGChunks.writingTextEntries([("chara", json.base64EncodedString())], into: avatar)
        let result = try CharacterCardCodec.importCard(from: png)
        XCTAssertEqual(result.character.name, "Solo")
        XCTAssertEqual(result.avatarPNG, png)
        // 原图的 IHDR/IDAT 被保留
        let types = try PNGChunks.readChunks(png).map(\.type)
        XCTAssertEqual(types.first, "IHDR")
        XCTAssertTrue(types.contains("IDAT"))
        XCTAssertEqual(types.last, "IEND")
    }

    func testRewritingReplacesOldCardChunks() throws {
        let first = try CharacterCardCodec.exportPNG(TavernCharacter(name: "A"), basePNG: nil)
        let second = try CharacterCardCodec.exportPNG(TavernCharacter(name: "B"), basePNG: first)
        let charaChunks = try PNGChunks.readChunks(second).filter { $0.type == "tEXt" }
        XCTAssertEqual(charaChunks.count, 2, "旧的 chara/ccv3 应被替换，不应重复")
        XCTAssertEqual(try CharacterCardCodec.importCard(from: second).character.name, "B")
    }

    func testErrors() {
        XCTAssertThrowsError(try CharacterCardCodec.importCard(from: SolidPNG.make(width: 2, height: 2, r: 0, g: 0, b: 0))) { error in
            XCTAssertEqual((error as? CharacterCardCodec.CardError)?.errorDescription, CharacterCardCodec.CardError.noCardData.errorDescription)
        }
        XCTAssertThrowsError(try CharacterCardCodec.importCard(from: Data("not json".utf8)))
        XCTAssertThrowsError(try CharacterCardCodec.importCard(from: Data(#"{"description":"no name"}"#.utf8)))
    }

    func testCRC32KnownValue() {
        // "IEND" 的 CRC 是 PNG 规范里的固定值 0xAE426082
        XCTAssertEqual(CRC32.checksum(Array("IEND".utf8)), 0xAE42_6082)
    }
}
