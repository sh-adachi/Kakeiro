import Foundation

public enum SampleData {
    /// All institutions, merchants and amounts are fictional. Loading demo data is
    /// an explicit UI action; the repository never inserts it into a real ledger.
    public static func make(now: Date = Date()) -> LedgerState {
        let bank = LedgerAccount(name: "生活用口座", institution: "サンプル銀行（架空）", kind: .bank, openingBalance: 1_850_000)
        let card = LedgerAccount(name: "メインカード", institution: "サンプルカード（架空）", kind: .creditCard, openingBalance: -42_600)
        let securities = LedgerAccount(name: "つみたて・投資", institution: "サンプル証券（架空）", kind: .securities, openingBalance: 2_520_000,
                                       note: "架空の評価額です。株価・評価額は自動更新されません。")
        let cash = LedgerAccount(name: "お財布", institution: "手元の現金", kind: .cash, openingBalance: 28_000)
        let calendar = FinanceCalculator.calendar
        let currentDay = calendar.component(.day, from: now)
        let month = calendar.dateInterval(of: .month, for: now)!.start
        func date(_ day: Int) -> Date {
            let start = calendar.date(byAdding: .day, value: min(day, currentDay) - 1, to: month)!
            return calendar.date(byAdding: .hour, value: 12, to: start)!
        }
        let entries: [LedgerTransaction] = [
            .init(accountID: bank.id, kind: .income, amount: 345_000, date: date(1), category: .salary, merchant: "給与（サンプル）"),
            .init(accountID: bank.id, kind: .expense, amount: 76_000, date: date(1), category: .housing, merchant: "家賃（サンプル）"),
            .init(accountID: bank.id, kind: .transfer, amount: 42_600, date: date(2), merchant: "カード引落（サンプル）", destinationAccountID: card.id),
            .init(accountID: card.id, kind: .expense, amount: 18_340, date: date(3), category: .food, merchant: "まちのスーパー（架空）"),
            .init(accountID: bank.id, kind: .expense, amount: 12_480, date: date(4), category: .utilities, merchant: "電気・ガス（サンプル）"),
            .init(accountID: card.id, kind: .expense, amount: 4_850, date: date(5), category: .daily, merchant: "日用品ストア（架空）"),
            .init(accountID: card.id, kind: .expense, amount: 4_320, date: date(6), category: .transport, merchant: "交通費（サンプル）"),
            .init(accountID: card.id, kind: .expense, amount: 6_800, date: date(7), category: .entertainment, merchant: "映画・書籍（サンプル）"),
            .init(accountID: cash.id, kind: .expense, amount: 2_040, date: date(8), category: .health, merchant: "お薬（サンプル）")
        ]
        return LedgerState(accounts: [bank, card, securities, cash], transactions: entries)
    }
}
