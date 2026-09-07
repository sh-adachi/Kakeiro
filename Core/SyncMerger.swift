import Foundation

public enum SyncMerger {
    public static let provider = "moneytree"

    /// Replaces provider transactions for returned accounts and preserves local
    /// account/transaction UUIDs by upstream identity. Equal amounts and dates are
    /// never treated as duplicates. All validation happens before a state is returned.
    ///
    /// Accounts omitted by the provider and their history remain at the last known
    /// balance. Disconnecting a provider must never implicitly erase manual entries
    /// or transfers that reference those accounts. Deletion requires a user action.
    public static func apply(snapshot: SyncSnapshot, to state: LedgerState, now: Date = Date()) throws -> LedgerState {
        try LedgerValidation.validate(state)
        guard snapshot.schemaVersion == 1 else { throw FinanceError.unsupportedSchema(snapshot.schemaVersion) }
        guard snapshot.revision > 0 else { throw FinanceError.validation("連携データのバージョンが正しくありません。") }
        try LedgerValidation.validateDate(now, field: "現在日時")
        try LedgerValidation.validateDate(snapshot.generatedAt, field: "連携データの作成日時")
        try LedgerValidation.validateDate(snapshot.lastSuccessfulSync, field: "最終同期日時")
        guard snapshot.generatedAt <= now.addingTimeInterval(300),
              snapshot.lastSuccessfulSync <= snapshot.generatedAt else {
            throw FinanceError.validation("連携データの日時が正しくありません。端末の日時設定を確認してください。")
        }
        if let lastSyncAt = state.lastSyncAt {
            guard snapshot.lastSuccessfulSync >= lastSyncAt,
                  snapshot.lastSuccessfulSync != lastSyncAt || snapshot.revision >= (state.syncRevision ?? 0) else {
                throw FinanceError.validation("現在保存されているものより古い連携データのため、更新しませんでした。")
            }
        }
        guard snapshot.accounts.count <= LedgerValidation.maximumAccounts,
              snapshot.transactions.count <= LedgerValidation.maximumTransactions else {
            throw FinanceError.validation("連携データの件数が対応範囲を超えています。")
        }

        var externalAccountIDs = Set<String>()
        for account in snapshot.accounts {
            try LedgerValidation.validateIdentity(provider: provider, externalID: account.id)
            guard externalAccountIDs.insert(account.id).inserted else {
                throw FinanceError.validation("受信した口座の連携IDが重複しています。")
            }
            try LedgerValidation.validateDate(account.balanceUpdatedAt, field: "残高更新日時")
            guard account.balanceUpdatedAt <= snapshot.generatedAt.addingTimeInterval(300) else {
                throw FinanceError.validation("受信した残高の更新日時が未来になっています。")
            }
        }
        var externalTransactionIDs = Set<String>()
        for transaction in snapshot.transactions {
            try LedgerValidation.validateIdentity(provider: provider, externalID: transaction.id)
            guard externalTransactionIDs.insert(transaction.id).inserted else {
                throw FinanceError.validation("受信した取引の連携IDが重複しています。")
            }
            guard externalAccountIDs.contains(transaction.accountID) else {
                throw FinanceError.validation("受信した取引の口座が連携データ内にありません。")
            }
            guard transaction.kind != .transfer else {
                throw FinanceError.validation("受信した連携取引の形式に対応していません。")
            }
        }

        var result = state
        var accountsByExternalID: [String: UUID] = [:]
        var accountIndexByID: [UUID: Int] = [:]
        for (index, account) in state.accounts.enumerated() {
            accountIndexByID[account.id] = index
            if let remote = account.remote, remote.provider == provider {
                accountsByExternalID[remote.externalID] = account.id
            }
        }
        var previousTransactions: [String: LedgerTransaction] = [:]
        for transaction in state.transactions {
            if let remote = transaction.remote, remote.provider == provider {
                previousTransactions[remote.externalID] = transaction
            }
        }

        for imported in snapshot.accounts {
            let metadata = RemoteAccountMetadata(provider: provider, externalID: imported.id,
                                                 balance: imported.balance, balanceUpdatedAt: imported.balanceUpdatedAt)
            if let id = accountsByExternalID[imported.id], let index = accountIndexByID[id] {
                if let previous = result.accounts[index].remote,
                   imported.balanceUpdatedAt < previous.balanceUpdatedAt {
                    throw FinanceError.validation("保存済みの残高より古い口座データが含まれているため、更新しませんでした。")
                }
                result.accounts[index].name = imported.name
                result.accounts[index].institution = imported.institution
                result.accounts[index].kind = imported.kind
                result.accounts[index].remote = metadata
            } else {
                let account = LedgerAccount(name: imported.name, institution: imported.institution,
                                            kind: imported.kind, openingBalance: 0, remote: metadata)
                result.accounts.append(account)
                accountsByExternalID[imported.id] = account.id
            }
        }
        let returnedAccountIDs = Set(snapshot.accounts.compactMap { accountsByExternalID[$0.id] })
        result.transactions.removeAll {
            $0.remote?.provider == provider && returnedAccountIDs.contains($0.accountID)
        }
        for imported in snapshot.transactions {
            guard let accountID = accountsByExternalID[imported.accountID] else {
                throw FinanceError.validation("連携取引の口座が見つかりません。")
            }
            let previous = previousTransactions[imported.id]
            result.transactions.append(LedgerTransaction(
                id: previous?.id ?? UUID(), accountID: accountID, kind: imported.kind, amount: imported.amount,
                date: imported.date, category: imported.category, merchant: imported.merchant, note: previous?.note ?? "",
                remote: RemoteTransactionMetadata(provider: provider, externalID: imported.id,
                                                  excludedFromCashFlow: imported.excludedFromCashFlow, isReversal: imported.isReversal)))
        }
        result.lastSyncAt = snapshot.lastSuccessfulSync
        result.syncRevision = snapshot.revision
        try LedgerValidation.validate(result)
        return result
    }
}
