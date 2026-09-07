import Foundation
import XCTest
@testable import KakeiroCore

final class KakeiroCoreTests: XCTestCase {
    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func bank(balance: Int64 = 100_000) -> LedgerAccount {
        LedgerAccount(name: "生活用口座", institution: "テスト銀行", kind: .bank, openingBalance: balance)
    }

    private func expense(account: LedgerAccount, amount: Int64 = 1_000, date: Date? = nil,
                         category: ExpenseCategory = .food, merchant: String = "スーパー", note: String = "") -> LedgerTransaction {
        LedgerTransaction(accountID: account.id, kind: .expense, amount: amount,
                          date: date ?? self.date("2026-09-05T03:00:00Z"), category: category, merchant: merchant, note: note)
    }

    func testCardPurchaseAndRepaymentOnlyCountExpenseOnce() throws {
        let bank = bank()
        let card = LedgerAccount(name: "カード", institution: "テストカード", kind: .creditCard, openingBalance: -20_000)
        let purchase = expense(account: card, amount: 3_000)
        let payment = LedgerTransaction(accountID: bank.id, kind: .transfer, amount: 23_000,
                                        date: purchase.date, merchant: "カード引落", destinationAccountID: card.id)
        let beforePayment = LedgerState(accounts: [bank, card], transactions: [purchase])
        let afterPayment = LedgerState(accounts: [bank, card], transactions: [purchase, payment])
        try LedgerValidation.validate(afterPayment)
        XCTAssertEqual(FinanceCalculator.balance(for: card, in: beforePayment), -23_000)
        XCTAssertEqual(FinanceCalculator.balance(for: card, in: afterPayment), 0)
        XCTAssertEqual(FinanceCalculator.balance(for: bank, in: afterPayment), 77_000)
        XCTAssertEqual(FinanceCalculator.netWorth(in: beforePayment), FinanceCalculator.netWorth(in: afterPayment))
        XCTAssertEqual(FinanceCalculator.monthlyExpense(in: afterPayment, month: purchase.date), 3_000)
        XCTAssertEqual(FinanceCalculator.monthlyIncome(in: afterPayment, month: purchase.date), 0)
        XCTAssertEqual(FinanceCalculator.categoryExpenses(in: afterPayment, month: purchase.date), [.food: 3_000])
    }

    func testTokyoMonthIncludesUTCPreviousDayAndExcludesFollowingMonth() {
        let account = bank()
        let entries = [
            expense(account: account, amount: 100, date: date("2026-08-31T14:59:59Z")),
            expense(account: account, amount: 200, date: date("2026-08-31T15:00:00Z")),
            expense(account: account, amount: 400, date: date("2026-09-30T14:59:59Z")),
            expense(account: account, amount: 800, date: date("2026-09-30T15:00:00Z"))
        ]
        let state = LedgerState(accounts: [account], transactions: entries)
        let month = date("2026-09-15T00:00:00Z")
        XCTAssertEqual(FinanceCalculator.monthlyExpense(in: state, month: month), 600)
        XCTAssertEqual(FinanceCalculator.transactions(in: state, month: month).map(\.id), [entries[2].id, entries[1].id])
    }

    func testNegativeNetWorthAndPositiveCardRefundBalance() {
        let account = bank(balance: 10_000)
        let card = LedgerAccount(name: "カード", institution: "カード会社", kind: .creditCard, openingBalance: -40_000)
        var state = LedgerState(accounts: [account, card])
        XCTAssertEqual(FinanceCalculator.netWorth(in: state), -30_000)
        XCTAssertEqual(FinanceCalculator.totalAssets(in: state), 10_000)
        XCTAssertEqual(FinanceCalculator.totalLiabilities(in: state), 40_000)
        state.transactions = [LedgerTransaction(accountID: card.id, kind: .income, amount: 45_000,
                                               date: date("2026-09-01T03:00:00Z"), merchant: "返金")]
        XCTAssertEqual(FinanceCalculator.totalAssets(in: state), 15_000)
        XCTAssertEqual(FinanceCalculator.totalLiabilities(in: state), 0)
        XCTAssertEqual(FinanceCalculator.netWorth(in: state), 15_000)
    }

    func testSampleIsValidAndAccountingBalances() throws {
        let now = date("2026-09-06T03:00:00Z")
        let state = SampleData.make(now: now)
        try LedgerValidation.validate(state)
        XCTAssertEqual(state.accounts.count, 4)
        XCTAssertEqual(FinanceCalculator.netWorth(in: state), 4_575_570)
        XCTAssertEqual(FinanceCalculator.totalAssets(in: state), 4_609_880)
        XCTAssertEqual(FinanceCalculator.totalLiabilities(in: state), 34_310)
        XCTAssertEqual(FinanceCalculator.monthlyIncome(in: state, month: now), 345_000)
        XCTAssertEqual(FinanceCalculator.monthlyExpense(in: state, month: now), 124_830)
        XCTAssertEqual(FinanceCalculator.categoryExpenses(in: state, month: now).values.reduce(0, +), 124_830)
    }

    func testValidationRejectsDuplicateAndMissingAccountIDs() {
        let account = bank()
        XCTAssertThrowsError(try LedgerValidation.validate(LedgerState(accounts: [account, account])))
        let entry = expense(account: account)
        XCTAssertThrowsError(try LedgerValidation.validate(LedgerState(transactions: [entry])))
        XCTAssertThrowsError(try LedgerValidation.validate(LedgerState(accounts: [account], transactions: [entry, entry])))
    }

    func testValidationRejectsBadTransferDestinations() {
        let account = bank()
        let destination = bank()
        for target in [nil, account.id, UUID()] as [UUID?] {
            let transfer = LedgerTransaction(accountID: account.id, kind: .transfer, amount: 1,
                                             merchant: "振替", destinationAccountID: target)
            XCTAssertThrowsError(try LedgerValidation.validate(LedgerState(accounts: [account, destination], transactions: [transfer])))
        }
        var nonTransfer = expense(account: account)
        nonTransfer.destinationAccountID = destination.id
        XCTAssertThrowsError(try LedgerValidation.validate(LedgerState(accounts: [account, destination], transactions: [nonTransfer])))
    }

    func testValidationRejectsOutOfRangeAmountsAndDates() throws {
        let account = bank()
        for amount: Int64 in [0, -1, .max, .min, LedgerValidation.maximumAmount + 1] {
            let entry = expense(account: account, amount: amount)
            XCTAssertThrowsError(try LedgerValidation.validate(LedgerState(accounts: [account], transactions: [entry])))
        }
        for openingBalance: Int64 in [.min, .max] {
            XCTAssertThrowsError(try LedgerValidation.validate(LedgerState(accounts: [bank(balance: openingBalance)])))
        }
        for invalidDate in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity), date("1899-12-31T03:00:00Z")] {
            XCTAssertThrowsError(try LedgerValidation.validate(LedgerState(accounts: [account], transactions: [expense(account: account, date: invalidDate)])))
        }
        XCTAssertThrowsError(try LedgerValidation.validate(LedgerState(monthlyBudget: -1)))
        XCTAssertThrowsError(try LedgerValidation.validate(LedgerState(schemaVersion: 2))) { error in
            XCTAssertEqual(error as? FinanceError, .unsupportedSchema(2))
        }
        try LedgerValidation.validate(LedgerState(accounts: [account], transactions: [expense(account: account, amount: LedgerValidation.maximumAmount)]))
    }

    func testValidationRejectsBlankAndOversizedText() {
        var account = bank()
        account.name = " \n "
        XCTAssertThrowsError(try LedgerValidation.validate(LedgerState(accounts: [account])))
        account.name = String(repeating: "あ", count: 101)
        XCTAssertThrowsError(try LedgerValidation.validate(LedgerState(accounts: [account])))
        account.name = "口座"
        XCTAssertThrowsError(try LedgerValidation.validate(LedgerState(accounts: [account], transactions: [expense(account: account, merchant: " ")])))
        XCTAssertThrowsError(try LedgerValidation.validate(LedgerState(accounts: [account], transactions: [expense(account: account, note: "bad\u{0000}text")])))
    }

    func testRepositoryRoundTripAndInvalidSavePreservesExistingData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KakeiroTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/ledger.json")
        let repository = LedgerRepository(fileURL: url)
        XCTAssertEqual(try repository.load(), .empty)
        let state = SampleData.make(now: date("2026-09-06T03:00:00Z"))
        try repository.save(state)
        XCTAssertEqual(try repository.load(), state)
        let original = try Data(contentsOf: url)
        var invalid = state
        invalid.transactions[0].amount = -1
        XCTAssertThrowsError(try repository.save(invalid))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try repository.load(), state)
    }

    func testCorruptedRepositoryFailsWithoutReplacingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KakeiroTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("ledger.json")
        let badData = Data("{broken}".utf8)
        try badData.write(to: url)
        XCTAssertThrowsError(try LedgerRepository(fileURL: url).load()) { error in
            XCTAssertEqual(error as? FinanceError, .corruptedFile)
        }
        XCTAssertEqual(try Data(contentsOf: url), badData)
    }

    func testRepositoryWriteFailureDoesNotDamageParentFile() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("KakeiroTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: parent) }
        let original = Data("existing file".utf8)
        try original.write(to: parent)
        let repository = LedgerRepository(fileURL: parent.appendingPathComponent("ledger.json"))
        XCTAssertThrowsError(try repository.save(.empty)) { error in
            XCTAssertEqual(error as? FinanceError, .fileWriteFailed)
        }
        XCTAssertEqual(try Data(contentsOf: parent), original)
    }

    func testCSVQuotedCommaNewlineAndEscapedQuotesRoundTrip() throws {
        let account = bank()
        let csv = "date,type,amount,category,merchant,note\r\n2026-09-01,expense,1280,food,\"スーパー,駅前\",\"パン\"\"特売\"\"\n食材\"\r\n2026-09-02,income,300000,salary,給与,\r\n"
        let imported = try CSVImporter.importTransactions(text: csv, accountID: account.id, into: LedgerState(accounts: [account]))
        XCTAssertEqual(imported.transactions.count, 2)
        XCTAssertEqual(imported.transactions[0].merchant, "スーパー,駅前")
        XCTAssertEqual(imported.transactions[0].note, "パン\"特売\"\n食材")
        XCTAssertEqual(imported.transactions[1].kind, .income)
        let exported = try CSVExporter.transactions(in: imported)
        let again = try CSVImporter.importTransactions(text: exported, accountID: account.id, into: LedgerState(accounts: [account]))
        XCTAssertEqual(again.transactions.map(\.merchant), imported.transactions.map(\.merchant))
        XCTAssertEqual(again.transactions.map(\.note), imported.transactions.map(\.note))
        XCTAssertEqual(again.transactions.map(\.amount), imported.transactions.map(\.amount))
    }

    func testCSVReimportSkipsDuplicatesWithinFileAndAcrossImports() throws {
        let account = bank()
        let row = "2026-09-05,expense,1000,food,スーパー,\n"
        let csv = "date,type,amount,category,merchant,note\n" + row + row
        let initial = LedgerState(accounts: [account])
        let first = try CSVImporter.importTransactions(text: csv, accountID: account.id, into: initial)
        XCTAssertEqual(first.transactions.count, 1)
        let second = try CSVImporter.importTransactions(text: csv, accountID: account.id, into: first)
        XCTAssertEqual(second, first)
        let existingManual = LedgerState(accounts: [account], transactions: [expense(account: account, date: date("2026-09-05T12:34:56Z"))])
        XCTAssertEqual(try CSVImporter.importTransactions(text: csv, accountID: account.id, into: existingManual), existingManual)
    }

    func testCSVSameRowInDifferentAccountIsPreserved() throws {
        let first = bank()
        let second = bank()
        let csv = "date,type,amount,category,merchant,note\n2026-09-05,expense,1000,food,スーパー,\n"
        let state = LedgerState(accounts: [first, second], transactions: [expense(account: first)])
        let imported = try CSVImporter.importTransactions(text: csv, accountID: second.id, into: state)
        XCTAssertEqual(imported.transactions.count, 2)
        XCTAssertEqual(imported.transactions.last?.accountID, second.id)
    }

    func testCSVInvalidRowsRejectEntireImport() throws {
        let account = bank()
        let state = LedgerState(accounts: [account], transactions: [expense(account: account)])
        let header = "date,type,amount,category,merchant,note\n"
        let valid = "2026-09-01,expense,2000,food,スーパー,\n"
        let invalidRows = [
            "2026-02-29,expense,100,food,店,",
            "2026-09-31,expense,100,food,店,",
            "2026-9-01,expense,100,food,店,",
            "2026-09-01,transfer,100,food,店,",
            "2026-09-01,expense,-100,food,店,",
            "2026-09-01,expense,100.5,food,店,",
            "2026-09-01,expense,0,food,店,",
            "2026-09-01,expense,9223372036854775808,food,店,",
            "2026-09-01,expense,100,unknown,店,",
            "2026-09-01,expense,100,food,店",
            "2026-09-01,expense,100,food,店,,extra",
            "2026-09-01,expense,100,food,\"店,",
            "2026-09-01,expense,100,food,店\"x,",
            "2026-09-01,expense,100,food,\"店\"x,"
        ]
        for invalid in invalidRows {
            XCTAssertThrowsError(try CSVImporter.importTransactions(text: header + valid + invalid, accountID: account.id, into: state), invalid)
            XCTAssertEqual(state.transactions.count, 1)
        }
        XCTAssertThrowsError(try CSVImporter.importTransactions(text: "wrong,header\n", accountID: account.id, into: state))
        XCTAssertThrowsError(try CSVImporter.importTransactions(text: header, accountID: account.id, into: state))
        XCTAssertThrowsError(try CSVImporter.importTransactions(text: header + valid, accountID: UUID(), into: state))
    }

    func testCSVLeapDateJapaneseLabelsAndBOM() throws {
        let account = bank()
        let csv = "\u{FEFF}date,type,amount,category,merchant,note\r\n2024-02-29,支出,100,食費,お店,\"\"\r\n"
        let state = try CSVImporter.importTransactions(text: csv, accountID: account.id, into: LedgerState(accounts: [account]))
        XCTAssertEqual(state.transactions.first?.date, date("2024-02-29T03:00:00Z"))
        XCTAssertEqual(state.transactions.first?.category, .food)
        XCTAssertEqual(state.transactions.first?.note, "")
    }

    func testCSVExportExcludesTransfers() throws {
        let state = SampleData.make(now: date("2026-09-06T03:00:00Z"))
        let csv = try CSVExporter.transactions(in: state)
        XCTAssertFalse(csv.contains(",transfer,"))
        let account = bank()
        let imported = try CSVImporter.importTransactions(text: csv, accountID: account.id, into: LedgerState(accounts: [account]))
        XCTAssertEqual(imported.transactions.count, state.transactions.filter { $0.kind != .transfer }.count)
    }
}
