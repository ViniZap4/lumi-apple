import SwiftUI
import LumiKit
import LumiUI

@main
struct LumiApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(\.theme, appState.theme.tokens)
                .preferredColorScheme(appState.theme.tokens.isDark ? .dark : .light)
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
        #endif
    }
}
