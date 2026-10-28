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

    func testLocalRoleplayEndToEnd() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MOONLIT_UITEST"] = "1"
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
        log(String(format: "生成结束，用时 %.1f 秒，助手消息数 %d", elapsed, replies))
        XCTAssertGreaterThan(replies, greetings, "没有收到本地模型的回复")
        let lastReply = app.descendants(matching: .any).matching(identifier: "message-assistant").element(boundBy: replies - 1)
        log("回复内容：\(lastReply.label)")
        XCTAssertFalse(lastReply.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "回复为空")
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
        log("测试流程结束")
    }
}
