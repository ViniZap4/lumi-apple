import Foundation
import LumiKit

#if canImport(UIKit)
import UIKit

/// Actions emitted by the command-line accessory bar (shown above the iOS soft
/// keyboard while the user is typing a `/pattern` or `?pattern`).
enum VimCommandLineAccessoryAction: Sendable, Hashable {
    case cancel
    case done
}

/// `UIToolbar` variant shown above the iOS / iPadOS / visionOS soft keyboard
/// while the editor is in `VimMode.commandLine`. It mirrors the engine's
/// prefix and pattern buffer as labels (no `UITextField` — all input still
/// flows through the engine via the keyboard), and offers Cancel / Done
/// shortcuts so a thumb can exit command-line mode without reaching for ESC.
final class VimCommandLineAccessoryBar: UIToolbar {
    var onTap: ((VimCommandLineAccessoryAction) -> Void)?

    private let bufferLabel = UILabel()

    /// Current prefix character (`/` or `?`). Re-set on every theme update; the
    /// label is rebuilt to combine prefix + buffer.
    var prefix: Character = "/" {
        didSet { refreshLabel() }
    }
    var buffer: String = "" {
        didSet { refreshLabel() }
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        autoresizingMask = .flexibleWidth
        configureItems()
        sizeToFit()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("VimCommandLineAccessoryBar is not storyboard-loadable")
    }

    private func configureItems() {
        let cancel = UIBarButtonItem(primaryAction: UIAction(title: "Cancel") { [weak self] _ in
            self?.onTap?(.cancel)
        })
        bufferLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        bufferLabel.textAlignment = .center
        let labelItem = UIBarButtonItem(customView: bufferLabel)
        let done = UIBarButtonItem(primaryAction: UIAction(title: "Done") { [weak self] _ in
            self?.onTap?(.done)
        })
        items = [
            cancel,
            UIBarButtonItem.flexibleSpace(),
            labelItem,
            UIBarButtonItem.flexibleSpace(),
            done
        ]
        refreshLabel()
    }

    private func refreshLabel() {
        bufferLabel.text = "\(prefix)\(buffer)"
        bufferLabel.sizeToFit()
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
        bufferLabel.textColor = UIColor(theme.text)
    }
}
#endif
