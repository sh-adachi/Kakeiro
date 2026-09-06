import SwiftUI
import Charts

struct DashboardView: View {
    @Environment(AppStore.self) private var store
    @State private var addingTransaction = false
    @State private var addingAccount = false
    @State private var editingTransaction: LedgerTransaction?
    private var expense: Int64 { FinanceCalculator.monthlyExpense(in: store.state, month: store.selectedMonth) }
    private var income: Int64 { FinanceCalculator.monthlyIncome(in: store.state, month: store.selectedMonth) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("暮らしのお金を、ひとつに。").font(.subheadline).foregroundStyle(.secondary)
                        Text("お金の見える日々").font(.title2.bold())
                    }
                    Spacer()
                    Image(systemName: "leaf.fill").font(.title2).foregroundStyle(Palette.teal).padding(14).background(Palette.mint.opacity(0.5), in: Circle())
                }.padding(.top, 8)
                if store.state.accounts.isEmpty { welcome }
                else {
                    wealthCard
                    VStack(spacing: 12) {
                        MonthPicker()
                        HStack(spacing: 12) {
                            metric("収入", value: income, symbol: "arrow.down.left", color: Palette.teal)
                            metric("支出", value: expense, symbol: "arrow.up.right", color: Palette.coral)
                        }
                        budgetCard
                    }
                    categories
                    recentTransactions
                }
                Text("端末内に保存 · 金融機関の自動連携は未接続").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.bottom, 8)
            }.padding(.horizontal, 20)
        }
        .background(Palette.canvas)
        .navigationTitle("かけいろ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { addingTransaction = true } label: { Image(systemName: "plus") }.accessibilityLabel("明細を追加").accessibilityIdentifier("addTransaction").disabled(store.state.accounts.isEmpty) } }
        .sheet(isPresented: $addingTransaction) { TransactionEditor() }
        .sheet(isPresented: $addingAccount) { AccountEditor() }
        .sheet(item: $editingTransaction) { TransactionEditor(transaction: $0) }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "chart.bar.xaxis.ascending").font(.system(size: 44, weight: .light))
            Text("残高も、日々の支出も。\nここから整えよう。").font(.title.bold()).fixedSize(horizontal: false, vertical: true)
            Text("銀行・カード・証券口座をまとめて、\nあなたのお金の流れが見える家計簿。").font(.subheadline).lineSpacing(5)
            Button { addingAccount = true } label: { Text("最初の口座を登録").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(Palette.teal)
            Button("サンプルで試す") { store.loadSample() }.font(.subheadline.weight(.semibold)).foregroundStyle(.white).frame(maxWidth: .infinity).accessibilityIdentifier("loadSample")
            Text("サンプルの口座・金額はすべて架空です。").font(.caption2).foregroundStyle(.white.opacity(0.8))
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.white).background(Palette.teal.gradient, in: RoundedRectangle(cornerRadius: 28))
    }

    private var wealthCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("純資産", systemImage: "circle.grid.cross").font(.subheadline.weight(.medium))
                Spacer()
                Text("現在の残高").font(.caption).padding(.horizontal, 10).padding(.vertical, 5).background(.white.opacity(0.12), in: Capsule())
            }.foregroundStyle(.white.opacity(0.84))
            Text(yen(FinanceCalculator.netWorth(in: store.state))).font(.system(size: 38, weight: .semibold, design: .rounded)).minimumScaleFactor(0.55).lineLimit(1).monospacedDigit().accessibilityIdentifier("netWorth")
            Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
            HStack {
                VStack(alignment: .leading, spacing: 6) { Text("資産合計").font(.caption).opacity(0.75); Text(yen(FinanceCalculator.totalAssets(in: store.state))).font(.subheadline.weight(.semibold)).monospacedDigit() }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) { Text("カード・負債").font(.caption).opacity(0.75); Text(yen(FinanceCalculator.totalLiabilities(in: store.state))).font(.subheadline.weight(.semibold)).monospacedDigit() }
            }
        }.padding(24).foregroundStyle(.white).background(Palette.teal.gradient, in: RoundedRectangle(cornerRadius: 26))
    }

    private func metric(_ title: String, value: Int64, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(color)
            Text(yen(value)).font(.title3.weight(.semibold)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private var budgetCard: some View {
        let budget = store.state.monthlyBudget
        let remainder = budget - expense
        return Panel {
            HStack {
                Text("今月の予算").font(.subheadline.weight(.semibold))
                Spacer()
                Text(budget > 0 ? "あと \(yen(max(0, remainder)))" : "未設定").font(.subheadline.weight(.semibold)).foregroundStyle(remainder < 0 ? Palette.coral : Palette.teal)
            }
            if budget > 0 {
                ProgressView(value: min(Double(expense), Double(budget)), total: Double(budget)).tint(remainder < 0 ? Palette.coral : Palette.teal)
                HStack {
                    Text(remainder < 0 ? "\(yen(-remainder)) 超過" : "無理のないペースで続けよう")
                    Spacer()
                    Text("予算 \(yen(budget))")
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var categories: some View {
        let totals = FinanceCalculator.categoryExpenses(in: store.state, month: store.selectedMonth)
        let sorted = totals.sorted { $0.value > $1.value }
        return Panel {
            HStack { Text("支出の内訳").font(.headline); Spacer(); Text("\(sorted.count) カテゴリ").font(.caption).foregroundStyle(.secondary) }
            if sorted.isEmpty { Text("この月の支出はまだありません。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12) }
            else {
                Chart(sorted, id: \.key) { entry in
                    SectorMark(angle: .value("金額", entry.value), innerRadius: .ratio(0.73), angularInset: 2)
                        .cornerRadius(4).foregroundStyle(Palette.color(entry.key))
                        .accessibilityLabel(entry.key.title).accessibilityValue(yen(entry.value))
                }.frame(height: 180).chartLegend(.hidden)
                    .overlay { VStack(spacing: 6) { Text("支出合計").font(.caption).foregroundStyle(.secondary); Text(yen(expense)).font(.headline).monospacedDigit() }.accessibilityHidden(true) }
                ForEach(sorted.prefix(4), id: \.key) { entry in
                    HStack { Circle().fill(Palette.color(entry.key)).frame(width: 8, height: 8); Text(entry.key.title).font(.subheadline); Spacer(); Text(yen(entry.value)).font(.subheadline.weight(.medium)).monospacedDigit(); Text("\(Int(Double(entry.value) / max(1, Double(expense)) * 100))%").font(.caption).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing) }
                }
            }
        }
    }

    private var recentTransactions: some View {
        let transactions = FinanceCalculator.transactions(in: store.state, month: store.selectedMonth)
        return Panel {
            Text("最近の明細").font(.headline)
            if transactions.isEmpty { Text("右上の＋から収入・支出を記録できます。").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(transactions.sorted { $0.date > $1.date }.prefix(4)) { transaction in
                Button { editingTransaction = transaction } label: { TransactionRow(transaction: transaction) }.buttonStyle(.plain)
            }
        }
    }
}
