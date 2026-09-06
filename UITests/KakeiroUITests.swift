import XCTest

final class KakeiroUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-data", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
    }

    func testFirstLaunchIsEmptyAndSampleRequiresAnExplicitTap() {
        XCTAssertTrue(app.buttons["loadSample"].waitForExistence(timeout: 5))
        for title in ["ホーム", "明細", "資産", "連携", "設定"] {
            XCTAssertTrue(app.tabBars.buttons[title].exists)
        }
        selectTab("資産")
        XCTAssertTrue(app.buttons["addAccount"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["口座をまとめよう"].firstMatch.exists)
        selectTab("ホーム")
        XCTAssertTrue(app.buttons["loadSample"].exists)
        capture("はじめてのホーム")
    }

    func testSampleScreensShowAssetsTransactionsAndConnectionLimitations() {
        XCTAssertTrue(app.buttons["loadSample"].waitForExistence(timeout: 5))
        revealAndTap(app.buttons["loadSample"])
        XCTAssertTrue(app.buttons["addTransaction"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["loadSample"].exists)
        capture("サンプル_ホーム")

        selectTab("資産")
        XCTAssertTrue(app.buttons["addAccount"].waitForExistence(timeout: 5))
        capture("サンプル_資産")
        selectTab("明細")
        XCTAssertTrue(app.buttons["addTransaction"].waitForExistence(timeout: 5))
        capture("サンプル_明細")
        selectTab("連携")
        XCTAssertTrue(app.staticTexts["SBI証券"].firstMatch.waitForExistence(timeout: 5))
        assertNoConnectedClaim()
        capture("サンプル_連携")
    }

    func testAccountAndExpenseCRUDPersistAcrossRelaunch() {
        createAccount(name: "テスト生活口座", balance: "10000")
        selectTab("明細")
        app.buttons["addTransaction"].tap()
        replace(app.textFields["transactionAmount"], with: "1200")
        replace(app.textFields["transactionMerchant"], with: "テストのスーパー")
        app.buttons["saveTransaction"].tap()
        XCTAssertTrue(app.staticTexts["テストのスーパー"].firstMatch.waitForExistence(timeout: 5))
        assertNetWorth(8_800)

        relaunchPreservingData()
        selectTab("資産")
        XCTAssertTrue(app.staticTexts["テスト生活口座"].firstMatch.waitForExistence(timeout: 5))
        selectTab("明細")
        let row = app.staticTexts["テストのスーパー"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.textFields["transactionAmount"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["transactionAmount"].value as? String, "1200")
        replace(app.textFields["transactionAmount"], with: "1500")
        replace(app.textFields["transactionMerchant"], with: "修正後のスーパー")
        app.buttons["saveTransaction"].tap()
        assertNetWorth(8_500)

        relaunchPreservingData()
        selectTab("明細")
        let editedRow = app.staticTexts["修正後のスーパー"].firstMatch
        XCTAssertTrue(editedRow.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["テストのスーパー"].exists)
        editedRow.tap()
        XCTAssertEqual(app.textFields["transactionAmount"].value as? String, "1500")
        revealAndTap(app.buttons["deleteTransaction"])
        confirmDeletion()
        XCTAssertTrue(editedRow.waitForNonExistence(timeout: 5))

        relaunchPreservingData()
        selectTab("明細")
        XCTAssertFalse(app.staticTexts["修正後のスーパー"].exists)
        assertNetWorth(10_000)
        selectTab("資産")
        XCTAssertTrue(app.staticTexts["テスト生活口座"].firstMatch.exists)
        app.staticTexts["テスト生活口座"].firstMatch.tap()
        XCTAssertTrue(app.textFields["accountName"].waitForExistence(timeout: 5))
        replace(app.textFields["accountName"], with: "修正後の生活口座")
        app.buttons["saveAccount"].tap()

        relaunchPreservingData()
        selectTab("資産")
        let editedAccount = app.staticTexts["修正後の生活口座"].firstMatch
        XCTAssertTrue(editedAccount.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["テスト生活口座"].exists)
        editedAccount.tap()
        revealAndTap(app.buttons["deleteAccount"])
        confirmDeletion()
        XCTAssertTrue(editedAccount.waitForNonExistence(timeout: 5))

        relaunchPreservingData()
        selectTab("資産")
        XCTAssertFalse(app.staticTexts["修正後の生活口座"].exists)
        XCTAssertTrue(app.staticTexts["口座をまとめよう"].firstMatch.exists)
    }

    func testMonthlyBudgetPersistsAfterRelaunch() {
        selectTab("設定")
        replace(app.textFields["monthlyBudget"], with: "123456")
        revealAndTap(app.buttons["saveBudget"])
        relaunchPreservingData()
        selectTab("設定")
        let field = app.textFields["monthlyBudget"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "123456")
    }

    func testRequestedInstitutionsAreCataloguedWithoutPretendingToConnect() {
        selectTab("連携")
        for institution in ["SBI証券", "楽天証券", "楽天銀行", "三井住友銀行", "三菱UFJ銀行", "ゆうちょ銀行"] {
            let name = app.staticTexts[institution].firstMatch
            reveal(name)
            XCTAssertTrue(name.exists, "Missing institution: \(institution)")
        }
        assertNoConnectedClaim()
        XCTAssertEqual(app.secureTextFields.count, 0)
    }

    func testSecuritiesValuationCanBeCancelledAndPersistsOnlyAfterSave() {
        revealAndTap(app.buttons["loadSample"])
        selectTab("資産")
        revealAndTap(app.staticTexts["つみたて・投資"].firstMatch)
        revealAndTap(app.buttons["現在の評価額を更新"])
        replace(app.textFields["評価額（円）"], with: "3000000")
        app.buttons["口座の入力に反映"].tap()
        XCTAssertEqual(app.textFields["openingBalance"].value as? String, "3000000")
        app.buttons["キャンセル"].tap()

        revealAndTap(app.staticTexts["つみたて・投資"].firstMatch)
        XCTAssertEqual(app.textFields["openingBalance"].value as? String, "2520000")
        revealAndTap(app.buttons["現在の評価額を更新"])
        replace(app.textFields["評価額（円）"], with: "3000000")
        app.buttons["口座の入力に反映"].tap()
        app.buttons["saveAccount"].tap()
        relaunchPreservingData()
        selectTab("資産")
        revealAndTap(app.staticTexts["つみたて・投資"].firstMatch)
        XCTAssertEqual(app.textFields["openingBalance"].value as? String, "3000000")
    }

    private func createAccount(name: String, balance: String) {
        selectTab("資産")
        app.buttons["addAccount"].tap()
        replace(app.textFields["accountName"], with: name)
        replace(app.textFields["institutionName"], with: "テスト銀行")
        replace(app.textFields["openingBalance"], with: balance)
        app.buttons["saveAccount"].tap()
        XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 5))
    }

    private func selectTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
    }

    private func assertNoConnectedClaim() {
        for claim in ["連携済み", "接続済み", "同期完了", "認証成功"] {
            XCTAssertFalse(app.staticTexts[claim].exists, "An unconfigured institution must not claim: \(claim)")
        }
    }

    private func assertNetWorth(_ expected: Int) {
        selectTab("ホーム")
        let value = app.staticTexts["netWorth"]
        reveal(value)
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertEqual(Int(value.label.filter(\.isNumber)), expected)
    }

    private func replace(_ field: XCUIElement, with value: String) {
        revealAndTap(field)
        let current = field.value as? String ?? ""
        // Tap the field's trailing edge so its existing value is before the caret.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + value)
        XCTAssertEqual(field.value as? String, value)
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeDown()
        }
    }

    private func revealAndTap(_ element: XCUIElement) {
        reveal(element)
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        element.tap()
    }

    private func confirmDeletion() {
        let confirmation = app.buttons["削除"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
    }

    private func relaunchPreservingData() {
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-data" }
        app.launch()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
