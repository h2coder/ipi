import XCTest

final class AIAssistantAppUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCapitalAndGreatWallChatFlow() throws {
        let app = self.launchApp()

        XCTAssertTrue(app.buttons["quickPromptCapital"].waitForExistence(timeout: 10))
        app.buttons["quickPromptCapital"].tap()
        XCTAssertTrue(self.waitForSendButtonToEnable(in: app, timeout: 10))
        app.buttons["sendButton"].tap()

        XCTAssertTrue(
            app.staticTexts.matching(identifier: "messageBubble_user-0").firstMatch.waitForExistence(timeout: 10)
        )

        let capitalReply = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "北京")
        ).firstMatch
        XCTAssertTrue(capitalReply.waitForExistence(timeout: 120))

        app.buttons["quickPromptGreatWall"].tap()
        XCTAssertTrue(self.waitForSendButtonToEnable(in: app, timeout: 10))
        app.buttons["sendButton"].tap()

        XCTAssertTrue(
            app.staticTexts.matching(identifier: "messageBubble_user-2").firstMatch.waitForExistence(timeout: 10)
        )

        let affirmativeReply = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "是", "北京")
        ).firstMatch
        XCTAssertTrue(affirmativeReply.waitForExistence(timeout: 120))
    }

    @MainActor
    func testChuShiBiaoStreamsIncrementally() throws {
        let app = self.launchApp()

        XCTAssertTrue(app.buttons["quickPromptChuShiBiao"].waitForExistence(timeout: 10))
        app.buttons["quickPromptChuShiBiao"].tap()
        XCTAssertTrue(self.waitForSendButtonToEnable(in: app, timeout: 10))
        app.buttons["sendButton"].tap()

        let streamingStatus = app.staticTexts["AI 正在回复…"]
        XCTAssertTrue(streamingStatus.waitForExistence(timeout: 20))

        let streamingReply = app.staticTexts.matching(identifier: "messageBubble_assistant-1").element(boundBy: 1)
        XCTAssertTrue(self.waitForNonEmptyLabel(on: streamingReply, timeout: 120))

        let initialLength = streamingReply.label.trimmingCharacters(in: .whitespacesAndNewlines).count
        XCTAssertGreaterThan(initialLength, 0)

        XCTAssertTrue(
            self.waitForLabelGrowth(
                on: streamingReply,
                beyond: initialLength,
                while: streamingStatus,
                timeout: 120
            )
        )

        XCTAssertTrue(self.waitForElementToDisappear(streamingStatus, timeout: 120))
        XCTAssertGreaterThan(
            streamingReply.label.trimmingCharacters(in: .whitespacesAndNewlines).count,
            initialLength
        )
    }

    @MainActor
    func testArithmeticToolCallFlow() throws {
        let app = self.launchApp(autoQuery: "99*2+2")

        XCTAssertTrue(
            app.staticTexts.matching(identifier: "messageBubble_user-0").firstMatch.waitForExistence(timeout: 10)
        )

        let toolResult = app.staticTexts.containing(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
                "messageBubble_tool-",
                "DEBUG toolCall triggered",
                "tool: calculate_arithmetic",
                "arguments.expression: 99*2+2",
                "result: 200"
            )
        ).firstMatch
        XCTAssertTrue(toolResult.waitForExistence(timeout: 120))

        let finalAnswer = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS %@", "200", "结果:")
        ).firstMatch
        XCTAssertTrue(finalAnswer.waitForExistence(timeout: 120))
    }

    @MainActor
    private func launchApp(autoQuery: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        if let autoQuery {
            app.launchArguments += ["--auto-query", autoQuery]
        }
        app.launch()
        return app
    }

    private func waitForNonEmptyLabel(
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists,
               !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private func waitForSendButtonToEnable(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let sendButton = app.buttons["sendButton"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sendButton.exists, sendButton.isEnabled {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private func waitForLabelGrowth(
        on element: XCUIElement,
        beyond baselineCount: Int,
        while statusElement: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let currentCount = element.label.trimmingCharacters(in: .whitespacesAndNewlines).count
            if statusElement.exists, currentCount > baselineCount {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private func waitForElementToDisappear(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
