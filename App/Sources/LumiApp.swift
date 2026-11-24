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

    static let sharedContainer: ModelContainer = {
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
                // lumi://open… (SPEC-PARTE2 §8): handled by this window,
                // never by a new one.
                .onOpenURL { appState.handleOpenURL($0) }
                .handlesExternalEvents(preferring: ["lumi"], allowing: ["lumi"])
        }
        .handlesExternalEvents(matching: ["lumi"])
        .modelContainer(Self.sharedContainer)
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appState.showSettings = true }
                    .keyboardShortcut(",", modifiers: [.command])
            }
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") { appState.toggleSidebar() }
                    .keyboardShortcut("\\", modifiers: [.command])
            }
            CommandMenu("Go") {
                Button("Command Palette…") { appState.openPalette() }
                    .keyboardShortcut("k", modifiers: [.command])
                Button("Open Note…") { appState.openPalette() }
                    .keyboardShortcut("o", modifiers: [.command])
                Divider()
                Button(appState.isEditing ? "Read Mode" : "Edit Mode") { appState.toggleEditing() }
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(appState.openBook == nil)
                Button("Live Preview") { appState.setNoteViewMode(.live) }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(!appState.isNoteOpen)
                Button("Source") { appState.setNoteViewMode(.source) }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(!appState.isNoteOpen)
                Button(appState.splitPreviewShown ? "Hide Split Preview" : "Show Split Preview") { appState.toggleSplitPreview() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(!appState.isNoteOpen)
                Button("Back to Explorer") { appState.closeNote() }
                    .disabled(!appState.isNoteOpen)
                Divider()
                Button("Keyboard Shortcuts") { appState.showHelp.toggle() }
                    .keyboardShortcut("/", modifiers: [.command])
            }
            // SPEC-LIVROS §5: ⌃⌘1–9 switch books in switcher order (⌃1–9
            // and g1–g9 also work in the explorer).
            CommandMenu("Book") {
                let shortcutBooks = appState.books.shortcutBooks
                ForEach(Array(shortcutBooks.enumerated()), id: \.element.id) { index, book in
                    Button(book.name) { appState.selectBook(number: index + 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .command])
                }
                if !shortcutBooks.isEmpty { Divider() }
                Button("Switch Book…") { appState.query(paletteFor: .books) }
                    .keyboardShortcut("0", modifiers: [.control, .command])
                Button("Book Settings…") { appState.showBookSettings = true }
                    .keyboardShortcut(",", modifiers: [.command, .option])
                    .disabled(appState.openBook == nil)
                Divider()
                Button("New Book…") { appState.showNewBook = true }
                Button("Link Folder…") { appState.showLinkFolder = true }
                Button("Manage Books…") { appState.showManageBooks = true }
                Divider()
                Button("Add Server…") { appState.showAddServer = true }
            }
        }
        #endif
    }

}
