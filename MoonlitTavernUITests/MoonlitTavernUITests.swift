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

    /// 打开「+ › 导入角色卡」，在文档选择器里找到测试角色卡并选中，确认侧栏出现新角色。
    private func importCardThroughPicker(_ app: XCUIApplication) {
        let add = element(app, "addMenu")
        guard add.waitForExistence(timeout: 10) else { log("导入角色卡：找不到「+」按钮"); return }
        add.tap()
        let item = app.buttons["导入角色卡（PNG / JSON）"]
        guard item.waitForExistence(timeout: 5) else { log("导入角色卡：菜单里没有导入项"); return }
        item.tap()
        sleep(4)
        save("12-文档选择器", app)

        // 选择器里的文件夹和文件是集合视图的单元格，标签后面会带「2 items」、日期、大小等信息，
        // 所以按前缀匹配；位置列表按完整标签匹配
        func tapFirst(_ labels: [String], prefix: Bool = false, timeout: TimeInterval = 8) -> String? {
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
        // iPad 上的选择器左侧是位置列表；有的系统版本要先点「浏览」
        _ = tapFirst(["Browse", "浏览"], timeout: 3)
        let location = tapFirst(["On My iPad", "我的 iPad", "在我的 iPad 上"])
        log("导入角色卡：位置 \(location ?? "未找到")")
        sleep(1)
        let folder = tapFirst(["月下酒馆", "MoonlitTavern"], prefix: true)
        log("导入角色卡：文件夹 \(folder ?? "未找到")")
        sleep(1)
        let file = tapFirst(["uitest-card"], prefix: true)
        log("导入角色卡：文件 \(file ?? "未找到")")
        if file == nil {
            let visible = app.cells.allElementsBoundByIndex.prefix(40).map(\.label).joined(separator: " | ")
            log("导入角色卡：当前可见文字 \(visible)")
            save("12-文档选择器-未找到文件", app)
            return
        }
        let imported = app.staticTexts["测试旅者"].waitForExistence(timeout: 15)
        log("导入角色卡：侧栏出现「测试旅者」：\(imported)")
        save("13-导入角色卡后", app)
        XCTAssertTrue(imported, "通过文档选择器导入角色卡失败")
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

        // 3. 发送消息，等待本地模型回复
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("你好，艾琳。今晚还有空房吗？")
        save("03-输入消息", app)
        let send = element(app, "sendButton")
        send.tap()
        let start = Date()
        // 生成期间出现停止按钮
        let stop = element(app, "stopButton")
        let sawStop = stop.waitForExistence(timeout: 30)
        log("生成开始（出现停止按钮）：\(sawStop)")
        sleep(3)
        save("04-生成中", app)
        // 等待生成结束：停止按钮消失、回复出现
        let deadline = Date().addingTimeInterval(Double(env["MOONLIT_GEN_TIMEOUT"] ?? "600") ?? 600)
        while Date() < deadline {
            if !stop.exists && count(app, "message-assistant") > greetings { break }
            sleep(2)
        }
        let elapsed = Date().timeIntervalSince(start)
        let replies = count(app, "message-assistant")
        let userMessages = count(app, "message-user")
        log(String(format: "生成结束，用时 %.1f 秒，助手消息数 %d", elapsed, replies))
        XCTAssertGreaterThan(replies, greetings, "没有收到本地模型的回复")
        let lastReply = app.descendants(matching: .any).matching(identifier: "message-assistant").element(boundBy: replies - 1)
        let replyText = lastReply.label
        log("回复内容：\(replyText)")
        XCTAssertFalse(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "回复为空")
        save("05-收到回复", app)

        // 4. 右侧面板
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

        // 5. 角色编辑
        let edit = element(app, "editCharacterButton")
        if edit.waitForExistence(timeout: 5) {
            edit.tap()
            sleep(1)
            save("07-角色编辑", app)
            let cancel = element(app, "editorCancel")
            if cancel.waitForExistence(timeout: 5) { cancel.tap() }
        }

        // 6. 群聊存档
        let group = element(app, "chat-row-group")
        if group.waitForExistence(timeout: 5) {
            group.tap()
            sleep(2)
            save("08-群聊存档", app)
        }

        // 7. 竖屏布局
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        save("09-竖屏", app)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)

        // 8. 退出并重新启动：聊天记录保留，模型重新加载后可以接着聊
        app.terminate()
        app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "重启后聊天输入框没有出现")
        let restoredUser = count(app, "message-user")
        let restoredReplies = count(app, "message-assistant")
        let restoredLast = restoredReplies > 0
            ? app.descendants(matching: .any).matching(identifier: "message-assistant").element(boundBy: restoredReplies - 1).label
            : ""
        log("重启后：用户消息 \(restoredUser)/\(userMessages)，助手消息 \(restoredReplies)/\(replies)，最后一条回复与重启前一致：\(restoredLast == replyText)")
        XCTAssertEqual(restoredUser, userMessages, "重启后用户消息数量不一致")
        XCTAssertEqual(restoredReplies, replies, "重启后助手消息数量不一致")
        XCTAssertEqual(restoredLast, replyText, "重启后最后一条回复内容不一致")
        save("10-重启后", app)

        composer.tap()
        composer.typeText("那就要朝钟楼的那间。")
        send.tap()
        let start2 = Date()
        _ = stop.waitForExistence(timeout: 30)
        let deadline2 = Date().addingTimeInterval(Double(env["MOONLIT_GEN_TIMEOUT"] ?? "600") ?? 600)
        while Date() < deadline2 {
            if !stop.exists && count(app, "message-assistant") > restoredReplies { break }
            sleep(2)
        }
        let replies2 = count(app, "message-assistant")
        log(String(format: "重启后继续对话：用时 %.1f 秒，助手消息数 %d", Date().timeIntervalSince(start2), replies2))
        XCTAssertGreaterThan(replies2, restoredReplies, "重启后没有收到回复")
        if replies2 > restoredReplies {
            let reply2 = app.descendants(matching: .any).matching(identifier: "message-assistant").element(boundBy: replies2 - 1)
            log("重启后回复内容：\(reply2.label)")
        }
        save("11-重启后继续对话", app)

        // 9. 通过系统文档选择器导入角色卡（App 启动时在「我的 iPad › 月下酒馆」放了 uitest-card.json）
        importCardThroughPicker(app)
        log("测试流程结束")
    }
}
