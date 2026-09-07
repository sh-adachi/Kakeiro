import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        @Bindable var store = store
        ZStack {
            TabView {
                NavigationStack { DashboardView() }.tabItem { Label("ホーム", systemImage: "square.grid.2x2") }
                NavigationStack { TransactionsView() }.tabItem { Label("明細", systemImage: "list.bullet.rectangle") }
                NavigationStack { AccountsView() }.tabItem { Label("資産", systemImage: "chart.pie") }
                NavigationStack { ConnectionsView() }.tabItem { Label("連携", systemImage: "link") }
                NavigationStack { SettingsView() }.tabItem { Label("設定", systemImage: "slider.horizontal.3") }
            }
            if scenePhase != .active { Palette.canvas.ignoresSafeArea().overlay { Label("かけいろ", systemImage: "leaf.fill").font(.title).foregroundStyle(Palette.teal) }.accessibilityHidden(true) }
        }
        .alert("操作を完了できませんでした", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("閉じる", role: .cancel) { store.message = nil } } message: { Text(store.message ?? "") }
        .overlay {
            if let failure = store.loadFailure {
                ContentUnavailableView {
                    Label("保存データを読み込めません", systemImage: "externaldrive.badge.exclamationmark")
                } description: { Text(failure + "\n既存データの上書きを停止しています。") } actions: { Button("再読み込み") { store.reload() }.buttonStyle(.borderedProminent) }
                .background(Palette.canvas)
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if store.loadFailure != nil { store.reload() }
            while !Task.isCancelled {
                _ = await store.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { store.cancelRefresh(); BackgroundRefresh.schedule() }
        }
    }
}
