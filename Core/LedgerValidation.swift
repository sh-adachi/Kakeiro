import Foundation

public enum LedgerValidation {
    public static let maximumAmount: Int64 = 1_000_000_000_000
    public static let maximumAccounts = 500
    public static let maximumTransactions = 100_000

    public static func validate(_ state: LedgerState) throws {
        guard state.schemaVersion == 1 else { throw FinanceError.unsupportedSchema(state.schemaVersion) }
        guard state.accounts.count <= maximumAccounts else { throw FinanceError.validation("口座は500件まで登録できます。") }
        guard state.transactions.count <= maximumTransactions else { throw FinanceError.validation("取引は100,000件まで登録できます。") }
        guard (0...maximumAmount).contains(state.monthlyBudget) else { throw FinanceError.validation("月の予算は0〜1兆円で入力してください。") }
        if let date = state.lastSyncAt {
            try validateDate(date, field: "最終同期日時")
            guard let revision = state.syncRevision, revision > 0 else {
                throw FinanceError.validation("同期履歴のバージョンが正しくありません。")
            }
        } else if state.syncRevision != nil {
            throw FinanceError.validation("同期履歴の日時がありません。")
        }

        var accountIDs = Set<UUID>()
        var remoteAccountIDs = Set<RemoteIdentity>()
        var accountsByID: [UUID: LedgerAccount] = [:]
        for account in state.accounts {
            guard accountIDs.insert(account.id).inserted else { throw FinanceError.validation("口座のIDが重複しています。") }
            accountsByID[account.id] = account
            try validateText(account.name, field: "口座名", maximum: 100, required: true)
            try validateText(account.institution, field: "金融機関名", maximum: 100, required: false)
            try validateText(account.note, field: "口座のメモ", maximum: 2_000, required: false)
            guard (-maximumAmount...maximumAmount).contains(account.openingBalance) else {
                throw FinanceError.validation("開始残高は−1兆円〜1兆円で入力してください。")
            }
            if let remote = account.remote {
                try validateIdentity(provider: remote.provider, externalID: remote.externalID)
                guard remoteAccountIDs.insert(RemoteIdentity(provider: remote.provider, externalID: remote.externalID)).inserted else {
                    throw FinanceError.validation("連携口座のIDが重複しています。")
                }
                guard (-maximumAmount...maximumAmount).contains(remote.balance) else {
                    throw FinanceError.validation("連携口座の残高が対応範囲を超えています。")
                }
                try validateDate(remote.balanceUpdatedAt, field: "残高更新日時")
            }
        }

        var transactionIDs = Set<UUID>()
        var remoteTransactionIDs = Set<RemoteIdentity>()
        for transaction in state.transactions {
            guard transactionIDs.insert(transaction.id).inserted else { throw FinanceError.validation("取引のIDが重複しています。") }
            guard accountIDs.contains(transaction.accountID) else { throw FinanceError.validation("取引の口座が見つかりません。") }
            guard (1...maximumAmount).contains(transaction.amount) else { throw FinanceError.validation("取引金額は1円〜1兆円で入力してください。") }
            try validateDate(transaction.date, field: "取引の日付")
            try validateText(transaction.merchant, field: "取引先", maximum: 200, required: true)
            try validateText(transaction.note, field: "取引のメモ", maximum: 2_000, required: false)
            if transaction.kind == .transfer {
                guard let destination = transaction.destinationAccountID,
                      accountIDs.contains(destination), destination != transaction.accountID else {
                    throw FinanceError.validation("振替先には、振替元と異なる登録済み口座を指定してください。")
                }
            } else if transaction.destinationAccountID != nil {
                throw FinanceError.validation("収入・支出に振替先の口座は指定できません。")
            }
            if let remote = transaction.remote {
                try validateIdentity(provider: remote.provider, externalID: remote.externalID)
                guard remoteTransactionIDs.insert(RemoteIdentity(provider: remote.provider, externalID: remote.externalID)).inserted else {
                    throw FinanceError.validation("連携取引のIDが重複しています。")
                }
                guard accountsByID[transaction.accountID]?.remote?.provider == remote.provider else {
                    throw FinanceError.validation("連携取引と口座の提供元が一致していません。")
                }
                guard transaction.kind != .transfer else {
                    throw FinanceError.validation("連携取引の振替は集計対象外の収入・支出として記録してください。")
                }
            }
        }
    }

    static func validateDate(_ date: Date, field: String) throws {
        guard date.timeIntervalSince1970.isFinite,
              (-2_209_021_200..<253_402_268_400).contains(date.timeIntervalSince1970) else {
            throw FinanceError.validation("\(field)は1900年〜9999年の範囲で入力してください。")
        }
    }

    static func validateIdentity(provider: String, externalID: String) throws {
        try validateText(provider, field: "連携の提供元", maximum: 100, required: true)
        try validateText(externalID, field: "連携ID", maximum: 256, required: true)
        guard provider == provider.trimmingCharacters(in: .whitespacesAndNewlines),
              externalID == externalID.trimmingCharacters(in: .whitespacesAndNewlines),
              !provider.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !externalID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FinanceError.validation("連携IDに使用できない文字が含まれています。")
        }
    }

    static func validateText(_ value: String, field: String, maximum: Int, required: Bool) throws {
        guard !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FinanceError.validation("\(field)を入力してください。")
        }
        guard value.count <= maximum else { throw FinanceError.validation("\(field)は\(maximum)文字以内で入力してください。") }
        guard !value.unicodeScalars.contains(where: { $0.value == 0 }) else { throw FinanceError.validation("\(field)に使用できない文字が含まれています。") }
    }

    private struct RemoteIdentity: Hashable {
        var provider: String
        var externalID: String
    }
}
