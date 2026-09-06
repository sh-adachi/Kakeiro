import SwiftUI

enum Palette {
    static let teal = Color(red: 0.07, green: 0.40, blue: 0.37)
    static let mint = Color(red: 0.78, green: 0.90, blue: 0.83)
    static let coral = Color(red: 0.78, green: 0.36, blue: 0.27)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static func color(_ category: ExpenseCategory) -> Color {
        switch category {
        case .food: return .orange
        case .daily: return .teal
        case .transport: return .blue
        case .housing: return Palette.teal
        case .utilities: return .yellow
        case .entertainment: return .purple
        case .health: return .pink
        case .shopping: return Palette.coral
        case .salary: return .green
        case .other: return .gray
        }
    }
}

func yen(_ value: Int64) -> String { value.formatted(.currency(code: "JPY").precision(.fractionLength(0)).locale(Locale(identifier: "ja_JP"))) }

enum AppCalendar {
    static var tokyo: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Tokyo")!; return value }
    static func monthLabel(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP"); formatter.timeZone = tokyo.timeZone; formatter.dateFormat = "yyyy年 M月"; return formatter.string(from: date)
    }
    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP"); formatter.timeZone = tokyo.timeZone; formatter.dateFormat = "M/d（E）"; return formatter.string(from: date)
    }
}

struct MonthPicker: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        HStack {
            Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }.accessibilityLabel("前の月")
            Spacer()
            Text(AppCalendar.monthLabel(store.selectedMonth)).font(.subheadline.weight(.semibold)).monospacedDigit()
            Spacer()
            Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }.accessibilityLabel("次の月")
        }.foregroundStyle(.primary)
    }
    private func move(_ offset: Int) { store.selectedMonth = AppCalendar.tokyo.date(byAdding: .month, value: offset, to: store.selectedMonth) ?? store.selectedMonth }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 16) { content }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card, in: RoundedRectangle(cornerRadius: 24)) }
}

struct IconTile: View {
    let symbol: String
    var color: Color = Palette.teal
    var body: some View { Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(color).frame(width: 44, height: 44).background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true) }
}

struct TransactionRow: View {
    @Environment(AppStore.self) private var store
    let transaction: LedgerTransaction
    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: transaction.kind == .transfer ? "arrow.left.arrow.right" : transaction.category.systemImage, color: transaction.kind == .income ? Palette.teal : Palette.color(transaction.category))
            VStack(alignment: .leading, spacing: 5) {
                Text(transaction.merchant.isEmpty ? transaction.category.title : transaction.merchant).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Text("\(AppCalendar.shortDate(transaction.date)) · \(store.accountName(transaction.accountID))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 5) {
                Text((transaction.kind == .expense ? "−" : transaction.kind == .income ? "+" : "") + yen(transaction.amount)).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(transaction.kind == .income ? Palette.teal : .primary)
                Text(transaction.kind == .transfer ? "振替" : transaction.category.title).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5).contentShape(Rectangle())
    }
}

struct AccountRow: View {
    @Environment(AppStore.self) private var store
    let account: LedgerAccount
    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: account.kind.systemImage, color: account.kind == .creditCard ? Palette.coral : Palette.teal)
            VStack(alignment: .leading, spacing: 5) {
                Text(account.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(account.institution.isEmpty ? account.kind.title : account.institution).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(yen(FinanceCalculator.balance(for: account, in: store.state))).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
                Text("手動管理").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6).contentShape(Rectangle())
    }
}

func parseYen(_ text: String, allowNegative: Bool = false) -> Int64? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "，", with: "")
    guard !value.isEmpty, let amount = Int64(value), abs(amount == Int64.min ? Int64.max : amount) <= 1_000_000_000_000, allowNegative || amount >= 0 else { return nil }
    return amount
}
