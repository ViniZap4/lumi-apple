import SwiftUI
import SwiftData
import LumiKit
import LumiUI

@main
struct LumiApp: App {
    @State private var appState = AppState()

    private static let sharedContainer: ModelContainer = {
        do {
            return try VaultModelContainer.make()
        } catch {
            fatalError("Failed to create vault model container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(\.theme, appState.theme.tokens)
                .preferredColorScheme(appState.theme.tokens.isDark ? .dark : .light)
                .tint(appState.theme.tokens.primary)
        }
        .modelContainer(Self.sharedContainer)
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appState.showSettings = true }
                    .keyboardShortcut(",", modifiers: [.command])
            }
        }
        #endif
    }
}
