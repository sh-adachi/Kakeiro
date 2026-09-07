import XCTest

final class SyncUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        _ = control("reset", method: "POST")
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-data", "--sync-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
    }

    func testForegroundImportManualRefreshCorrectionDeletionAndFailurePreservation() {
        assertNetWorth(95_000)
        XCTAssertEqual(control("state")["requests"] as? Int, 0, "Opening the app reads the server cache without spending a provider refresh.")
        app.tabBars.buttons["明細"].tap()
        XCTAssertTrue(app.staticTexts["取消前の明細"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["同期テストのスーパー"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["自動取得した明細"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["transactionAmount"].exists)
        XCTAssertFalse(app.buttons["deleteTransaction"].exists)
        app.buttons["閉じる"].tap()

        app.tabBars.buttons["ホーム"].tap()
        let refresh = app.buttons["refreshAccounts"].firstMatch
        XCTAssertTrue(refresh.isEnabled)
        refresh.tap()
        assertNetWorth(126_000)
        XCTAssertEqual(control("state")["requests"] as? Int, 1)
        app.tabBars.buttons["明細"].tap()
        XCTAssertTrue(app.staticTexts["同期テストのスーパー"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "同期テストのスーパー").count, 1)
        XCTAssertFalse(app.staticTexts["取消前の明細"].exists)
        app.tabBars.buttons["資産"].tap()
        app.staticTexts["連携テスト銀行"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["自動取得した口座"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["saveAccount"].exists)
        app.buttons["閉じる"].tap()

        app.tabBars.buttons["ホーム"].tap()
        refresh.tap()
        waitForRefresh()
        assertNetWorth(126_000)
        XCTAssertEqual(control("state")["requests"] as? Int, 2)
        let lastSuccess = app.staticTexts["lastSync"].label
        _ = control("fail", method: "POST")
        refresh.tap()
        XCTAssertTrue(app.staticTexts["syncError"].waitForExistence(timeout: 10))
        assertNetWorth(126_000)
        XCTAssertEqual(app.staticTexts["lastSync"].label, lastSuccess)

        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-data" }
        app.launch()
        assertNetWorth(126_000)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "自動連携_架空データ"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertNetWorth(_ expected: Int) {
        let value = app.staticTexts["netWorth"]
        let predicate = NSPredicate { _, _ in
            value.exists && Int(value.label.filter(\.isNumber)) == expected
        }
        expectation(for: predicate, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
    }

    private func waitForRefresh() {
        let button = app.buttons["refreshAccounts"].firstMatch
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button)
        waitForExpectations(timeout: 15)
    }

    @discardableResult
    private func control(_ path: String, method: String = "GET") -> [String: Any] {
        let finished = expectation(description: "Local fixture responds")
        var result: [String: Any] = [:]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8779/_test/" + path)!)
        request.httpMethod = method
        request.setValue("Bearer kakeiro-uitest-only-token-not-for-production", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, response, error in
            XCTAssertNil(error, "Start Scripts/sync_ui_fixture.py before running sync UI tests.")
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            if let data { result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
            finished.fulfill()
        }.resume()
        waitForExpectations(timeout: 10)
        return result
    }
}
