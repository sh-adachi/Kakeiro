import Foundation

/// Provider balances are signed integer yen and authoritative at balanceUpdatedAt.
public struct RemoteAccountMetadata: Codable, Hashable, Sendable {
    public var provider: String
    public var externalID: String
    public var balance: Int64
    public var balanceUpdatedAt: Date

    public init(provider: String, externalID: String, balance: Int64, balanceUpdatedAt: Date) {
        self.provider = provider
        self.externalID = externalID
        self.balance = balance
        self.balanceUpdatedAt = balanceUpdatedAt
    }
}

public struct RemoteTransactionMetadata: Codable, Hashable, Sendable {
    public var provider: String
    public var externalID: String
    /// Provider-classified transfers and card repayments remain visible in history
    /// but do not count as additional spending or income.
    public var excludedFromCashFlow: Bool
    /// Refunds/charge reversals retain the original income or expense kind and
    /// subtract their positive amount from that kind's cash-flow total.
    public var isReversal: Bool

    public init(provider: String, externalID: String, excludedFromCashFlow: Bool = false, isReversal: Bool = false) {
        self.provider = provider
        self.externalID = externalID
        self.excludedFromCashFlow = excludedFromCashFlow
        self.isReversal = isReversal
    }

    private enum CodingKeys: String, CodingKey { case provider, externalID, excludedFromCashFlow, isReversal }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(String.self, forKey: .provider)
        externalID = try values.decode(String.self, forKey: .externalID)
        excludedFromCashFlow = try values.decodeIfPresent(Bool.self, forKey: .excludedFromCashFlow) ?? false
        isReversal = try values.decodeIfPresent(Bool.self, forKey: .isReversal) ?? false
    }
}

/// A complete set of imported transactions for every account returned here.
/// The backend must finish all account/transaction pagination before publishing.
/// Wire dates use epoch milliseconds; the API client configures JSONDecoder accordingly.
public struct SyncSnapshot: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var revision: Int
    public var generatedAt: Date
    public var lastSuccessfulSync: Date
    public var accounts: [SyncedAccount]
    public var transactions: [SyncedTransaction]

    public init(schemaVersion: Int = 1, revision: Int, generatedAt: Date, lastSuccessfulSync: Date,
                accounts: [SyncedAccount], transactions: [SyncedTransaction]) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.generatedAt = generatedAt
        self.lastSuccessfulSync = lastSuccessfulSync
        self.accounts = accounts
        self.transactions = transactions
    }
}

public struct SyncedAccount: Codable, Hashable, Sendable {
    /// Namespaced upstream identity, e.g. bank:123 or investment:123.
    public var id: String
    public var name: String
    public var institution: String
    public var kind: AccountKind
    public var balance: Int64
    public var balanceUpdatedAt: Date

    public init(id: String, name: String, institution: String, kind: AccountKind,
                balance: Int64, balanceUpdatedAt: Date) {
        self.id = id
        self.name = name
        self.institution = institution
        self.kind = kind
        self.balance = balance
        self.balanceUpdatedAt = balanceUpdatedAt
    }
}

public struct SyncedTransaction: Codable, Hashable, Sendable {
    public var id: String
    public var accountID: String
    /// Only income and expense are accepted. An upstream transfer is represented
    /// by its signed leg with excludedFromCashFlow set to true.
    public var kind: TransactionKind
    public var amount: Int64
    public var date: Date
    public var category: ExpenseCategory
    public var merchant: String
    public var excludedFromCashFlow: Bool
    public var isReversal: Bool

    public init(id: String, accountID: String, kind: TransactionKind, amount: Int64, date: Date,
                category: ExpenseCategory, merchant: String, excludedFromCashFlow: Bool = false, isReversal: Bool = false) {
        self.id = id
        self.accountID = accountID
        self.kind = kind
        self.amount = amount
        self.date = date
        self.category = category
        self.merchant = merchant
        self.excludedFromCashFlow = excludedFromCashFlow
        self.isReversal = isReversal
    }

    private enum CodingKeys: String, CodingKey {
        case id, accountID, kind, amount, date, category, merchant, excludedFromCashFlow, isReversal
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        accountID = try values.decode(String.self, forKey: .accountID)
        kind = try values.decode(TransactionKind.self, forKey: .kind)
        amount = try values.decode(Int64.self, forKey: .amount)
        date = try values.decode(Date.self, forKey: .date)
        category = try values.decode(ExpenseCategory.self, forKey: .category)
        merchant = try values.decode(String.self, forKey: .merchant)
        excludedFromCashFlow = try values.decodeIfPresent(Bool.self, forKey: .excludedFromCashFlow) ?? false
        isReversal = try values.decodeIfPresent(Bool.self, forKey: .isReversal) ?? false
    }
}
