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

        var accountIDs = Set<UUID>()
        for account in state.accounts {
            guard accountIDs.insert(account.id).inserted else { throw FinanceError.validation("口座のIDが重複しています。") }
            try validateText(account.name, field: "口座名", maximum: 100, required: true)
            try validateText(account.institution, field: "金融機関名", maximum: 100, required: false)
            try validateText(account.note, field: "口座のメモ", maximum: 2_000, required: false)
            guard (-maximumAmount...maximumAmount).contains(account.openingBalance) else {
                throw FinanceError.validation("開始残高は−1兆円〜1兆円で入力してください。")
            }
        }

        var transactionIDs = Set<UUID>()
        for transaction in state.transactions {
            guard transactionIDs.insert(transaction.id).inserted else { throw FinanceError.validation("取引のIDが重複しています。") }
            guard accountIDs.contains(transaction.accountID) else { throw FinanceError.validation("取引の口座が見つかりません。") }
            guard (1...maximumAmount).contains(transaction.amount) else { throw FinanceError.validation("取引金額は1円〜1兆円で入力してください。") }
            guard transaction.date.timeIntervalSince1970.isFinite,
                  (-2_209_021_200..<253_402_268_400).contains(transaction.date.timeIntervalSince1970) else {
                throw FinanceError.validation("取引の日付は1900年〜9999年の範囲で入力してください。")
            }
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
        }
    }

    private static func validateText(_ value: String, field: String, maximum: Int, required: Bool) throws {
        guard !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FinanceError.validation("\(field)を入力してください。")
        }
        guard value.count <= maximum else { throw FinanceError.validation("\(field)は\(maximum)文字以内で入力してください。") }
        guard !value.unicodeScalars.contains(where: { $0.value == 0 }) else { throw FinanceError.validation("\(field)に使用できない文字が含まれています。") }
    }
}
