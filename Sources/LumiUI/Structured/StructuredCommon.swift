import SwiftUI
import LumiKit
#if canImport(AppKit)
import AppKit
#endif

/// Where a link / file node opens (SPEC-PARTE2 §6 `gf` vs `⌃w f`).
public enum StructuredOpenTarget: Sendable, Equatable {
    case current
    case split
    /// An http(s) URL for the browser.
    case external
}

/// The key handler of the structured view on screen, for hosts that
/// route keys themselves (the macOS shell's `NSEvent` monitor sees keys
/// before SwiftUI). Set while a board / canvas is visible.
@MainActor
public enum StructuredKeyRouting {
    public private(set) static var current: ((StructuredKey) -> Bool)?
    private static var owner: ObjectIdentifier?

    public static func install(_ owner: AnyObject, _ handler: @escaping (StructuredKey) -> Bool) {
        self.owner = ObjectIdentifier(owner)
        current = handler
    }

    public static func uninstall(_ owner: AnyObject) {
        guard self.owner == ObjectIdentifier(owner) else { return }
        self.owner = nil
        current = nil
    }
}

extension StructuredKey {
    /// SwiftUI key press → structured key.
    init?(press: KeyPress) {
        let mods = press.modifiers
        let name: String
        switch press.key {
        case .upArrow: name = "ArrowUp"
        case .downArrow: name = "ArrowDown"
        case .leftArrow: name = "ArrowLeft"
        case .rightArrow: name = "ArrowRight"
        case .return: name = "Enter"
        case .escape: name = "Escape"
        case .delete: name = "Backspace"
        case .deleteForward: name = "Delete"
        case .tab: name = "Tab"
        default:
            guard !press.characters.isEmpty else { return nil }
            var c = press.characters
            if mods.contains(.control) {
                // ⌃letter may arrive as a control code.
                if let v = c.unicodeScalars.first?.value, v >= 1, v <= 26, let s = Unicode.Scalar(v + 0x60) { c = String(s) }
                c = c.lowercased()
            }
            if c == "\u{19}" { name = "Tab" } else { name = c }
        }
        self.init(name, shift: mods.contains(.shift), ctrl: mods.contains(.control), meta: mods.contains(.command), alt: mods.contains(.option))
    }
}

/// Shared look for the structured views.
enum StructuredStyle {
    /// JSON Canvas presets 1–6 (Obsidian's palette).
    static func preset(_ n: Int) -> Color {
        switch n {
        case 1: return Color(hex: "#fb464c")
        case 2: return Color(hex: "#e9973f")
        case 3: return Color(hex: "#e0de71")
        case 4: return Color(hex: "#44cf6e")
        case 5: return Color(hex: "#53dfdd")
        default: return Color(hex: "#a882ff")
        }
    }

    static let presetNames = ["red", "orange", "yellow", "green", "cyan", "purple"]

    static func color(_ c: CanvasColor?) -> Color? {
        switch c {
        case let .preset(n)?: return preset(n)
        case let .hex(h)?: return Color(hex: expandHex(h))
        case nil: return nil
        }
    }

    static func expandHex(_ h: String) -> String {
        let s = h.dropFirst()
        guard s.count == 3 else { return h }
        return "#" + s.map { "\($0)\($0)" }.joined()
    }

    /// Motion for card moves / viewport easing (SPEC-PARTE2 §1).
    static func animation(_ enabled: Bool, _ duration: Double = 0.18) -> Animation? {
        enabled ? .smooth(duration: duration) : nil
    }
}

/// Parsed-markdown cache for card / node bodies (parsing on every render
/// of a large board is wasteful).
@MainActor
final class ProseCache {
    static let shared = ProseCache()
    private var docs: [String: MarkdownDocument] = [:]
    private var order: [String] = []

    func document(_ text: String) -> MarkdownDocument {
        if let d = docs[text] { return d }
        let d = MarkdownParser.parse(text)
        docs[text] = d
        order.append(text)
        if order.count > 400 {
            docs[order.removeFirst()] = nil
        }
        return d
    }
}

/// The shared prose renderer, compact variant (kanban cards, canvas text
/// nodes, file previews): same blocks and theme as the reader, smaller
/// scale, no stagger, heavy embeds collapsed.
struct CompactProse: View {
    let text: String
    var scale: Double = 0.86

    var body: some View {
        MarkdownView(ProseCache.shared.document(text))
            .environment(\.markdownScale, scale)
            .environment(\.markdownStagger, false)
            .environment(\.markdownLite, true)
    }
}
