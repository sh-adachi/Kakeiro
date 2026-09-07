import Foundation

public enum CSVImporter {
    public static let template = "date,type,amount,category,merchant,note\r\n2026-09-01,expense,1280,food,スーパー,食材\r\n"

    /// Imports the six-column UTF-8 template as yen. Import is atomic: any invalid
    /// row throws before returning a new state. Identical same-day rows in the same
    /// account are skipped, including rows already present in the ledger.
    public static func importTransactions(text: String, accountID: UUID, into state: LedgerState) throws -> LedgerState {
        try LedgerValidation.validate(state)
        guard let account = state.accounts.first(where: { $0.id == accountID }) else {
            throw FinanceError.validation("CSVの取込先口座を選んでください。")
        }
        guard account.remote == nil else {
            throw FinanceError.validation("自動連携口座にはCSVを取り込めません。補足データは手動口座に取り込んでください。")
        }
        guard text.utf8.count <= 32 * 1_024 * 1_024 else { throw FinanceError.invalidCSV(row: 1, reason: "ファイルは32MB以内にしてください。") }
        let rows = try CSVCodec.parse(text)
        guard let header = rows.first, header.fields == ["date", "type", "amount", "category", "merchant", "note"] else {
            throw FinanceError.invalidCSV(row: 1, reason: "見出しは date,type,amount,category,merchant,note の順で指定してください。")
        }
        guard rows.count > 1 else { throw FinanceError.invalidCSV(row: 1, reason: "取り込む取引がありません。") }
        var result = state
        var signatures = Set(state.transactions.filter { $0.kind != .transfer }.map(Signature.init))
        for row in rows.dropFirst() {
            guard row.fields.count == 6 else { throw FinanceError.invalidCSV(row: row.line, reason: "列数は6列にしてください。") }
            let values = row.fields
            guard let date = CSVCodec.parseDate(values[0]) else {
                throw FinanceError.invalidCSV(row: row.line, reason: "日付は実在する日付を yyyy-MM-dd で入力してください。")
            }
            let kind: TransactionKind
            switch values[1] {
            case "expense", "支出": kind = .expense
            case "income", "収入": kind = .income
            default: throw FinanceError.invalidCSV(row: row.line, reason: "type は expense（支出）または income（収入）を指定してください。振替はアプリで登録してください。")
            }
            guard !values[2].isEmpty, values[2].utf8.allSatisfy({ (48...57).contains($0) }),
                  let amount = Int64(values[2]), (1...LedgerValidation.maximumAmount).contains(amount) else {
                throw FinanceError.invalidCSV(row: row.line, reason: "金額は1〜1,000,000,000,000の半角整数で入力してください。")
            }
            guard let category = ExpenseCategory.allCases.first(where: { $0.rawValue == values[3] || $0.title == values[3] }) else {
                throw FinanceError.invalidCSV(row: row.line, reason: "category に対応していない分類が指定されています。")
            }
            let transaction = LedgerTransaction(accountID: accountID, kind: kind, amount: amount,
                                                date: date, category: category, merchant: values[4], note: values[5])
            // A one-row validation gives a useful CSV line number without repeatedly
            // scanning the entire ledger for large imports.
            do {
                try LedgerValidation.validate(LedgerState(accounts: state.accounts, transactions: [transaction], monthlyBudget: state.monthlyBudget))
            } catch {
                throw FinanceError.invalidCSV(row: row.line, reason: error.localizedDescription)
            }
            if signatures.insert(Signature(transaction)).inserted { result.transactions.append(transaction) }
            guard result.transactions.count <= LedgerValidation.maximumTransactions else {
                throw FinanceError.invalidCSV(row: row.line, reason: "取引の合計は100,000件までです。")
            }
        }
        try LedgerValidation.validate(result)
        return result
    }

    private struct Signature: Hashable {
        let accountID: UUID
        let date: String
        let kind: TransactionKind
        let amount: Int64
        let category: ExpenseCategory
        let merchant: String
        let note: String

        init(_ transaction: LedgerTransaction) {
            accountID = transaction.accountID
            date = CSVCodec.dateString(transaction.date)
            kind = transaction.kind
            amount = transaction.amount
            category = transaction.category
            merchant = transaction.merchant
            note = transaction.note
        }
    }
}

public enum CSVExporter {
    /// A six-column expense/income CSV matching the import template. Transfers and
    /// provider-classified repayments are excluded. For a lossless full backup use
    /// LedgerRepository JSON; filter state.accounts/transactions for per-account CSVs.
    /// Reversals cannot be represented by this positive-amount CSV format. Reject
    /// the export rather than relabeling refunds as income or silently omitting them.
    public static func transactions(in state: LedgerState) throws -> String {
        guard !state.transactions.contains(where: { $0.remote?.isReversal == true }) else {
            throw FinanceError.validation("返金・取消を含む明細は、このCSV形式で正しく保存できません。JSONのバックアップを使用してください。")
        }
        var rows = ["date,type,amount,category,merchant,note"]
        rows += state.transactions.filter { $0.kind != .transfer && $0.remote?.excludedFromCashFlow != true }.sorted { $0.date < $1.date }.map {
            [CSVCodec.dateString($0.date), $0.kind.rawValue, String($0.amount), $0.category.rawValue, $0.merchant, $0.note]
                .map(CSVCodec.escape).joined(separator: ",")
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }
}

private enum CSVCodec {
    struct Row { let fields: [String]; let line: Int }
    enum ParseState { case start, unquoted, quoted, afterQuote }

    static func parse(_ source: String) throws -> [Row] {
        var text = source
        if text.first == "\u{FEFF}" { text.removeFirst() }
        // Work with Unicode scalars so CRLF is recognized as two bytes rather than
        // Swift's single extended grapheme cluster.
        let scalars = Array(text.unicodeScalars)
        var rows: [Row] = []
        var fields: [String] = []
        var field = ""
        var state = ParseState.start
        var line = 1
        var rowLine = 1
        var index = 0
        var touched = false

        while index < scalars.count {
            let scalar = scalars[index]
            if state == .quoted {
                if scalar == "\"" {
                    state = .afterQuote
                } else {
                    field.unicodeScalars.append(scalar)
                    if scalar == "\n" { line += 1 }
                    else if scalar == "\r", index + 1 == scalars.count || scalars[index + 1] != "\n" { line += 1 }
                }
                touched = true
                index += 1
                continue
            }
            if scalar == "\r" || scalar == "\n" {
                fields.append(field)
                rows.append(Row(fields: fields, line: rowLine))
                guard rows.count <= LedgerValidation.maximumTransactions + 1 else {
                    throw FinanceError.invalidCSV(row: rowLine, reason: "CSVは100,000件以内にしてください。")
                }
                fields = []
                field = ""
                state = .start
                touched = false
                if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
                line += 1
                rowLine = line
            } else if scalar == "," {
                fields.append(field)
                guard fields.count <= 6 else { throw FinanceError.invalidCSV(row: rowLine, reason: "列数は6列にしてください。") }
                field = ""
                state = .start
                touched = true
            } else if scalar == "\"" {
                switch state {
                case .start: state = .quoted
                case .afterQuote:
                    field.append("\"")
                    state = .quoted
                default: throw FinanceError.invalidCSV(row: line, reason: "引用符の位置が正しくありません。")
                }
                touched = true
            } else {
                guard state != .afterQuote else { throw FinanceError.invalidCSV(row: line, reason: "閉じた引用符の後には区切り文字または改行を指定してください。") }
                state = .unquoted
                field.unicodeScalars.append(scalar)
                touched = true
            }
            index += 1
        }
        guard state != .quoted else { throw FinanceError.invalidCSV(row: rowLine, reason: "引用符が閉じられていません。") }
        if touched || !fields.isEmpty || !field.isEmpty {
            fields.append(field)
            rows.append(Row(fields: fields, line: rowLine))
        }
        return rows
    }

    static func parseDate(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }) else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1900...9999).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        let calendar = FinanceCalculator.calendar
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == parts[0], roundTrip.month == parts[1], roundTrip.day == parts[2] else { return nil }
        return date
    }

    static func dateString(_ date: Date) -> String {
        let components = FinanceCalculator.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
