import Foundation
import XCTest
@testable import KakeiroCore

final class SyncTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-06T03:00:00Z")!

    private func account(id: String = "bank:123", balance: Int64 = 100_000,
                         kind: AccountKind = .bank) -> SyncedAccount {
        SyncedAccount(id: id, name: "生活口座", institution: "テスト銀行", kind: kind,
                      balance: balance, balanceUpdatedAt: now)
    }

    private func transaction(id: String = "bank:tx1", accountID: String = "bank:123",
                             amount: Int64 = 1_000, kind: TransactionKind = .expense,
                             excluded: Bool = false, reversal: Bool = false) -> SyncedTransaction {
        SyncedTransaction(id: id, accountID: accountID, kind: kind, amount: amount, date: now,
                          category: .food, merchant: "スーパー", excludedFromCashFlow: excluded, isReversal: reversal)
    }

    private func snapshot(accounts: [SyncedAccount]? = nil, transactions: [SyncedTransaction]? = nil,
                          revision: Int = 1) -> SyncSnapshot {
        SyncSnapshot(revision: revision, generatedAt: now, lastSuccessfulSync: now,
                     accounts: accounts ?? [account()], transactions: transactions ?? [transaction()])
    }

    private func merge(_ snapshot: SyncSnapshot, into state: LedgerState = .empty) throws -> LedgerState {
        try SyncMerger.apply(snapshot: snapshot, to: state, now: now)
    }

    func testRepeatedSnapshotPreservesEveryUUIDAndIsIdempotent() throws {
        let first = try merge(snapshot())
        let second = try merge(snapshot(), into: first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.lastSyncAt, now)
        XCTAssertEqual(first.syncRevision, 1)
        XCTAssertEqual(first.accounts[0].remote?.externalID, "bank:123")
        XCTAssertEqual(first.transactions[0].remote?.externalID, "bank:tx1")
    }

    func testRevisionUpdatesAmountAndRemovesMissingImportedTransactionWhilePreservingManualData() throws {
        let manual = LedgerAccount(name: "現金", institution: "", kind: .cash, openingBalance: 10_000)
        let manualEntry = LedgerTransaction(accountID: manual.id, kind: .expense, amount: 200, date: now, merchant: "自販機")
        let initial = LedgerState(accounts: [manual], transactions: [manualEntry], monthlyBudget: 95_000)
        var first = try merge(snapshot(transactions: [transaction(), transaction(id: "bank:deleted")]), into: initial)
        let linkedIndex = try XCTUnwrap(first.accounts.firstIndex(where: { $0.remote != nil }))
        first.accounts[linkedIndex].note = "残しておくメモ"
        first.transactions[1].note = "補足"
        let originalImportedID = first.transactions[1].id
        let revised = snapshot(accounts: [account(balance: 98_000)], transactions: [transaction(amount: 2_000)], revision: 2)
        let result = try merge(revised, into: first)
        XCTAssertEqual(result.accounts.count, 2)
        XCTAssertEqual(result.accounts[0], manual)
        XCTAssertEqual(result.accounts[linkedIndex].id, first.accounts[linkedIndex].id)
        XCTAssertEqual(result.accounts[linkedIndex].note, "残しておくメモ")
        XCTAssertEqual(result.transactions.count, 2)
        XCTAssertEqual(result.transactions[0], manualEntry)
        XCTAssertEqual(result.transactions[1].id, originalImportedID)
        XCTAssertEqual(result.transactions[1].amount, 2_000)
        XCTAssertEqual(result.transactions[1].note, "補足")
        XCTAssertEqual(result.monthlyBudget, 95_000)
        XCTAssertEqual(result.syncRevision, 2)
    }

    func testOmittedAccountsKeepLastBalanceHistoryAndManualReferences() throws {
        var first = try merge(snapshot(accounts: [account(), account(id: "investment:456", balance: 750_000, kind: .securities)]))
        let linked = first.accounts[0]
        let cash = LedgerAccount(name: "現金", institution: "", kind: .cash, openingBalance: 1_000)
        let manual = LedgerTransaction(accountID: linked.id, kind: .expense, amount: 500, date: now, merchant: "古い補足")
        let transfer = LedgerTransaction(accountID: cash.id, kind: .transfer, amount: 100, date: now,
                                         merchant: "振替", destinationAccountID: linked.id)
        first.accounts.append(cash)
        first.transactions.append(contentsOf: [manual, transfer])
        let result = try merge(snapshot(accounts: [account(id: "investment:456", balance: 760_000, kind: .securities)],
                                        transactions: [], revision: 2), into: first)
        XCTAssertEqual(result.accounts[0], linked)
        XCTAssertEqual(result.accounts.count, 3)
        XCTAssertEqual(result.transactions, first.transactions)
        XCTAssertEqual(FinanceCalculator.balance(for: result.accounts[0], in: result), 100_000)
        XCTAssertEqual(FinanceCalculator.balance(for: result.accounts[1], in: result), 760_000)
        let emptyResult = try merge(snapshot(accounts: [], transactions: [], revision: 3), into: result)
        XCTAssertEqual(emptyResult.accounts, result.accounts)
        XCTAssertEqual(emptyResult.transactions, result.transactions)
    }

    func testManualEntriesAttachedToReturnedAccountSurviveFullHistoryReplacement() throws {
        var first = try merge(snapshot())
        let manual = LedgerTransaction(accountID: first.accounts[0].id, kind: .income, amount: 123,
                                       date: now, merchant: "以前の補足")
        first.transactions.append(manual)
        let result = try merge(snapshot(transactions: [], revision: 2), into: first)
        XCTAssertEqual(result.transactions, [manual])
    }

    func testSnapshotsDoNotDeduplicateSameAmountsDatesOrNames() throws {
        let local = LedgerAccount(name: "生活口座", institution: "テスト銀行", kind: .bank, openingBalance: 0)
        let localEntry = LedgerTransaction(accountID: local.id, kind: .expense, amount: 1_000,
                                           date: now, category: .food, merchant: "スーパー")
        let incoming = snapshot(accounts: [account(), account(id: "investment:123", kind: .securities)],
                                transactions: [transaction(), transaction(id: "bank:tx2")])
        let result = try merge(incoming, into: LedgerState(accounts: [local], transactions: [localEntry]))
        XCTAssertEqual(result.accounts.count, 3)
        XCTAssertEqual(result.transactions.count, 3)
        XCTAssertEqual(Set(result.transactions.map(\.id)).count, 3)
        XCTAssertEqual(result.accounts[0], local)
        XCTAssertEqual(result.transactions[0], localEntry)
    }

    func testProviderBalancesAreAuthoritativeAndRepaymentsExcludedFromCashFlow() throws {
        let incoming = snapshot(accounts: [account(balance: 77_000), account(id: "bank:card", balance: 0, kind: .creditCard)],
                                transactions: [
                                    transaction(id: "bank:purchase", accountID: "bank:card", amount: 3_000),
                                    transaction(id: "bank:payment", amount: 23_000, excluded: true),
                                    transaction(id: "bank:card-payment", accountID: "bank:card", amount: 23_000, kind: .income, excluded: true),
                                    transaction(id: "bank:salary", amount: 300_000, kind: .income)
                                ])
        let result = try merge(incoming)
        XCTAssertEqual(FinanceCalculator.balance(for: result.accounts[0], in: result), 77_000)
        XCTAssertEqual(FinanceCalculator.balance(for: result.accounts[1], in: result), 0)
        XCTAssertEqual(FinanceCalculator.netWorth(in: result), 77_000)
        XCTAssertEqual(FinanceCalculator.monthlyExpense(in: result, month: now), 3_000)
        XCTAssertEqual(FinanceCalculator.monthlyIncome(in: result, month: now), 300_000)
        XCTAssertEqual(FinanceCalculator.categoryExpenses(in: result, month: now), [.food: 3_000])
        XCTAssertEqual(FinanceCalculator.transactions(in: result, month: now).count, 4)
    }

    func testNegativeCardAndInvestmentValuationDoNotApplyHistoricalTransactionsAgain() throws {
        let result = try merge(snapshot(accounts: [account(balance: -20_000, kind: .creditCard),
                                                   account(id: "investment:1", balance: 2_000_000, kind: .securities)]))
        XCTAssertEqual(FinanceCalculator.totalAssets(in: result), 2_000_000)
        XCTAssertEqual(FinanceCalculator.totalLiabilities(in: result), 20_000)
        XCTAssertEqual(FinanceCalculator.netWorth(in: result), 1_980_000)
    }

    func testStaleSnapshotsAreRejectedAndNewerSuccessfulSyncCanRestartRevision() throws {
        let first = try merge(snapshot(revision: 5))
        var stale = snapshot(revision: 100)
        stale.lastSuccessfulSync = now.addingTimeInterval(-1)
        XCTAssertThrowsError(try merge(stale, into: first))
        XCTAssertThrowsError(try merge(snapshot(revision: 4), into: first))
        XCTAssertEqual(try merge(snapshot(revision: 5), into: first), first)
        XCTAssertEqual(try merge(snapshot(revision: 6), into: first).syncRevision, 6)
        var newer = snapshot(revision: 1)
        newer.lastSuccessfulSync = now.addingTimeInterval(1)
        newer.generatedAt = newer.lastSuccessfulSync
        XCTAssertEqual(try merge(newer, into: first).syncRevision, 1)
    }

    func testMalformedSnapshotsRejectEntireImportAndDoNotModifyOriginalState() throws {
        let original = try merge(snapshot())
        let mutations: [(inout SyncSnapshot) -> Void] = [
            { $0.schemaVersion = 2 },
            { $0.revision = 0 },
            { $0.generatedAt = self.now.addingTimeInterval(301) },
            { $0.generatedAt = Date(timeIntervalSince1970: .nan) },
            { $0.lastSuccessfulSync = self.now.addingTimeInterval(1) },
            { $0.accounts.append($0.accounts[0]) },
            { $0.transactions.append($0.transactions[0]) },
            { $0.accounts[0].id = " " },
            { $0.accounts[0].id = "bank:\n123" },
            { $0.transactions[0].id = "" },
            { $0.transactions[0].id = String(repeating: "a", count: 257) },
            { $0.transactions[0].accountID = "bank:missing" },
            { $0.accounts = [] },
            { $0.transactions[0].kind = .transfer },
            { $0.transactions[0].amount = 0 },
            { $0.transactions[0].amount = -1 },
            { $0.transactions[0].amount = .max },
            { $0.transactions[0].merchant = "" },
            { $0.transactions[0].date = Date(timeIntervalSince1970: .infinity) },
            { $0.accounts[0].name = " " },
            { $0.accounts[0].balance = .min },
            { $0.accounts[0].balance = LedgerValidation.maximumAmount + 1 },
            { $0.accounts[0].balanceUpdatedAt = self.now.addingTimeInterval(301) },
            { $0.accounts[0].balanceUpdatedAt = Date(timeIntervalSince1970: .nan) }
        ]
        for (index, mutate) in mutations.enumerated() {
            var invalid = snapshot(revision: 2)
            mutate(&invalid)
            XCTAssertThrowsError(try merge(invalid, into: original), "Invalid mutation \(index)")
            XCTAssertEqual(original.syncRevision, 1)
            XCTAssertEqual(original.transactions[0].amount, 1_000)
        }
    }

    func testOtherProviderEntitiesArePreservedEvenWithSameExternalIDs() throws {
        let account = LedgerAccount(name: "別の連携", institution: "テスト", kind: .bank, openingBalance: 0,
                                    remote: RemoteAccountMetadata(provider: "other-provider", externalID: "bank:123",
                                                                   balance: 1_000, balanceUpdatedAt: now))
        let transaction = LedgerTransaction(accountID: account.id, kind: .expense, amount: 10,
                                            date: now, merchant: "別の連携の店",
                                            remote: RemoteTransactionMetadata(provider: "other-provider", externalID: "bank:tx1"))
        let result = try merge(snapshot(), into: LedgerState(accounts: [account], transactions: [transaction]))
        XCTAssertEqual(result.accounts[0], account)
        XCTAssertEqual(result.transactions[0], transaction)
        XCTAssertEqual(result.accounts.count, 2)
        XCTAssertEqual(result.transactions.count, 2)
    }

    func testRemoteMetadataValidationRejectsDuplicateIdentitiesAndProviderMismatch() throws {
        let valid = try merge(snapshot())
        var invalid = valid
        var duplicateAccount = invalid.accounts[0]
        duplicateAccount.id = UUID()
        invalid.accounts.append(duplicateAccount)
        XCTAssertThrowsError(try LedgerValidation.validate(invalid))
        invalid = valid
        var duplicateTransaction = invalid.transactions[0]
        duplicateTransaction.id = UUID()
        invalid.transactions.append(duplicateTransaction)
        XCTAssertThrowsError(try LedgerValidation.validate(invalid))
        invalid = valid
        invalid.transactions[0].remote?.provider = "mismatched-provider"
        XCTAssertThrowsError(try LedgerValidation.validate(invalid))
        invalid = valid
        invalid.accounts[0].remote = nil
        XCTAssertThrowsError(try LedgerValidation.validate(invalid))
        invalid = valid
        invalid.lastSyncAt = nil
        XCTAssertThrowsError(try LedgerValidation.validate(invalid))
    }

    func testLegacyBackupWithoutRemoteOrSyncFieldsStillDecodes() throws {
        let json = """
        {"schemaVersion":1,"monthlyBudget":150000,
         "accounts":[{"id":"52C057CA-80D6-44E4-8C2E-DBFA30DD7F91","name":"銀行","institution":"テスト",
                      "kind":"bank","openingBalance":100000,"note":"古いデータ"}],
         "transactions":[{"id":"966AFCBD-4DD7-4191-94DB-8B308DA02B32","accountID":"52C057CA-80D6-44E4-8C2E-DBFA30DD7F91",
                          "kind":"expense","amount":1000,"date":1788663600000,"category":"food","merchant":"店","note":""}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(LedgerState.self, from: Data(json.utf8))
        try LedgerValidation.validate(decoded)
        XCTAssertNil(decoded.accounts[0].remote)
        XCTAssertNil(decoded.transactions[0].remote)
        XCTAssertNil(decoded.lastSyncAt)
        XCTAssertNil(decoded.syncRevision)
        XCTAssertEqual(FinanceCalculator.netWorth(in: decoded), 99_000)
    }

    func testSnapshotDecodesIntegerYenAndDefaultsExcludedFlagWithoutLosingMetadataOnRoundTrip() throws {
        let json = """
        {"schemaVersion":1,"revision":1,"generatedAt":1788663600000,"lastSuccessfulSync":1788663600000,
         "accounts":[{"id":"bank:123","name":"銀行","institution":"テスト","kind":"bank","balance":100000,"balanceUpdatedAt":1788663600000}],
         "transactions":[{"id":"bank:tx1","accountID":"bank:123","kind":"expense","amount":1000,
                           "date":1788663600000,"category":"food","merchant":"店"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(SyncSnapshot.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.transactions[0].excludedFromCashFlow)
        XCTAssertFalse(decoded.transactions[0].isReversal)
        let state = try merge(decoded)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
        XCTAssertEqual(try decoder.decode(LedgerState.self, from: encoder.encode(state)), state)
        let fractionalYen = json.replacingOccurrences(of: "\"amount\":1000", with: "\"amount\":1000.5")
        XCTAssertThrowsError(try decoder.decode(SyncSnapshot.self, from: Data(fractionalYen.utf8)))
    }

    func testRepositoryPreservesCommittedSnapshotWhenNextSyncFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KakeiroSyncTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LedgerRepository(fileURL: directory.appendingPathComponent("ledger.json"))
        let state = try merge(snapshot())
        try repository.save(state)
        XCTAssertEqual(try repository.load(), state)
        let originalData = try Data(contentsOf: repository.fileURL)
        var invalid = snapshot(revision: 2)
        invalid.transactions[0].amount = -1
        XCTAssertThrowsError(try repository.save(merge(invalid, into: state)))
        XCTAssertEqual(try Data(contentsOf: repository.fileURL), originalData)
        XCTAssertEqual(try repository.load(), state)
    }

    func testCSVImportIntoLinkedAccountRejectsBeforeAddingDuplicates() throws {
        let state = try merge(snapshot())
        XCTAssertThrowsError(try CSVImporter.importTransactions(text: CSVImporter.template,
                                                               accountID: state.accounts[0].id, into: state))
        let cash = LedgerAccount(name: "現金", institution: "", kind: .cash, openingBalance: 0)
        var supplemented = state
        supplemented.accounts.append(cash)
        let result = try CSVImporter.importTransactions(text: CSVImporter.template, accountID: cash.id, into: supplemented)
        XCTAssertEqual(result.transactions.count, 2)
        XCTAssertEqual(result.lastSyncAt, now)
        XCTAssertNil(result.transactions.last?.remote)
    }

    func testNewerSnapshotWithOlderAccountBalanceRejectsWholeUpdateAndPreservesCommittedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KakeiroBalanceRegressionTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LedgerRepository(fileURL: directory.appendingPathComponent("ledger.json"))
        let first = try merge(snapshot(accounts: [account(), account(id: "investment:456", balance: 750_000, kind: .securities)]))
        try repository.save(first)
        let originalData = try Data(contentsOf: repository.fileURL)
        var incoming = snapshot(accounts: [account(balance: 90_000), account(id: "investment:456", balance: 700_000, kind: .securities)],
                                 transactions: [transaction(amount: 10_000)], revision: 2)
        incoming.generatedAt = now.addingTimeInterval(10)
        incoming.lastSuccessfulSync = incoming.generatedAt
        incoming.accounts[0].balanceUpdatedAt = incoming.generatedAt
        incoming.accounts[1].balanceUpdatedAt = now.addingTimeInterval(-1)
        XCTAssertThrowsError(try repository.save(merge(incoming, into: first))) { error in
            XCTAssertEqual(error as? FinanceError, .validation("保存済みの残高より古い口座データが含まれているため、更新しませんでした。"))
        }
        XCTAssertEqual(try repository.load(), first)
        XCTAssertEqual(try Data(contentsOf: repository.fileURL), originalData)
        // An unchanged timestamp is allowed: providers may correct a value without
        // issuing a new account timestamp, and the overall snapshot is newer.
        incoming.accounts[1].balanceUpdatedAt = now
        let corrected = try merge(incoming, into: first)
        XCTAssertEqual(corrected.accounts[0].remote?.balance, 90_000)
        XCTAssertEqual(corrected.accounts[1].remote?.balance, 700_000)
        XCTAssertEqual(corrected.transactions[0].amount, 10_000)
    }

    func testCSVExportOmitsImportedRepaymentsSoManualReimportDoesNotDoubleCount() throws {
        let source = try merge(snapshot(transactions: [transaction(), transaction(id: "bank:repayment", amount: 3_000, excluded: true)]))
        let cash = LedgerAccount(name: "現金", institution: "", kind: .cash, openingBalance: 0)
        let imported = try CSVImporter.importTransactions(text: CSVExporter.transactions(in: source), accountID: cash.id,
                                                          into: LedgerState(accounts: [cash]))
        XCTAssertEqual(imported.transactions.count, 1)
        XCTAssertEqual(FinanceCalculator.monthlyExpense(in: imported, month: now), 1_000)
    }

    func testExpenseRefundReducesSpendingWithoutBecomingIncomeOrChangingAuthoritativeBalance() throws {
        let incoming = snapshot(transactions: [transaction(amount: 1_000), transaction(id: "bank:refund", amount: 300, reversal: true)])
        let state = try merge(incoming)
        XCTAssertEqual(FinanceCalculator.monthlyExpense(in: state, month: now), 700)
        XCTAssertEqual(FinanceCalculator.monthlyIncome(in: state, month: now), 0)
        XCTAssertEqual(FinanceCalculator.categoryExpenses(in: state, month: now), [.food: 700])
        XCTAssertEqual(FinanceCalculator.netWorth(in: state), 100_000)
        XCTAssertEqual(state.transactions[1].kind, .expense)
        XCTAssertEqual(state.transactions[1].remote?.isReversal, true)
        XCTAssertEqual(try merge(incoming, into: state), state)
    }

    func testIncomeReversalReducesIncomeWithoutCreatingExpense() throws {
        let state = try merge(snapshot(transactions: [transaction(amount: 100_000, kind: .income),
                                                       transaction(id: "bank:income-reversal", amount: 20_000, kind: .income, reversal: true)]))
        XCTAssertEqual(FinanceCalculator.monthlyIncome(in: state, month: now), 80_000)
        XCTAssertEqual(FinanceCalculator.monthlyExpense(in: state, month: now), 0)
        XCTAssertEqual(FinanceCalculator.categoryExpenses(in: state, month: now), [:])
    }

    func testRefundInLaterMonthRemainsNegativeExpenseInRefundMonth() throws {
        var purchase = transaction(amount: 1_000)
        purchase.date = now.addingTimeInterval(-31 * 86_400)
        let state = try merge(snapshot(transactions: [purchase, transaction(id: "bank:refund", amount: 300, reversal: true)]))
        XCTAssertEqual(FinanceCalculator.monthlyExpense(in: state, month: purchase.date), 1_000)
        XCTAssertEqual(FinanceCalculator.monthlyExpense(in: state, month: now), -300)
        XCTAssertEqual(FinanceCalculator.monthlyIncome(in: state, month: now), 0)
        XCTAssertEqual(FinanceCalculator.categoryExpenses(in: state, month: now), [.food: -300])
    }

    func testOldRemoteMetadataDefaultsReversalToFalseAndJSONPreservesNewRefund() throws {
        let legacy = Data("{\"provider\":\"moneytree\",\"externalID\":\"bank:old\",\"excludedFromCashFlow\":false}".utf8)
        let decoder = JSONDecoder()
        XCTAssertFalse(try decoder.decode(RemoteTransactionMetadata.self, from: legacy).isReversal)
        let state = try merge(snapshot(transactions: [transaction(reversal: true)]))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let roundTrip = try decoder.decode(LedgerState.self, from: encoder.encode(state))
        XCTAssertEqual(roundTrip, state)
        XCTAssertEqual(FinanceCalculator.monthlyExpense(in: roundTrip, month: now), -1_000)
    }

    func testCSVExportRejectsRefundsInsteadOfMisclassifyingOrOmittingThem() throws {
        let state = try merge(snapshot(transactions: [transaction(), transaction(id: "bank:refund", amount: 300, reversal: true)]))
        XCTAssertThrowsError(try CSVExporter.transactions(in: state)) { error in
            XCTAssertEqual(error as? FinanceError, .validation("返金・取消を含む明細は、このCSV形式で正しく保存できません。JSONのバックアップを使用してください。"))
        }
    }
}
