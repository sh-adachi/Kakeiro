import Foundation

public enum AccountKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case bank, creditCard, securities, cash
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .bank: return "銀行"
        case .creditCard: return "クレジットカード"
        case .securities: return "証券"
        case .cash: return "現金"
        }
    }
    public var systemImage: String {
        switch self {
        case .bank: return "building.columns.fill"
        case .creditCard: return "creditcard.fill"
        case .securities: return "chart.line.uptrend.xyaxis"
        case .cash: return "banknote.fill"
        }
    }
}

public enum TransactionKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case expense, income, transfer
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .expense: return "支出"
        case .income: return "収入"
        case .transfer: return "振替"
        }
    }
}

public enum ExpenseCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case food, daily, transport, housing, utilities, entertainment, health, shopping, salary, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .food: return "食費"
        case .daily: return "日用品"
        case .transport: return "交通費"
        case .housing: return "住居費"
        case .utilities: return "水道・光熱費"
        case .entertainment: return "趣味・娯楽"
        case .health: return "健康・医療"
        case .shopping: return "買い物"
        case .salary: return "給与"
        case .other: return "その他"
        }
    }
    public var systemImage: String {
        switch self {
        case .food: return "fork.knife"
        case .daily: return "basket.fill"
        case .transport: return "tram.fill"
        case .housing: return "house.fill"
        case .utilities: return "bolt.fill"
        case .entertainment: return "gamecontroller.fill"
        case .health: return "cross.case.fill"
        case .shopping: return "bag.fill"
        case .salary: return "briefcase.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }
}

public struct LedgerAccount: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var institution: String
    public var kind: AccountKind
    /// Yen. Negative values represent debt, including outstanding card charges.
    public var openingBalance: Int64
    public var note: String
    public var remote: RemoteAccountMetadata?

    public init(id: UUID = UUID(), name: String, institution: String, kind: AccountKind,
                openingBalance: Int64, note: String = "", remote: RemoteAccountMetadata? = nil) {
        self.id = id
        self.name = name
        self.institution = institution
        self.kind = kind
        self.openingBalance = openingBalance
        self.note = note
        self.remote = remote
    }
}

public struct LedgerTransaction: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var accountID: UUID
    public var kind: TransactionKind
    /// Positive integer yen. `kind` determines the direction.
    public var amount: Int64
    public var date: Date
    public var category: ExpenseCategory
    public var merchant: String
    public var note: String
    public var destinationAccountID: UUID?
    public var remote: RemoteTransactionMetadata?

    public init(id: UUID = UUID(), accountID: UUID, kind: TransactionKind, amount: Int64,
                date: Date = Date(), category: ExpenseCategory = .other, merchant: String,
                note: String = "", destinationAccountID: UUID? = nil, remote: RemoteTransactionMetadata? = nil) {
        self.id = id
        self.accountID = accountID
        self.kind = kind
        self.amount = amount
        self.date = date
        self.category = category
        self.merchant = merchant
        self.note = note
        self.destinationAccountID = destinationAccountID
        self.remote = remote
    }
}

public struct LedgerState: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var accounts: [LedgerAccount]
    public var transactions: [LedgerTransaction]
    public var monthlyBudget: Int64
    public var lastSyncAt: Date?
    public var syncRevision: Int?

    public init(schemaVersion: Int = 1, accounts: [LedgerAccount] = [],
                transactions: [LedgerTransaction] = [], monthlyBudget: Int64 = 150_000,
                lastSyncAt: Date? = nil, syncRevision: Int? = nil) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.transactions = transactions
        self.monthlyBudget = monthlyBudget
        self.lastSyncAt = lastSyncAt
        self.syncRevision = syncRevision
    }
    public static var empty: LedgerState { LedgerState() }
}

public enum FinanceError: Error, LocalizedError, Equatable {
    case validation(String)
    case unsupportedSchema(Int)
    case corruptedFile
    case fileReadFailed
    case fileWriteFailed
    case invalidCSV(row: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case .validation(let message): return message
        case .unsupportedSchema(let version): return "このデータ形式（バージョン \(version)）には対応していません。"
        case .corruptedFile: return "保存データを読み取れません。元のファイルは変更されていません。"
        case .fileReadFailed: return "保存データを開けません。ファイルへのアクセス権を確認してください。"
        case .fileWriteFailed: return "データを保存できませんでした。空き容量とアクセス権を確認してください。"
        case .invalidCSV(let row, let reason): return "CSVの\(row)行目: \(reason)"
        }
    }
}
