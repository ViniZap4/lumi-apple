import Foundation

/// How the editor cursor is drawn.
public enum VimCursorShape: Sendable, Hashable {
    /// Solid cell over the character; the character is drawn inverted.
    case block
    /// Outline of the cell (editor not focused).
    case hollowBlock
    /// Lower half of the cell (operator-pending).
    case halfBlock
    /// Thin line under the character (replace mode, `r`).
    case underline
    /// Thin vertical caret (insert mode, plain editing).
    case bar
    /// No cursor in the text (it lives in the command line).
    case hidden
}

public struct VimCursorStyle: Sendable, Hashable {
    public var shape: VimCursorShape
    public var blinks: Bool
    /// Let the system caret draw (IME composition): our overlay hides.
    public var usesSystemCaret: Bool

    public init(shape: VimCursorShape, blinks: Bool, usesSystemCaret: Bool = false) {
        self.shape = shape
        self.blinks = blinks
        self.usesSystemCaret = usesSystemCaret
    }

    /// Blink period (seconds on, then off).
    public static let blinkInterval: TimeInterval = 0.53

    /// Mode → cursor. Pure, so the decision is unit-tested; the text
    /// views only draw what this returns.
    ///
    /// - normal: block (non-blinking), operator-pending: half block,
    ///   after `r`: underline; visual: block at the head.
    /// - insert: bar, replace: underline — both blink unless the user
    ///   asked to reduce motion.
    /// - command line / search: hidden (the caret is in the command line).
    /// - IME composition (marked text) or vim off: the system bar caret.
    /// - not focused: hollow block (insert: steady bar).
    public static func resolve(
        mode: VimMode,
        pending: VimPendingInfo = VimPendingInfo(),
        hasMarkedText: Bool = false,
        vimEnabled: Bool = true,
        isFocused: Bool = true,
        reduceMotion: Bool = false,
        blockCursor: Bool = true
    ) -> VimCursorStyle {
        if !vimEnabled || hasMarkedText {
            return VimCursorStyle(shape: .bar, blinks: !reduceMotion && isFocused, usesSystemCaret: true)
        }
        switch mode {
        case .commandLine:
            return VimCursorStyle(shape: .hidden, blinks: false)
        case .insert:
            return VimCursorStyle(shape: .bar, blinks: isFocused && !reduceMotion)
        case .replace:
            return VimCursorStyle(shape: .underline, blinks: isFocused && !reduceMotion)
        case .visual, .normal:
            guard isFocused else { return VimCursorStyle(shape: .hollowBlock, blinks: false) }
            if mode == .normal {
                if pending.awaiting == .replaceChar { return VimCursorStyle(shape: .underline, blinks: false) }
                if pending.op != nil { return VimCursorStyle(shape: .halfBlock, blinks: false) }
            }
            return VimCursorStyle(shape: blockCursor ? .block : .bar, blinks: false)
        }
    }
}
