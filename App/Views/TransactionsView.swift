import SwiftUI

struct TransactionsView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var kind = "all"
    @State private var adding = false
    @State private var editing: LedgerTransaction?
    private var filtered: [LedgerTransaction] {
        FinanceCalculator.transactions(in: store.state, month: store.selectedMonth)
            .filter { (kind == "all" || $0.kind.rawValue == kind) && (query.isEmpty || ($0.merchant + $0.note + $0.category.title + store.accountName($0.accountID)).localizedCaseInsensitiveContains(query)) }
            .sorted { $0.date > $1.date }
    }
    var body: some View {
        VStack(spacing: 0) {
            MonthPicker().padding(.horizontal, 20)
            Picker("明細の種類", selection: $kind) {
                Text("すべて").tag("all"); Text("支出").tag("expense"); Text("収入").tag("income"); Text("振替").tag("transfer")
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 12)
            List {
                if filtered.isEmpty {
                    ContentUnavailableView("明細がありません", systemImage: "list.bullet.rectangle", description: Text(query.isEmpty ? "＋から収支を登録できます。カードの引き落としは「振替」で記録します。" : "検索条件を変えてみてください。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(filtered) { transaction in
                    Button { editing = transaction } label: { TransactionRow(transaction: transaction) }.buttonStyle(.plain)
                }
            }.listStyle(.insetGrouped)
        }.background(Palette.canvas)
        .navigationTitle("明細")
        .searchable(text: $query, prompt: "お店・カテゴリ・口座を検索")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("明細を追加").accessibilityIdentifier("addTransaction").disabled(store.state.accounts.isEmpty) } }
        .sheet(isPresented: $adding) { TransactionEditor() }
        .sheet(item: $editing) { TransactionEditor(transaction: $0) }
    }
}
