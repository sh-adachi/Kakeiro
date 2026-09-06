import SwiftUI

@main
struct KakeiroApp: App {
    @State private var store = AppStore()

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
