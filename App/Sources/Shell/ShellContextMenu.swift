import SwiftUI
import LumiKit
import LumiUI

extension View {
    /// Right-click (and ⌃-click, Shift+F10 via `AppState`) menu with the
    /// same actions as the keys, each showing its key. `key` names the
    /// target so the keyboard can open the menu on the cursor row.
    func shellContextMenu(key: String, items: @escaping @MainActor () -> [ShellMenuItem]) -> some View {
        #if os(macOS)
        overlay(ContextMenuCatcher(key: key, items: items))
        #else
        contextMenu {
            ForEach(items()) { item in
                if item.separatorAbove { Divider() }
                Button(role: item.danger ? .destructive : nil) { item.run() } label: {
                    Text(item.keys.isEmpty ? item.label : "\(item.label)   \(item.keys)")
                }
                .disabled(!item.enabled)
            }
        }
        #endif
    }
}

#if os(macOS)
import AppKit

/// Weak registry of the mounted catchers, so Shift+F10 can open the menu
/// of the cursor row from the keyboard.
@MainActor
enum ContextMenuCatchers {
    private static var views: [String: WeakCatcher] = [:]
    private struct WeakCatcher { weak var view: ContextMenuCatcherView? }

    static func register(_ view: ContextMenuCatcherView, key: String) {
        views[key] = WeakCatcher(view: view)
        if views.count > 512 { views = views.filter { $0.value.view != nil } }
    }

    static func view(for key: String) -> ContextMenuCatcherView? {
        guard let v = views[key]?.view, v.window != nil else { return nil }
        return v
    }
}

struct ContextMenuCatcher: NSViewRepresentable {
    let key: String
    let items: @MainActor () -> [ShellMenuItem]

    func makeNSView(context: Context) -> ContextMenuCatcherView {
        let v = ContextMenuCatcherView()
        v.items = items
        ContextMenuCatchers.register(v, key: key)
        return v
    }

    func updateNSView(_ v: ContextMenuCatcherView, context: Context) {
        v.items = items
        ContextMenuCatchers.register(v, key: key)
    }
}

/// Transparent overlay that only claims right / ⌃ clicks; left clicks,
/// drags and hovers fall through to the SwiftUI row underneath.
final class ContextMenuCatcherView: NSView {
    var items: (@MainActor () -> [ShellMenuItem])?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let isMenuClick = event.type == .rightMouseDown || event.type == .rightMouseUp
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        return isMenuClick ? super.hitTest(point) : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = makeMenu() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.mouseDown(with: event)
        }
    }

    /// Keyboard (Shift+F10): open at the row, left-aligned under it.
    func popUpFromKeyboard() {
        guard let menu = makeMenu() else { return }
        menu.popUp(positioning: menu.items.first, at: NSPoint(x: 24, y: bounds.midY), in: self)
    }

    func makeMenu() -> NSMenu? {
        guard let items = items?(), !items.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.separatorAbove, !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(ClosureMenuItem(item))
        }
        return menu
    }
}

/// NSMenuItem running a closure; the shell key is its key equivalent
/// (shown on the right, and typed while the menu is open it picks it).
final class ClosureMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(_ item: ShellMenuItem) {
        run = item.run
        let key: String
        switch item.keys {
        case "⏎": key = "\r"
        case let k where k.count == 1: key = k
        default: key = ""
        }
        super.init(title: item.label, action: #selector(fire), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = []
        isEnabled = item.enabled
        if item.danger, item.enabled {
            attributedTitle = NSAttributedString(string: item.label, attributes: [.foregroundColor: NSColor.systemRed])
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not coded") }

    @objc private func fire() {
        let run = self.run
        // After the menu's tracking loop ends.
        DispatchQueue.main.async { MainActor.assumeIsolated { run() } }
    }
}
#endif

extension AppState {
    /// Shift+F10 in the explorer: the cursor row's menu.
    func showContextMenuForCursor() {
        #if os(macOS)
        let key = explorer.nav.current?.key ?? "explorer.empty"
        (ContextMenuCatchers.view(for: key) ?? ContextMenuCatchers.view(for: "explorer.empty"))?.popUpFromKeyboard()
        #endif
    }
}
