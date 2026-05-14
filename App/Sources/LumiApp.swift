import SwiftUI
import SwiftData
import LumiKit
import LumiUI

@main
struct LumiApp: App {
    @State private var appState = AppState()

    /// Map preferences.themeMode + the active theme into a SwiftUI
    /// preferredColorScheme. `auto` returns nil (system follows). `dark` /
    /// `light` force the scheme regardless of theme palette so users can
    /// pin the OS chrome (window controls, segmented controls) independent
    /// of which color palette they picked.
    private var preferredScheme: ColorScheme? {
        switch appState.preferences.themeMode {
        case .auto: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

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
                .preferredColorScheme(preferredScheme)
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

                Button("Home") {
                    if appState.editor.isDirty { appState.editor.save() }
                    appState.selectedEntry = nil
                    appState.selectedNoteID = nil
                    appState.selectedVaultID = nil
                    appState.selectedRemoteVaultID = nil
                    appState.browserState = nil
                    appState.rootFolder = nil
                    appState.setSession(nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

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
