import SwiftUI

struct AccountsView: View {
    @Environment(AppStore.self) private var store
    @State private var adding = false
    @State private var editing: LedgerAccount?
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("すべての資産を、ひと目で").font(.subheadline).foregroundStyle(.secondary)
                    Text(yen(FinanceCalculator.netWorth(in: store.state))).font(.largeTitle.bold()).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                    Text("資産 − カード・負債 = 純資産").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }
            if store.state.accounts.isEmpty {
                ContentUnavailableView("口座をまとめよう", systemImage: "building.columns", description: Text("銀行・証券・カード・現金を登録できます。"))
            }
            ForEach(AccountKind.allCases) { kind in
                let accounts = store.state.accounts.filter { $0.kind == kind }
                if !accounts.isEmpty {
                    Section(kind.title) { ForEach(accounts) { account in
                        Button { editing = account } label: { AccountRow(account: account) }.buttonStyle(.plain)
                    } }
                }
            }
            Section { Label("残高は登録した開始残高と明細から計算します。証券の時価は口座の編集画面から手動で更新できます。", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle("資産")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("口座を追加").accessibilityIdentifier("addAccount") } }
        .sheet(isPresented: $adding) { AccountEditor() }
        .sheet(item: $editing) { AccountEditor(account: $0) }
    }
}

struct AccountEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let account: LedgerAccount?
    @State private var name: String
    @State private var institution: String
    @State private var kind: AccountKind
    @State private var balance: String
    @State private var note: String
    @State private var validation: String?
    @State private var deleting = false

    init(account: LedgerAccount? = nil, institution: String = "", kind: AccountKind = .bank) {
        self.account = account
        _name = State(initialValue: account?.name ?? institution)
        _institution = State(initialValue: account?.institution ?? institution)
        _kind = State(initialValue: account?.kind ?? kind)
        let original = account?.openingBalance ?? 0
        _balance = State(initialValue: String(account?.kind == .creditCard ? -original : original))
        _note = State(initialValue: account?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("口座の情報") {
                    TextField("口座名（例：生活費口座）", text: $name).accessibilityIdentifier("accountName")
                    TextField("金融機関名", text: $institution).accessibilityIdentifier("institutionName")
                    Picker("種類", selection: $kind) { ForEach(AccountKind.allCases) { Text($0.title).tag($0) } }.accessibilityIdentifier("accountKind")
                }
                Section {
                    HStack { Text(kind == .creditCard ? "開始時の未払額" : "開始残高"); Spacer(); TextField("0", text: $balance).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("openingBalance"); Text("円") }
                    if let account {
                        HStack { Text("現在の残高"); Spacer(); Text(yen(FinanceCalculator.balance(for: account, in: store.state))).foregroundStyle(.secondary) }
                    }
                } footer: {
                    Text(kind == .creditCard ? "カードの未払額は正の数で入力します。支払い時は銀行口座からカードへの「振替」で記録してください。" : "明細を記録し始める直前の残高です。すでに登録した明細の増減は、この金額に加算されます。")
                }
                if kind == .securities, let account {
                    Section {
                        NavigationLink("現在の評価額を更新") { ValuationEditor(account: account) { adjusted in balance = String(adjusted) } }
                    } footer: { Text("評価額の変化は収入・支出に含めず、開始残高の調整として反映します。口座の「保存」で確定します。") }
                }
                Section("メモ") { TextField("用途など（任意）", text: $note, axis: .vertical).lineLimit(3...5) }
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
                if account != nil { Section { Button("口座を削除", role: .destructive) { deleting = true }.accessibilityIdentifier("deleteAccount") } }
            }.navigationTitle(account == nil ? "口座を登録" : "口座を編集").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.fontWeight(.semibold).accessibilityIdentifier("saveAccount") }
                }
                .confirmationDialog("この口座を削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
                    Button("削除", role: .destructive) {
                        if let account, store.deleteAccount(account) { dismiss() }
                        else { validation = store.message; store.message = nil }
                    }
                } message: { Text("明細のある口座は削除できません。") }
        }
    }

    private func save() {
        guard let amount = parseYen(balance, allowNegative: true) else { validation = "残高は1兆円以内の整数で入力してください。"; return }
        let value = LedgerAccount(id: account?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), institution: institution.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, openingBalance: kind == .creditCard ? -amount : amount, note: note)
        if store.saveAccount(value) { dismiss() }
        else { validation = store.message; store.message = nil }
    }
}

struct ValuationEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let account: LedgerAccount
    let apply: (Int64) -> Void
    @State private var value = ""
    @State private var validation: String?
    var body: some View {
        Form {
            Section("証券口座の現在の評価額") {
                TextField("評価額（円）", text: $value).keyboardType(.numberPad)
                Text("金融機関で確認した円換算の評価額を入力してください。銘柄や為替の自動更新はありません。").font(.caption).foregroundStyle(.secondary)
            }
            if let validation { Text(validation).foregroundStyle(.red) }
            Button("口座の入力に反映") {
                guard let amount = parseYen(value) else { validation = "0〜1兆円の整数を入力してください。"; return }
                guard let current = store.state.accounts.first(where: { $0.id == account.id }) else { return }
                let adjusted = current.openingBalance + amount - FinanceCalculator.balance(for: current, in: store.state)
                guard (-LedgerValidation.maximumAmount...LedgerValidation.maximumAmount).contains(adjusted) else { validation = "調整後の開始残高が上限を超えます。"; return }
                apply(adjusted)
                dismiss()
            }
        }.navigationTitle("評価額の更新").navigationBarTitleDisplayMode(.inline)
        .onAppear { value = String(FinanceCalculator.balance(for: account, in: store.state)) }
    }
}
