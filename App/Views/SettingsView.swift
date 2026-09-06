import SwiftUI
import UniformTypeIdentifiers

struct LedgerDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText, .plainText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var budget = ""
    @State private var notice: String?
    @State private var exporting = false
    @State private var exportDocument = LedgerDocument(data: Data())
    @State private var exportType = UTType.json
    @State private var exportName = "Kakeiro-backup"
    @State private var restoring = false
    @State private var pendingRestore: LedgerState?
    @State private var confirmRestore = false
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                HStack { IconTile(symbol: "leaf.fill"); VStack(alignment: .leading, spacing: 5) { Text("かけいろ").font(.headline); Text("暮らしのお金を、ひとつに。 · v0.1").font(.caption).foregroundStyle(.secondary) } }
            }
            Section {
                HStack { Text("月の予算"); Spacer(); TextField("150000", text: $budget).keyboardType(.numberPad).multilineTextAlignment(.trailing).accessibilityIdentifier("monthlyBudget"); Text("円") }
                Button("予算を保存") {
                    guard let amount = parseYen(budget) else { notice = "予算は0〜1兆円の整数で入力してください。"; return }
                    var updated = store.state; updated.monthlyBudget = amount
                    if store.commit(updated) { notice = "月の予算を保存しました。" }
                }.accessibilityIdentifier("saveBudget")
            } header: { Text("予算") } footer: { Text("すべての月に同じ予算を適用します。0円にすると予算を表示しません。") }
            Section("明細の取り込み") {
                NavigationLink { CSVImportView() } label: { Label("CSVから明細を取り込む", systemImage: "square.and.arrow.down") }.disabled(store.state.accounts.isEmpty)
                Button { export(data: Data(CSVImporter.template.utf8), type: .commaSeparatedText, name: "Kakeiro-template") } label: { Label("CSVテンプレートを保存", systemImage: "tablecells") }
            }
            Section {
                Button { backup() } label: { Label("バックアップを保存", systemImage: "square.and.arrow.up") }
                Button { restoring = true } label: { Label("バックアップから復元", systemImage: "arrow.counterclockwise") }
            } header: { Text("バックアップ") } footer: { Text("口座・明細・予算をJSONファイルに保存します。ファイルには家計情報が含まれます。アプリを削除する前にバックアップしてください。") }
            Section("保存と連携") {
                Label("データはこのiPhone内に保存", systemImage: "iphone")
                Label("自動連携は未接続", systemImage: "link")
                Text("銀行のパスワードや証券のログイン情報は取得しません。クラウド同期、株価・為替の自動更新、Face IDによるアプリロックはありません。").font(.caption).foregroundStyle(.secondary)
            }
            Section { Button("すべてのデータを削除", role: .destructive) { confirmClear = true } } footer: { Text("サンプルから使い始めた場合も、ここで空の家計簿に戻せます。") }
        }.navigationTitle("設定")
        .onAppear { budget = String(store.state.monthlyBudget) }
        .alert("お知らせ", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("OK", role: .cancel) { notice = nil } } message: { Text(notice ?? "") }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType, defaultFilename: exportName) { result in if case .failure(let error) = result { notice = error.localizedDescription } }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.json]) { result in
            do {
                let data = try readSelectedFile(result.get(), limit: 128 * 1_024 * 1_024)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
                let candidate = try decoder.decode(LedgerState.self, from: data)
                try LedgerValidation.validate(candidate)
                pendingRestore = candidate; confirmRestore = true
            } catch { notice = "復元できませんでした。現在のデータは変更していません。\n" + error.localizedDescription }
        }
        .confirmationDialog("バックアップで置き換えますか？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("復元する", role: .destructive) {
                if let candidate = pendingRestore, store.commit(candidate) { budget = String(candidate.monthlyBudget); notice = "バックアップを復元しました。" }
                pendingRestore = nil
            }
            Button("キャンセル", role: .cancel) { pendingRestore = nil }
        } message: { Text("現在の口座・明細・予算を、口座\(pendingRestore?.accounts.count ?? 0)件・明細\(pendingRestore?.transactions.count ?? 0)件のバックアップに置き換えます。") }
        .confirmationDialog("すべてのデータを削除しますか？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("すべて削除", role: .destructive) { if store.commit(LedgerState()) { budget = String(store.state.monthlyBudget) } }
        } message: { Text("このiPhone内の口座・明細・予算を削除します。必要な場合は先にバックアップを保存してください。") }
    }

    private func backup() {
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            export(data: try encoder.encode(store.state), type: .json, name: "Kakeiro-backup")
        } catch { notice = error.localizedDescription }
    }
    private func export(data: Data, type: UTType, name: String) { exportDocument = LedgerDocument(data: data); exportType = type; exportName = name; exporting = true }
}

struct CSVImportView: View {
    @Environment(AppStore.self) private var store
    @State private var accountID: UUID?
    @State private var picking = false
    @State private var pendingText: String?
    @State private var importCount = 0
    @State private var confirming = false
    @State private var notice: String?
    var body: some View {
        Form {
            Section("取り込み先") {
                Picker("口座", selection: $accountID) { Text("選択してください").tag(Optional<UUID>.none); ForEach(store.state.accounts) { Text($0.name).tag(Optional($0.id)) } }
                Button("CSVファイルを選ぶ") { picking = true }.disabled(accountID == nil)
            }
            Section("取り込み形式") {
                Text("UTF-8の6列形式に対応しています。各金融機関のCSVは、そのままではなくテンプレート形式に整えてから取り込んでください。").font(.subheadline)
                Text("date,type,amount,category,merchant,note").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("日付：yyyy-MM-dd\n種類：expense（支出）/ income（収入）\n金額：1円以上の半角整数\n分類：food / daily / transport / housing / utilities / entertainment / health / shopping / salary / other").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("振替は取り込めません。カード引落しや銀行・証券間の資金移動は、アプリで「振替」として登録してください。").font(.footnote)
                Text("同じ口座・日付・種類・金額・分類・内容・メモの明細は重複としてスキップします。同日に完全に同じ買い物を複数回した場合、必要な明細は手動で追加してください。").font(.footnote)
                Text("開始残高は取り込む明細の前の残高に設定してください。現在残高と過去明細を両方加算すると残高がずれます。").font(.footnote)
            }.foregroundStyle(.secondary)
        }.navigationTitle("CSV取り込み").navigationBarTitleDisplayMode(.inline)
        .onAppear { accountID = accountID ?? store.state.accounts.first?.id }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            do {
                let data = try readSelectedFile(result.get(), limit: 32 * 1_024 * 1_024)
                guard let text = String(data: data, encoding: .utf8), let accountID else { throw FinanceError.validation("UTF-8のCSVファイルを選んでください。") }
                let candidate = try CSVImporter.importTransactions(text: text, accountID: accountID, into: store.state)
                importCount = candidate.transactions.count - store.state.transactions.count
                pendingText = text; confirming = true
            } catch { notice = error.localizedDescription }
        }
        .confirmationDialog("明細\(importCount)件を取り込みますか？", isPresented: $confirming, titleVisibility: .visible) {
            Button("取り込む") { if let pendingText, let accountID, let count = store.importCSV(text: pendingText, accountID: accountID) { notice = "\(count)件の明細を取り込みました。" }; pendingText = nil }
            Button("キャンセル", role: .cancel) { pendingText = nil }
        } message: { Text("\(accountID.map(store.accountName) ?? "")に追加します。重複した明細はスキップします。") }
        .alert("CSV取り込み", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("OK", role: .cancel) { notice = nil } } message: { Text(notice ?? "") }
    }
}

private func readSelectedFile(_ url: URL, limit: Int) throws -> Data {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let size = values.fileSize, size <= limit else { throw FinanceError.validation("ファイルが大きすぎるか、通常のファイルではありません。") }
    let data = try Data(contentsOf: url)
    guard data.count <= limit else { throw FinanceError.validation("ファイルが大きすぎます。") }
    return data
}
