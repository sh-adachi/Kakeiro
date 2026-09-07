import Foundation
import Observation
import UIKit

@MainActor @Observable
final class AppStore {
    private(set) var state = LedgerState()
    private(set) var loadFailure: String?
    var message: String?
    var selectedMonth = Date()
    private let repository: LedgerRepository
    private(set) var connection: SyncConfiguration?
    private(set) var serviceStatus: SyncServiceStatus?
    private(set) var isRefreshing = false
    private(set) var isConnecting = false
    var syncError: String?
    var syncNotice: String?
    @ObservationIgnored private var refreshTask: Task<Bool, Never>?
    @ObservationIgnored private var queuedManualRefreshTask: Task<Bool, Never>?
    @ObservationIgnored private var refreshWasManual = false
    @ObservationIgnored private var syncGeneration = 0
    @ObservationIgnored private let testing: Bool
    @ObservationIgnored private var authorization: MoneytreeAuthorization?
    var manualAccounts: [LedgerAccount] { state.accounts.filter { $0.remote == nil } }

    init() {
        let args = ProcessInfo.processInfo.arguments
        testing = args.contains("--uitesting")
        let folder = URL.applicationSupportDirectory.appendingPathComponent(testing ? "Kakeiro-UITests" : "Kakeiro", isDirectory: true)
        let file = folder.appendingPathComponent("ledger.json")
        repository = LedgerRepository(fileURL: file)
        if testing && args.contains("--reset-data") {
            try? FileManager.default.removeItem(at: file)
        }
        reload()
        if testing {
            if args.contains("--sync-fixture") {
                connection = SyncConfiguration(baseURL: "http://127.0.0.1:8779", apiToken: "kakeiro-uitest-only-token-not-for-production")
            }
        } else {
            do { connection = try ConnectionKeychain.load() }
            catch { syncError = error.localizedDescription }
        }
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
        guard account.remote == nil, state.accounts.first(where: { $0.id == account.id })?.remote == nil else {
            message = "自動取得した口座は連携元で管理します。更新ボタンで最新情報を取得してください。"; return false
        }
        var copy = state
        if let index = copy.accounts.firstIndex(where: { $0.id == account.id }) { copy.accounts[index] = account }
        else { copy.accounts.append(account) }
        return commit(copy)
    }

    func deleteAccount(_ account: LedgerAccount) -> Bool {
        guard account.remote == nil else { message = "自動取得した口座は金融機関の管理画面から連携を変更してください。"; return false }
        guard !state.transactions.contains(where: { $0.accountID == account.id || $0.destinationAccountID == account.id }) else {
            message = "この口座には明細があります。明細を削除するか別の口座へ変更してから、口座を削除してください。"
            return false
        }
        var copy = state; copy.accounts.removeAll { $0.id == account.id }; return commit(copy)
    }

    func saveTransaction(_ transaction: LedgerTransaction) -> Bool {
        guard transaction.remote == nil, state.transactions.first(where: { $0.id == transaction.id })?.remote == nil,
              state.accounts.first(where: { $0.id == transaction.accountID })?.remote == nil,
              transaction.destinationAccountID.flatMap({ id in state.accounts.first { $0.id == id } })?.remote == nil else {
            message = "自動取得する口座への手動明細は追加できません。補足用の手動口座を作成してください。"; return false
        }
        var copy = state
        if let index = copy.transactions.firstIndex(where: { $0.id == transaction.id }) { copy.transactions[index] = transaction }
        else { copy.transactions.append(transaction) }
        return commit(copy)
    }

    func deleteTransaction(_ transaction: LedgerTransaction) -> Bool {
        guard transaction.remote == nil else { message = "自動取得した明細は連携元の情報を表示しています。"; return false }
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

    func configureConnection(baseURL: String, apiToken: String) async -> Bool {
        guard !isConnecting else { return false }
        isConnecting = true
        defer { isConnecting = false }
        let previousConnection = connection
        cancelRefresh()
        do {
            let candidate = SyncConfiguration(baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), apiToken: apiToken.trimmingCharacters(in: .whitespacesAndNewlines))
            let client = try SyncBackendClient(configuration: candidate, allowLoopback: testing)
            let status = try await client.status()
            try Task.checkCancellation()
            guard connection == previousConnection else { return false }
            if !testing { try ConnectionKeychain.save(candidate) }
            cancelRefresh()
            connection = candidate; serviceStatus = status; syncError = nil
            BackgroundRefresh.schedule()
            return true
        } catch is CancellationError { return false }
        catch {
            guard connection == previousConnection else { return false }
            syncError = error.localizedDescription; return false
        }
    }

    func connectMoneytree() async {
        guard let connection, !isConnecting else { return }
        isConnecting = true; syncError = nil
        defer { isConnecting = false; authorization = nil }
        cancelRefresh()
        do {
            let client = try SyncBackendClient(configuration: connection, allowLoopback: testing)
            let provider = try await client.provider()
            try Task.checkCancellation()
            guard self.connection == connection else { return }
            let flow = MoneytreeAuthorization(); authorization = flow
            let tokens = try await flow.authorize(provider)
            try Task.checkCancellation()
            guard self.connection == connection else { return }
            try await client.connect(tokens)
            try Task.checkCancellation()
            guard self.connection == connection else { return }
            cancelRefresh()
            _ = await refresh(manual: false, waitForCompletion: true)
            BackgroundRefresh.schedule()
        } catch is CancellationError { return }
        catch {
            guard self.connection == connection else { return }
            syncError = error.localizedDescription
        }
    }

    /// Manual refresh asks the provider to aggregate; foreground/background reads
    /// only download the server snapshot and never consume provider refresh quota.
    @discardableResult
    func refresh(manual: Bool = false, waitForCompletion: Bool = false) async -> Bool {
        guard !Task.isCancelled else { return false }
        if manual, let queuedManualRefreshTask { return await queuedManualRefreshTask.value }
        guard let connection else {
            if manual { syncError = "連携画面でサーバーの接続設定を行ってください。" }
            return false
        }
        guard UIApplication.shared.isProtectedDataAvailable, loadFailure == nil else { return false }
        let generation = syncGeneration
        if let refreshTask {
            guard manual && !refreshWasManual else { return await refreshTask.value }
            // A manual request must still reach the provider when an automatic
            // snapshot read is already running. All concurrent taps join this one
            // queued request, including taps while the read's owner is unwinding.
            let queued = Task { @MainActor in
                _ = await refreshTask.value
                while let active = self.refreshTask, !self.refreshWasManual {
                    guard generation == self.syncGeneration, self.connection == connection, !Task.isCancelled else { return false }
                    _ = await active.value
                    await Task.yield()
                }
                guard generation == self.syncGeneration, self.connection == connection, !Task.isCancelled else { return false }
                return await self.beginRefresh(connection: connection, generation: generation, manual: true, wait: true)
            }
            queuedManualRefreshTask = queued
            let success = await queued.value
            if generation == syncGeneration { queuedManualRefreshTask = nil }
            return success
        }
        return await beginRefresh(connection: connection, generation: generation, manual: manual, wait: waitForCompletion || manual)
    }

    private func beginRefresh(connection: SyncConfiguration, generation: Int, manual: Bool, wait: Bool) async -> Bool {
        guard generation == syncGeneration, self.connection == connection, !Task.isCancelled,
              UIApplication.shared.isProtectedDataAvailable, loadFailure == nil else { return false }
        if let refreshTask { return await refreshTask.value }
        isRefreshing = true
        refreshWasManual = manual
        let task = Task { await performRefresh(connection: connection, generation: generation, manual: manual, wait: wait) }
        refreshTask = task
        let success = await task.value
        if generation == syncGeneration { refreshTask = nil; refreshWasManual = false }
        return success
    }

    private func performRefresh(connection: SyncConfiguration, generation: Int, manual: Bool, wait: Bool) async -> Bool {
        defer { if generation == syncGeneration { isRefreshing = false } }
        guard generation == syncGeneration, self.connection == connection, !Task.isCancelled else { return false }
        syncError = nil; syncNotice = nil
        do {
            let client = try SyncBackendClient(configuration: connection, allowLoopback: testing)
            var status = try await client.status()
            try Task.checkCancellation()
            guard generation == syncGeneration else { return false }
            serviceStatus = status
            guard status.connected else { syncNotice = "金融機関が未接続です。連携画面から認証してください。"; return false }
            if manual {
                try await client.triggerRefresh()
                try Task.checkCancellation()
                guard generation == syncGeneration else { return false }
                status = try await client.status()
            }
            for _ in 0..<(wait ? 72 : 0) {
                try Task.checkCancellation()
                guard generation == syncGeneration else { return false }
                serviceStatus = status
                if !status.isSyncing { break }
                syncNotice = "金融機関の更新を待っています。アプリを閉じてもサーバーで取得を続けます。"
                try await Task.sleep(for: .seconds(testing ? 0.1 : 5))
                status = try await client.status()
            }
            try Task.checkCancellation()
            guard generation == syncGeneration else { return false }
            serviceStatus = status
            if let lastSuccess = status.lastSuccessfulSync,
               manual || lastSuccess != state.lastSyncAt || status.revision.map({ $0 != state.syncRevision }) == true {
                let snapshot = try await client.snapshot()
                try Task.checkCancellation()
                guard generation == syncGeneration else { return false }
                let merged = try SyncMerger.apply(snapshot: snapshot, to: state)
                guard commit(merged) else { syncError = message; message = nil; return false }
            }
            syncError = status.error
            syncNotice = status.isSyncing ? "更新処理はサーバーで継続中です。" : status.error == nil && status.lastSuccessfulSync != nil ? "取得済みのデータを表示しています。" : nil
            return status.error == nil && status.lastSuccessfulSync != nil
        } catch is CancellationError { return false }
        catch {
            guard generation == syncGeneration else { return false }
            syncError = "更新できませんでした。保存済みのデータは保持しています。\n" + error.localizedDescription
            return false
        }
    }

    func cancelRefresh() {
        syncGeneration += 1
        queuedManualRefreshTask?.cancel(); queuedManualRefreshTask = nil
        refreshTask?.cancel(); refreshTask = nil; refreshWasManual = false; isRefreshing = false
    }

    func disconnectMoneytree() async -> Bool {
        guard !isConnecting else { return false }
        guard let connection else { return true }
        isConnecting = true
        defer { isConnecting = false }
        cancelRefresh()
        do {
            let client = try SyncBackendClient(configuration: connection, allowLoopback: testing)
            try await client.disconnect()
            try Task.checkCancellation()
            guard self.connection == connection else { return false }
            let status = try await client.status()
            try Task.checkCancellation()
            guard self.connection == connection else { return false }
            cancelRefresh()
            serviceStatus = status
            syncNotice = "自動取得を停止しました。保存済みの明細は保持しています。"; syncError = nil
            return true
        } catch is CancellationError { return false }
        catch {
            guard self.connection == connection else { return false }
            syncError = "連携解除を確認できませんでした。\n" + error.localizedDescription; return false
        }
    }

    func restoreBackup(_ candidate: LedgerState) -> Bool { cancelRefresh(); return commit(candidate) }
}
