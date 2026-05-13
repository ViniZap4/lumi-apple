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
            // A real top-level "View" menu in the menu bar, so users
            // discover the read/edit toggle without keyboard-shortcut
            // tribal knowledge. Explicit show/hide variants make the
            // command's effect obvious.
            CommandMenu("View") {
                Button("Read Mode") {
                    appState.editorMode = .view
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(appState.selectedEntry == nil)

                Button("Edit Mode") {
                    appState.editorMode = .edit
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(appState.selectedEntry == nil)

                Divider()

                Button("Toggle Read / Edit") {
                    appState.editorMode = appState.editorMode == .view ? .edit : .view
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(appState.selectedEntry == nil)

                Divider()

                Button("Back to Vault") {
                    if appState.editor.isDirty { appState.editor.save() }
                    appState.selectedEntry = nil
                    appState.selectedNoteID = nil
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(appState.selectedEntry == nil)

                Button("Quick Switcher…") {
                    appState.showQuickSwitcher = true
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(appState.rootFolder == nil)
            }
        }
        #endif
    }
}
