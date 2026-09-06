import Foundation
import Observation

@MainActor @Observable
final class AppStore {
    private(set) var state = LedgerState()
    private(set) var loadFailure: String?
    var message: String?
    var selectedMonth = Date()
    private let repository: LedgerRepository

    init() {
        let args = ProcessInfo.processInfo.arguments
        let testing = args.contains("--uitesting")
        let folder = URL.applicationSupportDirectory.appendingPathComponent(testing ? "Kakeiro-UITests" : "Kakeiro", isDirectory: true)
        let file = folder.appendingPathComponent("ledger.json")
        repository = LedgerRepository(fileURL: file)
        if testing && args.contains("--reset-data") {
            try? FileManager.default.removeItem(at: file)
        }
        reload()
    }

    func reload() {
        do { state = try repository.load(); loadFailure = nil }
        catch { loadFailure = error.localizedDescription }
    }

    @discardableResult
    func commit(_ updated: LedgerState) -> Bool {
        guard loadFailure == nil else { message = "保存データを読み直してから操作してください。"; return false }
        do { try repository.save(updated); state = updated; return true }
        catch { message = error.localizedDescription; return false }
    }

    func saveAccount(_ account: LedgerAccount) -> Bool {
        var copy = state
        if let index = copy.accounts.firstIndex(where: { $0.id == account.id }) { copy.accounts[index] = account }
        else { copy.accounts.append(account) }
        return commit(copy)
    }

    func deleteAccount(_ account: LedgerAccount) -> Bool {
        guard !state.transactions.contains(where: { $0.accountID == account.id || $0.destinationAccountID == account.id }) else {
            message = "この口座には明細があります。明細を削除するか別の口座へ変更してから、口座を削除してください。"
            return false
        }
        var copy = state; copy.accounts.removeAll { $0.id == account.id }; return commit(copy)
    }

    func saveTransaction(_ transaction: LedgerTransaction) -> Bool {
        var copy = state
        if let index = copy.transactions.firstIndex(where: { $0.id == transaction.id }) { copy.transactions[index] = transaction }
        else { copy.transactions.append(transaction) }
        return commit(copy)
    }

    func deleteTransaction(_ transaction: LedgerTransaction) -> Bool {
        var copy = state; copy.transactions.removeAll { $0.id == transaction.id }; return commit(copy)
    }

    func loadSample() {
        guard state.accounts.isEmpty && state.transactions.isEmpty else { return }
        _ = commit(SampleData.make())
    }

    func accountName(_ id: UUID) -> String { state.accounts.first { $0.id == id }?.name ?? "口座なし" }

    func importCSV(text: String, accountID: UUID) -> Int? {
        do {
            let result = try CSVImporter.importTransactions(text: text, accountID: accountID, into: state)
            let count = result.transactions.count - state.transactions.count
            return commit(result) ? count : nil
        } catch { message = error.localizedDescription; return nil }
    }
}
