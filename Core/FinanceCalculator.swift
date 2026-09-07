import Foundation

public enum FinanceCalculator {
    /// Gregorian calendar with Japanese month boundaries, independent of device locale.
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    public static func balance(for account: LedgerAccount, in state: LedgerState) -> Int64 {
        // A provider balance already includes its transaction history. Reapplying
        // imported entries would count purchases and repayments twice.
        if let remote = account.remote { return remote.balance }
        return state.transactions.reduce(account.openingBalance) { balance, transaction in
            var result = balance
            if transaction.accountID == account.id {
                result = add(result, transaction.kind == .income ? transaction.amount : negate(transaction.amount))
            }
            if transaction.kind == .transfer, transaction.destinationAccountID == account.id {
                result = add(result, transaction.amount)
            }
            return result
        }
    }

    public static func netWorth(in state: LedgerState) -> Int64 {
        state.accounts.reduce(0) { add($0, balance(for: $1, in: state)) }
    }

    public static func totalAssets(in state: LedgerState) -> Int64 {
        state.accounts.reduce(0) { add($0, max(0, balance(for: $1, in: state))) }
    }

    /// Returns the positive magnitude of all negative account balances.
    public static func totalLiabilities(in state: LedgerState) -> Int64 {
        state.accounts.reduce(0) { add($0, negate(min(0, balance(for: $1, in: state)))) }
    }

    public static func monthlyIncome(in state: LedgerState, month: Date) -> Int64 {
        transactions(in: state, month: month).filter { $0.kind == .income && $0.remote?.excludedFromCashFlow != true }.reduce(0) { add($0, cashFlowAmount($1)) }
    }

    public static func monthlyExpense(in state: LedgerState, month: Date) -> Int64 {
        transactions(in: state, month: month).filter { $0.kind == .expense && $0.remote?.excludedFromCashFlow != true }.reduce(0) { add($0, cashFlowAmount($1)) }
    }

    public static func categoryExpenses(in state: LedgerState, month: Date) -> [ExpenseCategory: Int64] {
        transactions(in: state, month: month).filter { $0.kind == .expense && $0.remote?.excludedFromCashFlow != true }.reduce(into: [:]) {
            $0[$1.category] = add($0[$1.category, default: 0], cashFlowAmount($1))
        }
    }

    public static func transactions(in state: LedgerState, month: Date) -> [LedgerTransaction] {
        guard month.timeIntervalSinceReferenceDate.isFinite,
              let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        return state.transactions.filter { $0.date >= interval.start && $0.date < interval.end }
            .sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
    }

    // Validated states cannot overflow these calculations. Saturation also prevents a
    // malformed, unsaved draft from crashing a view before validation can explain it.
    private static func cashFlowAmount(_ transaction: LedgerTransaction) -> Int64 {
        transaction.remote?.isReversal == true ? negate(transaction.amount) : transaction.amount
    }

    private static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (rhs >= 0 ? .max : .min) : result
    }

    private static func negate(_ value: Int64) -> Int64 {
        value == .min ? .max : -value
    }
}
