import SwiftUI

struct SyncedAccountDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let account: LedgerAccount
    private var current: LedgerAccount? { store.state.accounts.first { $0.id == account.id } }
    var body: some View {
        NavigationStack {
            Group {
                if let current {
                    List {
                        Section {
                            Text(current.name).font(.headline)
                            Text(current.institution).foregroundStyle(.secondary)
                            Text(yen(FinanceCalculator.balance(for: current, in: store.state))).font(.largeTitle.bold()).monospacedDigit()
                            if let remote = current.remote { Text("残高の取得日時 \(syncDate(remote.balanceUpdatedAt))").font(.caption).foregroundStyle(.secondary) }
                        }
                        Section {
                            Text("金融機関から取得した残高を表示しています。過去の明細を残高へ再加算しません。情報の訂正は連携元で行ってください。")
                            Text("連携元から口座が返されなくなっても、最終取得残高と明細を保持し、資産合計にも含めます。")
                            Text("保存履歴をまとめて消す場合は「設定」から端末内のデータを削除できます。連携中は次回の同期で取得データを再取り込みします。")
                        }.font(.footnote).foregroundStyle(.secondary)
                        Section("取得した明細") {
                            ForEach(store.state.transactions.filter { $0.accountID == current.id }.sorted { $0.date > $1.date }.prefix(100)) { TransactionRow(transaction: $0) }
                        }
                    }
                } else {
                    ContentUnavailableView("口座が見つかりません", systemImage: "building.columns", description: Text("この口座は端末内の保存データにありません。資産一覧で確認してください。"))
                }
            }.navigationTitle("自動取得した口座").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }; ToolbarItem(placement: .topBarTrailing) { RefreshControl() } }
        }
    }
}

struct SyncedTransactionDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let transaction: LedgerTransaction
    private var current: LedgerTransaction? { store.state.transactions.first { $0.id == transaction.id } }
    var body: some View {
        NavigationStack {
            Group {
                if let current {
                    Form {
                        Section {
                            Text(current.merchant).font(.headline)
                            Text(yen(current.amount)).font(.largeTitle.bold()).monospacedDigit()
                            LabeledContent("日付", value: AppCalendar.shortDate(current.date))
                            LabeledContent("口座", value: store.accountName(current.accountID))
                            LabeledContent("種類", value: current.kind.title)
                            LabeledContent("カテゴリ", value: current.category.title)
                        }
                        if current.remote?.isReversal == true {
                            Section { Text(current.kind == .expense ? "支出の返金です。この月の支出から差し引いて集計します。" : "収入の取消です。この月の収入から差し引いて集計します。").font(.footnote) }
                        }
                        if current.remote?.excludedFromCashFlow == true {
                            Section { Label("振替・カード引落・投資売買など、家計の収入・支出の集計対象外です。", systemImage: "arrow.left.arrow.right").font(.footnote) }
                        }
                        Section { Text("Moneytreeから自動取得した明細です。変更は連携元で行い、更新ボタンで反映します。").font(.footnote).foregroundStyle(.secondary) }
                    }
                } else {
                    ContentUnavailableView("明細が更新されました", systemImage: "doc.text.magnifyingglass", description: Text("この明細は最新の保存データに含まれていません。明細一覧で確認してください。"))
                        .accessibilityIdentifier("syncedTransactionRemoved")
                }
            }.navigationTitle("自動取得した明細").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}
