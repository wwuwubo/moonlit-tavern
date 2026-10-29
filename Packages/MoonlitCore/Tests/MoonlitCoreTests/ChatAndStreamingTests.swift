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

    // MARK: 吞回复的几种情形

    func testUnclosedThinkingIsReleasedAsText() {
        var f = StreamingTextFilter(stopSequences: [], hideThinking: true)
        var out = ""
        for piece in ["<think>", "她放下酒杯，", "笑了笑。"] { out += f.feed(piece) }
        XCTAssertEqual(out, "", "思考段未闭合前不显示")
        out += f.finish()
        XCTAssertEqual(out, "她放下酒杯，笑了笑。", "直到结束都没闭合的思考段要当正文放出")
        XCTAssertTrue(f.unclosedThinking)
    }

    func testThinkTagInMiddleDoesNotHideRest() {
        var f = StreamingTextFilter(stopSequences: [], hideThinking: true)
        var out = ""
        for piece in ["二楼还有", "一间。<thi", "nk>窗户朝着钟楼", "。</think>别开窗。"] { out += f.feed(piece) }
        out += f.finish()
        XCTAssertEqual(out, "二楼还有一间。窗户朝着钟楼。别开窗。")
        XCTAssertFalse(f.unclosedThinking)
    }

    func testLoneClosingTagKeepsPrecedingText() {
        var f = StreamingTextFilter(stopSequences: [], hideThinking: true)
        var out = ""
        for piece in ["她叹了口气。", "</thi", "nk>", "说吧。"] { out += f.feed(piece) }
        out += f.finish()
        XCTAssertEqual(out, "她叹了口气。说吧。")
    }

    func testStartsInsideThinkingWhenTemplateOpenedIt() {
        var f = StreamingTextFilter(stopSequences: [], hideThinking: true, startsInsideThinking: true)
        var out = ""
        for piece in ["用户在问房间", "</think>\n\n", "有一间。"] { out += f.feed(piece) }
        out += f.finish()
        XCTAssertEqual(out, "有一间。")
        XCTAssertGreaterThan(f.hiddenThinkingCount, 0)
    }

    func testLeadingWhitespaceBeforeThinkBlock() {
        var f = StreamingTextFilter(stopSequences: [], hideThinking: true)
        var out = ""
        for piece in ["\n", " <think>", "想一想</think>", "好。"] { out += f.feed(piece) }
        out += f.finish()
        XCTAssertEqual(out, "好。")
    }

    func testLongReplyStreamsCompletely() {
        var f = StreamingTextFilter(stopSequences: ["\n旅人：", "\n旅人:"], hideThinking: true)
        let sentence = "她把灯芯挑亮了一些，*目光落在窗外的钟楼上*，“今晚风大，别乱跑。”\n"
        var out = ""
        for _ in 0..<200 {
            for ch in sentence { out += f.feed(String(ch)) }
        }
        out += f.finish()
        XCTAssertEqual(out, String(repeating: sentence, count: 200))
        XCTAssertFalse(f.stopped)
    }

    func testFinalizerKeepsVisibleTextWhenCleaningEmptiesIt() {
        // 正常情况
        let normal = ReplyFinalizer.finalize(visible: "  艾琳：你好  ", speakerName: "艾琳")
        XCTAssertEqual(normal.content, "你好")
        XCTAssertFalse(normal.usedFallback)
        // 只有空白或孤零零的符号：确实没有可保存的内容
        XCTAssertEqual(ReplyFinalizer.finalize(visible: "  \n ", speakerName: "艾琳").content, "")
        XCTAssertEqual(ReplyFinalizer.finalize(visible: "*", speakerName: "艾琳").content, "")
        let line = normal.logLine(stopReason: "自然结束", saved: true, error: nil)
        XCTAssertTrue(line.contains("显示 9 字") && line.contains("已保存 2 字"), line)
    }

    func testSanitizer() {
        XCTAssertEqual(ResponseSanitizer.clean("  艾琳：你好  ", speakerName: "艾琳"), "你好")
        XCTAssertEqual(ResponseSanitizer.clean("<think>x</think>\n回答", speakerName: "A"), "回答")
        XCTAssertEqual("<think>先想想</think>\n答".strippingThinkBlocks(), "\n答")
        // 孤立的结束标签只删标签，不能把前面的正文一起删掉
        XCTAssertEqual("她笑了。</think>坐吧。".strippingThinkBlocks(), "她笑了。坐吧。")
        XCTAssertEqual(ResponseSanitizer.clean("*她笑了。* 要是敢在满月那*", speakerName: "A"), "*她笑了。* 要是敢在满月那")
        XCTAssertEqual(ResponseSanitizer.clean("*她笑了。*", speakerName: "A"), "*她笑了。*")
        XCTAssertEqual(ResponseSanitizer.clean("好。*她伸手勾了勾门框", speakerName: "A"), "好。*她伸手勾了勾门框*")
        XCTAssertEqual(ResponseSanitizer.clean("清单：\n* 第一项", speakerName: "A"), "清单：\n* 第一项", "列表标记不补星号")
        XCTAssertEqual(ResponseSanitizer.clean("**重点** 还有", speakerName: "A"), "**重点** 还有")
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
