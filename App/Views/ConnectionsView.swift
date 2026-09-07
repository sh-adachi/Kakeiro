import SwiftUI
import SafariServices

struct Institution: Identifiable {
    let name: String
    let kind: AccountKind
    var id: String { name }
    static let requested: [Institution] = [
        .init(name: "SBI証券", kind: .securities), .init(name: "楽天証券", kind: .securities),
        .init(name: "楽天銀行", kind: .bank), .init(name: "三井住友銀行", kind: .bank),
        .init(name: "三菱UFJ銀行", kind: .bank), .init(name: "ゆうちょ銀行", kind: .bank)
    ]
}

struct ConnectionsView: View {
    @Environment(AppStore.self) private var store
    @State private var setup = false
    @State private var addingManual = false
    @State private var disconnect = false
    @State private var vaultURL: URL?
    @State private var showingVault = false
    var body: some View {
        List {
            Section { SyncStatusContent() }
            Section {
                Button {
                    if store.connection == nil { setup = true }
                    else { Task { await store.connectMoneytree() } }
                } label: {
                    Label(store.isConnecting ? "認証中…" : store.serviceStatus?.connected == true ? "Moneytreeを再認証" : "金融機関を連携", systemImage: "link").font(.headline).padding(.vertical, 6)
                }.disabled(store.isConnecting || store.isRefreshing).accessibilityIdentifier("connectProvider")
                if store.serviceStatus?.connected == true {
                    Button("登録する金融機関を管理") { Task { await openVault() } }
                }
                Button("サーバー接続設定") { setup = true }.disabled(store.isConnecting).accessibilityIdentifier("connectionSettings")
            } footer: { Text("API契約と稼働中の連携サーバーが必要です。金融機関のログイン・同意はMoneytreeの画面で行います。") }
            Section("連携したい金融機関") {
                ForEach(Institution.requested) { institution in
                    HStack(spacing: 12) { IconTile(symbol: institution.kind.systemImage); Text(institution.name); Spacer(); Text(institution.kind.title).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("更新のしくみ") {
                Label("毎日 0:00（日本時間）にサーバーで更新開始", systemImage: "moon.stars")
                Text("0時は取得開始の時刻です。金融機関側の更新や認証待ちで、完了まで時間がかかることがあります。iPhoneには起動時とOSが許可したバックグラウンド実行時に反映します。").font(.footnote).foregroundStyle(.secondary)
                Text("更新ボタンは金融データの再取得を要求します。Moneytreeの更新要求は1日4回までで、楽天銀行など金融機関ごとの制限もあります。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("補足データ") {
                Button { addingManual = true } label: { Label("手動管理の口座を追加", systemImage: "plus.circle") }
                Text("現金など、自動連携で取得できない情報を手動・CSVで補足できます。自動取得する口座と分けて記録します。").font(.caption).foregroundStyle(.secondary)
            }
            if store.serviceStatus?.connected == true {
                Section { Button("自動連携を解除", role: .destructive) { disconnect = true }.disabled(store.isConnecting) }
            }
        }.navigationTitle("金融機関連携")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { RefreshControl() } }
        .sheet(isPresented: $setup) { ConnectionSetupView() }
        .sheet(isPresented: $addingManual) { AccountEditor() }
        .sheet(isPresented: $showingVault) { if let vaultURL { ProviderWebView(url: vaultURL) } }
        .confirmationDialog("自動取得を停止しますか？", isPresented: $disconnect, titleVisibility: .visible) {
            Button("連携を解除", role: .destructive) { Task { _ = await store.disconnectMoneytree() } }
        } message: { Text("サーバーで認証情報を解除し、0時の自動取得を停止します。保存済みの明細は残ります。") }
    }
    private func openVault() async {
        do {
            guard let configuration = store.connection else { return }
            let provider = try await SyncBackendClient(configuration: configuration).provider()
            guard ["production", "staging"].contains(provider.environment) else { return }
            var components = URLComponents(string: provider.environment == "production" ? "https://vault.getmoneytree.com" : "https://vault-staging.getmoneytree.com")!
            components.queryItems = [.init(name: "client_id", value: provider.clientID)]
            vaultURL = components.url; showingVault = true
        } catch { store.syncError = error.localizedDescription }
    }
}

struct RefreshControl: View {
    @Environment(AppStore.self) private var store
    @State private var setup = false
    var body: some View {
        Button {
            if store.connection == nil { setup = true }
            else { Task { _ = await store.refresh(manual: true) } }
        } label: {
            if store.isRefreshing { ProgressView().controlSize(.small) }
            else { Label("更新", systemImage: "arrow.clockwise") }
        }.disabled(store.isRefreshing || store.isConnecting).accessibilityLabel("更新").accessibilityIdentifier("refreshAccounts")
        .sheet(isPresented: $setup) { ConnectionSetupView() }
    }
}

struct SyncStatusContent: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(store.serviceStatus?.connected == true ? "自動連携" : "自動連携は未接続", systemImage: "arrow.triangle.2.circlepath").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.teal)
                Spacer()
                if store.serviceStatus?.providerEnvironment == "staging" { Text("検証環境").font(.caption2).foregroundStyle(Palette.coral) }
            }
            if let date = store.state.lastSyncAt { Text("取得完了 \(syncDate(date))").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("lastSync") }
            if let next = store.serviceStatus?.nextScheduledSync, store.serviceStatus?.connected == true {
                Text("次回の定期更新 \(syncDate(next))").font(.caption).foregroundStyle(.secondary)
            } else { Text("0時更新：接続設定後にサーバーで実行").font(.caption).foregroundStyle(.secondary) }
            if let warning = store.serviceStatus?.warning { Text(warning).font(.caption).foregroundStyle(Palette.coral).accessibilityIdentifier("syncWarning") }
            if let error = store.syncError ?? store.serviceStatus?.error { Text(error).font(.caption).foregroundStyle(Palette.coral).accessibilityIdentifier("syncError") }
            else if let notice = store.syncNotice { Text(notice).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("syncNotice") }
            if store.connection == nil { Text("金融機関を連携して、残高と明細を自動で取り込みましょう。").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 6)
    }
}

func syncDate(_ date: Date) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP")
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo"); formatter.dateFormat = "M/d HH:mm"
    return formatter.string(from: date) + " JST"
}

struct ConnectionSetupView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = ""
    @State private var token = ""
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://sync.example.com", text: $baseURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("syncServerURL")
                    SecureField("サーバーの接続キー", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("syncServerToken")
                } header: { Text("あなたの連携サーバー") } footer: { Text("Kakeiro用に用意したサーバーのURLと接続キーを入力します。設定はこのiPhoneのキーチェーンに保存します。") }
                Section("準備が必要なもの") {
                    Label("Moneytree LINKの利用契約・公開クライアント設定", systemImage: "checklist")
                    Label("毎日0時に稼働するサーバーとHTTPSのURL", systemImage: "server.rack")
                    Text("Moneytree LINKは初期費用・月額料金の見積もりが必要です。API契約がない場合、サンプルや手動管理はそのまま利用できます。").font(.footnote).foregroundStyle(.secondary)
                    Link("Moneytree LINKの費用について", destination: URL(string: "https://faq.getmoneytree.com/cost")!)
                }
                if let error = store.syncError { Section { Text(error).font(.footnote).foregroundStyle(Palette.coral) } }
            }.navigationTitle("連携の接続設定").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "確認中…" : "確認して保存") {
                            saving = true
                            Task { let saved = await store.configureConnection(baseURL: baseURL, apiToken: token); saving = false; if saved { dismiss() } }
                        }.disabled(saving || store.isConnecting || baseURL.isEmpty || token.isEmpty).accessibilityIdentifier("saveConnection")
                    }
                }
                .onAppear { baseURL = store.connection?.baseURL ?? ""; token = store.connection?.apiToken ?? "" }
        }.interactiveDismissDisabled(saving)
    }
}

private struct ProviderWebView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
