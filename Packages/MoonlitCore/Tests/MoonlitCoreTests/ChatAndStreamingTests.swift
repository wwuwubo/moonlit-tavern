import XCTest
@testable import MoonlitCore

final class ChatTreeTests: XCTestCase {
    func testAppendSiblingsSwitchAndDelete() {
        var s = ChatSession(title: "t", characterIDs: [UUID()])
        let greet = s.append(ChatMessage(role: .assistant, speakerName: "A", content: "g"))
        let u1 = s.append(ChatMessage(role: .user, speakerName: "U", content: "u1"))
        let a1 = s.append(ChatMessage(role: .assistant, speakerName: "A", content: "a1", createdAt: Date(timeIntervalSinceNow: 1)))
        XCTAssertEqual(s.activePath().map(\.content), ["g", "u1", "a1"])

        // 重新生成：同父的兄弟
        let a1b = s.addSibling(ChatMessage(role: .assistant, speakerName: "A", content: "a1b", createdAt: Date(timeIntervalSinceNow: 2)), siblingOf: a1.id)!
        XCTAssertEqual(s.activePath().map(\.content), ["g", "u1", "a1b"])
        XCTAssertEqual(s.siblingPosition(of: a1b.id).index, 2)
        XCTAssertEqual(s.siblingPosition(of: a1b.id).count, 2)

        s.switchSibling(of: a1b.id, offset: -1)
        XCTAssertEqual(s.activePath().last?.content, "a1")
        s.switchSibling(of: a1.id, offset: -1) // 越界无效
        XCTAssertEqual(s.activePath().last?.content, "a1")

        // 在 a1 下继续，再切回 a1b，再切回 a1 时应走到 a1 分支的最新叶子
        _ = s.append(ChatMessage(role: .user, speakerName: "U", content: "u2", createdAt: Date(timeIntervalSinceNow: 3)))
        s.switchSibling(of: a1.id, offset: 1)
        XCTAssertEqual(s.activePath().last?.content, "a1b")
        s.switchSibling(of: a1b.id, offset: -1)
        XCTAssertEqual(s.activePath().last?.content, "u2")

        // 删除 a1：子树一起删除，活动路径回到兄弟
        s.deleteMessage(a1.id)
        XCTAssertFalse(s.messages.contains { $0.content == "u2" })
        XCTAssertEqual(s.activePath().map(\.content), ["g", "u1", "a1b"])

        // 删除唯一的分支后回到父消息
        s.deleteMessage(a1b.id)
        XCTAssertEqual(s.activeLeafID, u1.id)
        XCTAssertEqual(s.activePath().first?.id, greet.id)
    }

    func testEditHideAndFork() {
        var s = ChatSession(title: "t", characterIDs: [UUID()], plotState: ["章节": "一"])
        let m1 = s.append(ChatMessage(role: .assistant, speakerName: "A", content: "1"))
        let m2 = s.append(ChatMessage(role: .user, speakerName: "U", content: "2"))
        _ = s.append(ChatMessage(role: .assistant, speakerName: "A", content: "3"))
        s.editMessage(m2.id, content: "二")
        XCTAssertEqual(s.message(m2.id)?.content, "二")
        XCTAssertNotNil(s.message(m2.id)?.editedAt)
        s.setHidden(m1.id, hidden: true)
        XCTAssertTrue(s.message(m1.id)!.isHidden)

        let fork = s.forked(at: m2.id, title: "分支")!
        XCTAssertEqual(fork.activePath().map(\.content), ["1", "二"])
        XCTAssertNotEqual(fork.messages.first?.id, m1.id, "分支使用新的消息 id")
        XCTAssertEqual(fork.activePath().last?.parentID, fork.activePath().first?.id)
        XCTAssertEqual(fork.plotState["章节"], "一")
        XCTAssertEqual(s.activePath().count, 3, "原存档不受影响")
    }
}

final class StreamingTests: XCTestCase {
    func testUTF8AccumulatorHandlesSplitCharacters() {
        var acc = UTF8Accumulator()
        let bytes = Array("月光🌙".utf8) // 3 + 3 + 4 字节
        var out = ""
        for b in bytes { out += acc.append([b]) }
        out += acc.flush()
        XCTAssertEqual(out, "月光🌙")

        var acc2 = UTF8Accumulator()
        XCTAssertEqual(acc2.append(Array(bytes[0..<2])), "")
        XCTAssertEqual(acc2.append(Array(bytes[2..<5])), "月")
        XCTAssertEqual(acc2.append(Array(bytes[5...])), "光🌙")
    }

    func testStopSequenceAcrossChunks() {
        var f = StreamingTextFilter(stopSequences: ["\n旅人："], hideThinking: true)
        var out = ""
        for piece in ["你好", "，旅人", "。\n", "旅", "人：我来替你说"] {
            out += f.feed(piece)
        }
        out += f.finish()
        XCTAssertEqual(out, "你好，旅人。")
        XCTAssertTrue(f.stopped)
        XCTAssertEqual(f.matchedStop, "\n旅人：")
    }

    func testHeldTextReleasedWhenNotStop() {
        var f = StreamingTextFilter(stopSequences: ["<|im_end|>"])
        var out = f.feed("价格是 <")
        XCTAssertEqual(out, "价格是 ", "可能是停止词开头的 < 先扣住")
        out += f.feed("5 枚金币")
        XCTAssertEqual(out, "价格是 <5 枚金币")
        out += f.finish()
        XCTAssertEqual(f.visibleText, "价格是 <5 枚金币")
    }

    func testThinkingHidden() {
        var f = StreamingTextFilter(stopSequences: [], hideThinking: true)
        var out = ""
        for piece in ["<thi", "nk>先想想", "……</th", "ink>", "正文"] { out += f.feed(piece) }
        out += f.finish()
        XCTAssertEqual(out, "正文")
    }

    func testSanitizer() {
        XCTAssertEqual(ResponseSanitizer.clean("  艾琳：你好  ", speakerName: "艾琳"), "你好")
        XCTAssertEqual(ResponseSanitizer.clean("<think>x</think>\n回答", speakerName: "A"), "回答")
        XCTAssertEqual("思考中</think>答".strippingThinkBlocks(), "答")
        XCTAssertEqual(ResponseSanitizer.clean("*她笑了。* 要是敢在满月那*", speakerName: "A"), "*她笑了。* 要是敢在满月那")
        XCTAssertEqual(ResponseSanitizer.clean("*她笑了。*", speakerName: "A"), "*她笑了。*")
        XCTAssertEqual(ResponseSanitizer.clean("好。*她伸手勾了勾门框", speakerName: "A"), "好。*她伸手勾了勾门框*")
        XCTAssertEqual(ResponseSanitizer.clean("清单：\n* 第一项", speakerName: "A"), "清单：\n* 第一项", "列表标记不补星号")
        XCTAssertEqual(ResponseSanitizer.clean("**重点** 还有", speakerName: "A"), "**重点** 还有")
    }
}

final class SuggestedActionTests: XCTestCase {
    func testParsesFourDistinctContextActions() {
        let raw = """
        1. 询问掌门关于灵网的秘密
        2、检查古老的封印阵法
        3. 沿着山道寻找失踪的弟子
        4. 留在道院研究玉简
        """
        XCTAssertEqual(ActionSuggestionParser.parse(raw), [
            "询问掌门关于灵网的秘密", "检查古老的封印阵法",
            "沿着山道寻找失踪的弟子", "留在道院研究玉简"
        ])
    }

    func testIgnoreInvalidAndDuplicateOptions() {
        let raw = """
        你可以考虑这些行动：
        1. 询问线索
        2. 询问线索
        - 观察四周
        3. \(String(repeating: "长", count: 81))
        4. 返回山门
        """
        XCTAssertEqual(ActionSuggestionParser.parse(raw), [
            "询问线索", "观察四周", "返回山门"
        ])
    }
}

final class GroupDirectorTests: XCTestCase {
    func testStrategies() {
        let a = TavernCharacter(name: "艾琳", talkativeness: 0.9)
        let b = TavernCharacter(name: "莱恩", talkativeness: 0.1)
        let c = TavernCharacter(name: "米拉")
        var s = ChatSession(title: "g", characterIDs: [a.id, b.id, c.id], turnOrder: .roundRobin)
        s.append(ChatMessage(role: .assistant, speakerID: a.id, speakerName: "艾琳", content: "hi"))
        let chars = [a, b, c]
        XCTAssertEqual(GroupDirector.nextSpeaker(in: s, characters: chars)?.name, "莱恩")

        s.append(ChatMessage(role: .user, speakerName: "旅人", content: "米拉，你来说"))
        XCTAssertEqual(GroupDirector.nextSpeaker(in: s, characters: chars, strategy: .natural)?.name, "米拉")

        s.append(ChatMessage(role: .user, speakerName: "旅人", content: "大家好"))
        // 自然顺序：没被点名时选最久没说话的（莱恩、米拉都没说过，按顺序取莱恩）
        XCTAssertEqual(GroupDirector.nextSpeaker(in: s, characters: chars, strategy: .natural)?.name, "莱恩")
        XCTAssertNil(GroupDirector.nextSpeaker(in: s, characters: chars, strategy: .manual))
        // 加权随机不会选上一个发言者
        for r in stride(from: 0.0, to: 1.0, by: 0.1) {
            XCTAssertNotEqual(GroupDirector.nextSpeaker(in: s, characters: chars, strategy: .weightedRandom, random: { r })?.name, "艾琳")
        }
    }
}

final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let text = """
        # 标题
        *她笑了笑。* "坐吧。"

        - 第一项
        * 第二项
        1. 编号
        > 引用
        ---
        ```swift
        let x = 1
        ```
        """
        let blocks = MarkdownParser.blocks(text)
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "标题"))
        XCTAssertEqual(blocks[1], .paragraph("*她笑了笑。* \"坐吧。\""), "动作描写不能被当成列表")
        XCTAssertEqual(blocks[2], .listItem(ordered: false, marker: "•", text: "第一项"))
        XCTAssertEqual(blocks[3], .listItem(ordered: false, marker: "•", text: "第二项"))
        XCTAssertEqual(blocks[4], .listItem(ordered: true, marker: "1.", text: "编号"))
        XCTAssertEqual(blocks[5], .quote("引用"))
        XCTAssertEqual(blocks[6], .divider)
        XCTAssertEqual(blocks[7], .code(language: "swift", text: "let x = 1"))
    }
}
