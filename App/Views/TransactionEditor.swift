import SwiftUI

struct TransactionEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let transaction: LedgerTransaction?
    @State private var kind: TransactionKind
    @State private var amount: String
    @State private var accountID: UUID?
    @State private var destinationID: UUID?
    @State private var date: Date
    @State private var category: ExpenseCategory
    @State private var merchant: String
    @State private var note: String
    @State private var validation: String?
    @State private var deleting = false

    init(transaction: LedgerTransaction? = nil) {
        self.transaction = transaction
        _kind = State(initialValue: transaction?.kind ?? .expense)
        _amount = State(initialValue: transaction.map { String($0.amount) } ?? "")
        _accountID = State(initialValue: transaction?.accountID)
        _destinationID = State(initialValue: transaction?.destinationAccountID)
        _date = State(initialValue: transaction?.date ?? Date())
        _category = State(initialValue: transaction?.category ?? .food)
        _merchant = State(initialValue: transaction?.merchant ?? "")
        _note = State(initialValue: transaction?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("種類", selection: $kind) { Text("支出").tag(TransactionKind.expense); Text("収入").tag(TransactionKind.income); Text("振替").tag(TransactionKind.transfer) }.pickerStyle(.segmented).accessibilityIdentifier("transactionKind")
                    HStack { Text("¥").font(.title2).foregroundStyle(.secondary); TextField("0", text: $amount).keyboardType(.numberPad).font(.system(size: 36, weight: .semibold, design: .rounded)).accessibilityIdentifier("transactionAmount") }.padding(.vertical, 12)
                } footer: { if kind == .transfer { Text("口座間の移動とカードの支払いは振替で記録します。月の収入・支出には含みません。") } }
                Section("明細の内容") {
                    DatePicker("日付", selection: $date, displayedComponents: .date)
                    Picker(kind == .transfer ? "振替元" : "口座", selection: $accountID) { Text("選択してください").tag(Optional<UUID>.none); ForEach(store.state.accounts) { Text($0.name).tag(Optional($0.id)) } }.accessibilityIdentifier("transactionAccount")
                    if kind == .transfer {
                        Picker("振替先", selection: $destinationID) { Text("選択してください").tag(Optional<UUID>.none); ForEach(store.state.accounts.filter { $0.id != accountID }) { Text($0.name).tag(Optional($0.id)) } }.accessibilityIdentifier("transactionDestination")
                    } else {
                        Picker("カテゴリ", selection: $category) { ForEach(ExpenseCategory.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) } }
                    }
                    TextField(kind == .transfer ? "内容（例：カード引き落とし）" : "お店・内容", text: $merchant).accessibilityIdentifier("transactionMerchant")
                }
                Section("メモ") { TextField("メモ（任意）", text: $note, axis: .vertical).lineLimit(3...5) }
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
                if transaction != nil { Section { Button("明細を削除", role: .destructive) { deleting = true }.accessibilityIdentifier("deleteTransaction") } }
            }.navigationTitle(transaction == nil ? "明細を追加" : "明細を編集").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.fontWeight(.semibold).accessibilityIdentifier("saveTransaction") }
            }
            .onAppear { if accountID == nil { accountID = store.state.accounts.first?.id } }
            .onChange(of: kind) { _, newValue in if transaction == nil { category = newValue == .income ? .salary : .food } }
            .onChange(of: accountID) { _, newValue in if destinationID == newValue { destinationID = nil } }
            .confirmationDialog("この明細を削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if let transaction, store.deleteTransaction(transaction) { dismiss() }
                    else { validation = store.message; store.message = nil }
                }
            } message: { Text("口座の残高と月の集計にも反映されます。") }
        }
    }

    private func save() {
        guard let amount = parseYen(amount), amount > 0 else { validation = "金額は1〜1兆円の整数で入力してください。"; return }
        guard let accountID else { validation = "口座を選択してください。"; return }
        guard kind != .transfer || (destinationID != nil && destinationID != accountID) else { validation = "異なる振替先の口座を選択してください。"; return }
        let value = LedgerTransaction(id: transaction?.id ?? UUID(), accountID: accountID, kind: kind, amount: amount, date: date, category: category, merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines), note: note, destinationAccountID: kind == .transfer ? destinationID : nil)
        if store.saveTransaction(value) { dismiss() }
        else { validation = store.message; store.message = nil }
    }
}
