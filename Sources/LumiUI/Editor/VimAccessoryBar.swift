import Foundation
import LumiKit

#if canImport(UIKit)
import UIKit

/// Buttons exposed on the soft-keyboard accessory bar. `colon`/`slash` are
/// placeholders for ex commands and search, which arrive in later phases —
/// in the meantime they just inject the literal `:` or `/` character.
enum VimAccessoryAction: Sendable, Hashable {
    case escape
    case colon
    case slash
    case semicolon
    case comma
}

/// `UIToolbar` shown above the iOS / iPadOS / visionOS soft keyboard while the
/// editor is focused. Hardware keyboards display this as the shortcut bar at
/// the bottom edge, so the same bar works in both contexts.
final class VimAccessoryBar: UIToolbar {
    var onTap: ((VimAccessoryAction) -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        autoresizingMask = .flexibleWidth
        configureItems()
        sizeToFit()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("VimAccessoryBar is not storyboard-loadable")
    }

    private func configureItems() {
        let esc = UIBarButtonItem(primaryAction: UIAction(title: "ESC") { [weak self] _ in
            self?.onTap?(.escape)
        })
        let colon = UIBarButtonItem(primaryAction: UIAction(title: ":") { [weak self] _ in
            self?.onTap?(.colon)
        })
        let slash = UIBarButtonItem(primaryAction: UIAction(title: "/") { [weak self] _ in
            self?.onTap?(.slash)
        })
        let semi = UIBarButtonItem(primaryAction: UIAction(title: ";") { [weak self] _ in
            self?.onTap?(.semicolon)
        })
        let comma = UIBarButtonItem(primaryAction: UIAction(title: ",") { [weak self] _ in
            self?.onTap?(.comma)
        })

        items = [
            esc,
            UIBarButtonItem.flexibleSpace(),
            colon,
            slash,
            semi,
            comma
        ]
    }

    func apply(theme: ThemeTokens) {
        let appearance = UIToolbarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(theme.overlayBackground)
        appearance.shadowColor = UIColor(theme.border)
        standardAppearance = appearance
        scrollEdgeAppearance = appearance
        compactAppearance = appearance
        compactScrollEdgeAppearance = appearance
        tintColor = UIColor(theme.primary)
    }
}
#endif
