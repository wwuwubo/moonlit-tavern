import XCTest

/// 端到端 UI 测试：在 iPad 模拟器上启动真实 App，用真实 GGUF 模型完成一轮本地角色扮演。
/// 模型目录通过环境变量 MOONLIT_MODEL_DIR 传入（xcodebuild 的 TEST_RUNNER_ 前缀），
/// 截图写入 SCREENSHOT_DIR，供 CI 收集。
final class MoonlitTavernUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = true
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["SCREENSHOT_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? shot.pngRepresentation.write(to: url)
        }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func count(_ app: XCUIApplication, _ id: String) -> Int {
        app.descendants(matching: .any).matching(identifier: id).count
    }

    private func log(_ text: String) {
        print("[UITest] \(text)")
        if let dir = env["SCREENSHOT_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("uitest-steps.txt")
            let line = text + "\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - 通用步骤

    private var genTimeout: TimeInterval { Double(env["MOONLIT_GEN_TIMEOUT"] ?? "600") ?? 600 }

    private func messages(_ app: XCUIApplication, _ role: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "message-\(role)")
    }

    /// 等回复生成完：停止按钮消失、助手消息数超过 before。返回用时与新的消息数。
    private func waitForReply(_ app: XCUIApplication, after before: Int) -> (TimeInterval, Int) {
        let start = Date()
        let stop = element(app, "stopButton")
        _ = stop.waitForExistence(timeout: 30)
        let deadline = Date().addingTimeInterval(genTimeout)
        while Date() < deadline {
            if !stop.exists && count(app, "message-assistant") > before { break }
            sleep(2)
        }
        return (Date().timeIntervalSince(start), count(app, "message-assistant"))
    }

    private func suggestionLabels(_ app: XCUIApplication) -> [String] {
        (0..<4).compactMap { i in
            let e = element(app, "suggestion-\(i)")
            return e.exists ? e.label : nil
        }
    }

    /// 等剧情选项出现（生成中提示消失且至少有两个选项）。
    private func waitForSuggestions(_ app: XCUIApplication, timeout: TimeInterval = 120) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let labels = suggestionLabels(app)
            if labels.count >= 2 && !element(app, "suggestionsWorking").exists { return labels }
            sleep(2)
        }
        return suggestionLabels(app)
    }

    private func openCardImport(_ app: XCUIApplication) -> Bool {
        let add = element(app, "addMenu")
        guard add.waitForExistence(timeout: 10) else { log("导入：找不到「+」按钮"); return false }
        add.tap()
        let item = element(app, "importCardMenuItem")
        guard item.waitForExistence(timeout: 5) else { log("导入：菜单里没有导入项"); return false }
        item.tap()
        // 导入页最上面的按钮；下面的按钮可能在屏幕外，列表还没创建它们
        return element(app, "readCardClipboardButton").waitForExistence(timeout: 10)
    }

    /// 从「我的 iPad › 月下酒馆 › 角色卡」文件夹列表导入（不经过系统文件选择器）。
    private func importCardFromFolder(_ app: XCUIApplication) {
        XCTAssertTrue(openCardImport(app), "导入界面没有打开")
        let row = element(app, "folder-card-uitest-card.json")
        let listed = row.waitForExistence(timeout: 10)
        log("文件夹导入：列表里有 uitest-card.json：\(listed)")
        save("12-导入界面", app)
        XCTAssertTrue(listed, "角色卡文件夹列表里没有测试卡")
        guard listed else { return }
        row.tap()
        let imported = app.staticTexts["测试旅者"].waitForExistence(timeout: 15)
        log("文件夹导入：侧栏出现「测试旅者」：\(imported)")
        XCTAssertTrue(imported, "从文件夹导入角色卡失败")
    }

    /// 通过系统文档选择器导入：我的 iPad › 月下酒馆 › 角色卡 › 测试卡。
    /// button 是导入页上的哪个按钮（UIKit 选择器或备用的 SwiftUI 选择器）。
    private func importCardThroughPicker(_ app: XCUIApplication, button: String, file fileName: String,
                                         character: String, shot: String, tag: String) {
        XCTAssertTrue(openCardImport(app), "导入界面没有打开")
        let pickButton = element(app, button)
        for _ in 0..<4 where !pickButton.isHittable { app.swipeUp() }
        log("\(tag)：按钮可点 \(pickButton.isHittable)")
        pickButton.tap()
        sleep(4)
        save("\(shot)-文档选择器", app)

        // 选择器里的文件夹和文件是集合视图的单元格，标签后面会带「2 items」、日期、大小等信息，
        // 所以按前缀匹配；位置列表按完整标签匹配
        func tapFirst(_ labels: [String], prefix: Bool = false, timeout: TimeInterval = 10) -> String? {
            let deadline = Date().addingTimeInterval(timeout)
            let format = prefix ? "label BEGINSWITH %@" : "label == %@"
            while Date() < deadline {
                for label in labels {
                    let queries = prefix ? [app.cells] : [app.cells, app.staticTexts, app.buttons]
                    for query in queries {
                        let e = query.matching(NSPredicate(format: format, label)).firstMatch
                        if e.exists && e.isHittable {
                            let found = e.label   // 点击后界面会跳转，先记下标签
                            e.tap()
                            return found
                        }
                    }
                }
                sleep(1)
            }
            return nil
        }
        // 第二次打开选择器时，它会停在上次的文件夹里，先看看文件是不是已经在眼前
        var file = tapFirst([fileName], prefix: true, timeout: 3)
        if file == nil {
            _ = tapFirst(["Browse", "浏览"], timeout: 3)
            let location = tapFirst(["On My iPad", "我的 iPad", "在我的 iPad 上"])
            log("\(tag)：位置 \(location ?? "未找到")")
            sleep(1)
            let appFolder = tapFirst(["月下酒馆", "MoonlitTavern"], prefix: true)
            log("\(tag)：App 文件夹 \(appFolder ?? "未找到")")
            sleep(1)
            let cardFolder = tapFirst(["角色卡"], prefix: true)
            log("\(tag)：角色卡文件夹 \(cardFolder ?? "未找到")")
            sleep(1)
            file = tapFirst([fileName], prefix: true)
        }
        log("\(tag)：文件 \(file ?? "未找到")")
        if file == nil {
            // 界面层级快照（逐个读取单元格在界面变化时会失败，所以整体取一次）
            log("\(tag)：界面层级 \(String(app.debugDescription.prefix(3000)))")
            save("\(shot)-文档选择器-未找到文件", app)
        }
        let imported = app.staticTexts[character].waitForExistence(timeout: 15)
        log("\(tag)：侧栏出现「\(character)」：\(imported)")
        save("\(shot)-选择器导入后", app)
        XCTAssertTrue(imported, "\(tag)失败")
    }

    // MARK: - 测试

    /// 独立于文件选择器的集成测试：输入真实 V2 JSON，确认出现新角色。
    func testPasteJSONCharacterCard() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MOONLIT_UITEST"] = "1"
        app.launchEnvironment["MOONLIT_UITEST_RUN"] = UUID().uuidString
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()

        let add = element(app, "addMenu")
        XCTAssertTrue(add.waitForExistence(timeout: 15), "未找到新增菜单")
        add.tap()
        let pasteItem = element(app, "pasteCardMenuItem")
        XCTAssertTrue(pasteItem.waitForExistence(timeout: 10), "缺少粘贴 JSON 入口")
        pasteItem.tap()

        let editor = element(app, "cardJSONEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "粘贴导入界面没有文本输入框")
        editor.tap()
        editor.typeText(#"{"spec":"chara_card_v2","spec_version":"2.0","data":{"name":"ClipboardCardSmoke","description":"smoke test","personality":"calm","scenario":"test","first_mes":"hello"}}"#)
        let importButton = element(app, "confirmPasteCardImport")
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "缺少确认导入按钮")
        XCTAssertTrue(importButton.isEnabled, "输入 JSON 后导入按钮仍被禁用")
        importButton.tap()
        let name = app.staticTexts["ClipboardCardSmoke"]
        XCTAssertTrue(name.waitForExistence(timeout: 15), "导入后侧栏没有显示 ClipboardCardSmoke")
        save("clipboard-json-card-imported", app)

        // 重新启动后角色还在
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["ClipboardCardSmoke"].waitForExistence(timeout: 15), "重启后粘贴导入的角色不见了")
        log("粘贴导入：重启后角色仍在")
    }

    func testLocalRoleplayEndToEnd() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MOONLIT_UITEST"] = "1"
        app.launchEnvironment["MOONLIT_UITEST_RUN"] = UUID().uuidString
        app.launchEnvironment["MOONLIT_MAX_TOKENS"] = env["MOONLIT_MAX_TOKENS"] ?? "48"
        app.launchEnvironment["MOONLIT_CONTEXT"] = env["MOONLIT_CONTEXT"] ?? "2048"
        if let dir = env["MOONLIT_MODEL_DIR"] {
            app.launchEnvironment["MOONLIT_EXTRA_MODEL_DIR"] = dir
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()

        // 1. 启动：示例数据、聊天界面
        let composer = element(app, "composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "聊天输入框没有出现")
        let greetings = count(app, "message-assistant")
        log("启动完成，开场白消息数 \(greetings)")
        XCTAssertGreaterThanOrEqual(greetings, 1, "示例存档应有开场白")
        save("01-启动-示例存档", app)

        // 2. 设置 → 模型管理：模型被识别
        element(app, "settingsButton").tap()
        let manager = element(app, "modelManagerLink")
        XCTAssertTrue(manager.waitForExistence(timeout: 10))
        manager.tap()
        let modelRow = element(app, "model-row")
        let hasModel = modelRow.waitForExistence(timeout: 30)
        log("模型管理页识别到模型：\(hasModel)")
        XCTAssertTrue(hasModel, "模型管理页没有列出测试模型")
        if hasModel { modelRow.tap() }
        sleep(1)
        save("02-模型管理", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let done = element(app, "settingsDone")
        if done.waitForExistence(timeout: 5) { done.tap() }

        // 3. 自由输入并发送，等待本地模型回复
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("你好，艾琳。今晚还有空房吗？")
        save("03-输入消息", app)
        let send = element(app, "sendButton")
        send.tap()
        sleep(3)
        save("04-生成中", app)
        let (elapsed, replies) = waitForReply(app, after: greetings)
        let userMessages = count(app, "message-user")
        log(String(format: "生成结束，用时 %.1f 秒，助手消息数 %d", elapsed, replies))
        XCTAssertGreaterThan(replies, greetings, "没有收到本地模型的回复")
        let replyText = messages(app, "assistant").element(boundBy: replies - 1).label
        log("回复内容：\(replyText)")
        XCTAssertFalse(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "回复为空")
        save("05-收到回复", app)

        // 4. 剧情选项：回复后自动出现
        let options1 = waitForSuggestions(app)
        log("剧情选项：\(options1.map { "「\($0)」" }.joined(separator: " "))")
        XCTAssertGreaterThanOrEqual(options1.count, 2, "回复后没有出现剧情选项")
        save("05b-剧情选项", app)

        // 5. 换一组：选项更新，角色回复不变
        let refresh = element(app, "refreshSuggestions")
        XCTAssertTrue(refresh.waitForExistence(timeout: 10), "没有「换一组选项」按钮")
        refresh.tap()
        let sawWorking = element(app, "suggestionsWorking").waitForExistence(timeout: 10)
        let options2 = waitForSuggestions(app)
        let replyAfterRefresh = messages(app, "assistant").element(boundBy: replies - 1).label
        log("换一组：出现生成提示 \(sawWorking)，新选项 \(options2.map { "「\($0)」" }.joined(separator: " "))，与上一组不同：\(options2 != options1)，回复未变：\(replyAfterRefresh == replyText)")
        XCTAssertTrue(sawWorking, "点「换一组」后没有开始生成")
        XCTAssertGreaterThanOrEqual(options2.count, 2, "换一组后没有选项")
        XCTAssertEqual(count(app, "message-assistant"), replies, "换一组不应新增或删除回复")
        XCTAssertEqual(replyAfterRefresh, replyText, "换一组改动了角色回复")
        save("05c-换一组", app)

        // 6. 右侧面板
        let tabs = element(app, "inspectorTabs")
        if tabs.waitForExistence(timeout: 5) {
            for tab in ["上下文", "世界书", "记忆", "参数", "角色"] {
                let button = tabs.buttons[tab]
                if button.exists {
                    button.tap()
                    sleep(1)
                    save("06-面板-\(tab)", app)
                }
            }
        } else {
            log("右侧面板未显示")
        }

        // 7. 角色编辑
        let edit = element(app, "editCharacterButton")
        if edit.waitForExistence(timeout: 5) {
            edit.tap()
            sleep(1)
            save("07-角色编辑", app)
            let cancel = element(app, "editorCancel")
            if cancel.waitForExistence(timeout: 5) { cancel.tap() }
        }

        // 8. 群聊存档
        let group = element(app, "chat-row-group")
        if group.waitForExistence(timeout: 5) {
            group.tap()
            sleep(2)
            save("08-群聊存档", app)
        }

        // 9. 竖屏布局
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        save("09-竖屏", app)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)

        // 10. 退出并重新启动：聊天记录和剧情选项都保留
        app.terminate()
        app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "重启后聊天输入框没有出现")
        let restoredUser = count(app, "message-user")
        let restoredReplies = count(app, "message-assistant")
        let restoredLast = restoredReplies > 0 ? messages(app, "assistant").element(boundBy: restoredReplies - 1).label : ""
        let restoredOptions = waitForSuggestions(app, timeout: 10)
        log("重启后：用户消息 \(restoredUser)/\(userMessages)，助手消息 \(restoredReplies)/\(replies)，最后一条回复与重启前一致：\(restoredLast == replyText)，选项与重启前一致：\(restoredOptions == options2)")
        XCTAssertEqual(restoredUser, userMessages, "重启后用户消息数量不一致")
        XCTAssertEqual(restoredReplies, replies, "重启后助手消息数量不一致")
        XCTAssertEqual(restoredLast, replyText, "重启后最后一条回复内容不一致")
        XCTAssertEqual(restoredOptions, options2, "重启后剧情选项不一致")
        save("10-重启后", app)

        // 11. 点一个选项：作为用户消息发出，模型接着回复，新回复下面又有选项
        let pick = element(app, "suggestion-0")
        XCTAssertTrue(pick.waitForExistence(timeout: 10), "重启后找不到选项")
        let picked = pick.label
        pick.tap()
        let (elapsed2, replies2) = waitForReply(app, after: restoredReplies)
        let users2 = count(app, "message-user")
        let lastUser = users2 > 0 ? messages(app, "user").element(boundBy: users2 - 1).label : ""
        log(String(format: "点选项「%@」后：用时 %.1f 秒，用户消息 %d，助手消息 %d", picked, elapsed2, users2, replies2))
        XCTAssertEqual(users2, restoredUser + 1, "点选项后没有发出用户消息")
        XCTAssertTrue(lastUser.contains(String(picked.prefix(6))), "发出的用户消息与所选选项不一致：\(lastUser)")
        XCTAssertGreaterThan(replies2, restoredReplies, "点选项后没有收到回复")
        if replies2 > restoredReplies {
            log("选项之后的回复：\(messages(app, "assistant").element(boundBy: replies2 - 1).label)")
        }
        let options3 = waitForSuggestions(app)
        log("新回复的剧情选项：\(options3.map { "「\($0)」" }.joined(separator: " "))")
        XCTAssertGreaterThanOrEqual(options3.count, 2, "新回复下没有剧情选项")
        save("11-点选项后继续", app)

        // 12. 重新生成：保留旧版本，可以左右切换
        let regenerate = element(app, "regenerateButton")
        XCTAssertTrue(regenerate.waitForExistence(timeout: 10), "没有「重新生成」按钮")
        regenerate.tap()
        let stop = element(app, "stopButton")
        _ = stop.waitForExistence(timeout: 30)
        let deadline = Date().addingTimeInterval(genTimeout)
        while Date() < deadline && stop.exists { sleep(2) }
        let switcher = app.staticTexts["2/2"].waitForExistence(timeout: 15)
        log("重新生成：出现版本切换「2/2」：\(switcher)，助手消息 \(count(app, "message-assistant"))")
        XCTAssertTrue(switcher, "重新生成后没有保留旧版本")
        XCTAssertEqual(count(app, "message-assistant"), replies2, "重新生成应替换显示的版本，而不是追加一条")
        save("11b-重新生成", app)

        // 12b. 继续：测试里回复上限只有 48 token，回复多半停在长度上限；继续后内容接在同一条回复后面
        let beforeCount = count(app, "message-assistant")
        let beforeText = messages(app, "assistant").element(boundBy: beforeCount - 1).label
        let truncated = element(app, "truncatedHint").exists
        let continueButton = element(app, "continueButton")
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10), "没有「继续」按钮")
        continueButton.tap()
        _ = stop.waitForExistence(timeout: 30)
        let continueDeadline = Date().addingTimeInterval(genTimeout)
        while Date() < continueDeadline && stop.exists { sleep(2) }
        sleep(1)
        let afterCount = count(app, "message-assistant")
        let afterText = afterCount > 0 ? messages(app, "assistant").element(boundBy: afterCount - 1).label : ""
        log("继续：截断提示 \(truncated)，续写前 \(beforeText.count) 字，续写后 \(afterText.count) 字，助手消息 \(beforeCount) → \(afterCount)")
        log("继续后的回复：\(afterText)")
        XCTAssertEqual(afterCount, beforeCount, "继续应写进同一条回复，不新增消息")
        if truncated {
            XCTAssertGreaterThan(afterText.count, beforeText.count, "停在长度上限的回复，继续后没有变长")
        }
        XCTAssertTrue(afterText.hasPrefix(String(beforeText.prefix(8))), "继续后回复开头变了")
        XCTAssertTrue(app.staticTexts["2/2"].exists, "继续不应产生新版本")
        save("11c-继续", app)

        // 13. 导入角色卡：App 文件夹、系统文档选择器、备用选择器
        importCardFromFolder(app)
        importCardThroughPicker(app, button: "pickCardFileButton", file: "uitest-picker",
                                character: "选择器旅者", shot: "13", tag: "选择器导入")
        importCardThroughPicker(app, button: "pickCardFileButtonAlt", file: "uitest-alt",
                                character: "备用旅者", shot: "13c", tag: "备用选择器导入")

        // 14. 再次重启：导入的角色仍在
        app.terminate()
        app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "第二次重启后聊天输入框没有出现")
        let keptFolder = app.staticTexts["测试旅者"].waitForExistence(timeout: 15)
        let keptPicker = app.staticTexts["选择器旅者"].waitForExistence(timeout: 5)
        let keptAlt = app.staticTexts["备用旅者"].waitForExistence(timeout: 5)
        log("第二次重启后：「测试旅者」\(keptFolder)，「选择器旅者」\(keptPicker)，「备用旅者」\(keptAlt)")
        XCTAssertTrue(keptFolder && keptPicker && keptAlt, "重启后导入的角色不见了")
        save("14-重启后导入的角色", app)
        log("测试流程结束")
    }
}
