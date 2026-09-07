import SwiftUI

@main
struct KakeiroApp: App {
    @State private var store: AppStore

    init() {
        let store = AppStore()
        _store = State(initialValue: store)
        BackgroundRefresh.register(store: store)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .environment(\.timeZone, TimeZone(identifier: "Asia/Tokyo")!)
                .tint(Palette.teal)
        }
    }
}
