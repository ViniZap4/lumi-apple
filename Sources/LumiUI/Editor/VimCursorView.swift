import Foundation
import LumiKit

#if canImport(AppKit)
import AppKit
typealias CursorPlatformView = NSView
#elseif canImport(UIKit)
import UIKit
typealias CursorPlatformView = UIView
#endif

/// The vim cursor, drawn over the text view as a non-interactive subview
/// sized to the character cell under the cursor (TextKit 2 segment
/// frame), so wide glyphs and emoji get a wide block and an empty line /
/// end of line get one cell. Block shapes redraw the character in the
/// background colour so it stays readable ("inverted").
///
/// It never takes focus, never receives clicks and is hidden from
/// accessibility — the text view stays the only responder.
final class VimCursorView: CursorPlatformView {
    var shape: VimCursorShape = .block { didSet { if shape != oldValue { redraw() } } }
    var color: PlatformColor = .systemBlue { didSet { redraw() } }
    /// The character under the cursor, already in the "inverted" colour.
    var glyph: NSAttributedString? { didSet { redraw() } }
    /// Caret / underline thickness in points.
    var thickness: CGFloat = 2

    private func redraw() {
        #if canImport(AppKit)
        needsDisplay = true
        #else
        setNeedsDisplay()
        #endif
    }

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        paint(in: bounds)
    }
    #else
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ rect: CGRect) {
        paint(in: bounds)
    }
    #endif

    /// Shape geometry inside the cell (exposed for tests).
    static func shapeRect(_ shape: VimCursorShape, in r: CGRect, thickness: CGFloat) -> CGRect {
        switch shape {
        case .block, .hollowBlock: return r
        case .halfBlock: return CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
        case .underline: return CGRect(x: r.minX, y: r.maxY - thickness, width: r.width, height: thickness)
        case .bar: return CGRect(x: r.minX, y: r.minY, width: thickness, height: r.height)
        case .hidden: return .zero
        }
    }

    private func paint(in r: CGRect) {
        let area = Self.shapeRect(shape, in: r, thickness: thickness)
        switch shape {
        case .hidden:
            return
        case .hollowBlock:
            color.setStroke()
            #if canImport(AppKit)
            let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            #else
            let path = UIBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            #endif
            path.lineWidth = 1
            path.stroke()
        case .block, .halfBlock:
            color.setFill()
            fill(area)
            if let glyph {
                // Clip to the filled part: the text view's own glyph shows
                // above a half block, the inverted one inside it.
                withClip(area) { glyph.draw(at: r.origin) }
            }
        case .underline, .bar:
            color.setFill()
            fill(area)
        }
    }

    private func fill(_ rect: CGRect) {
        #if canImport(AppKit)
        rect.fill()
        #else
        UIRectFill(rect)
        #endif
    }

    private func withClip(_ rect: CGRect, _ body: () -> Void) {
        #if canImport(AppKit)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        body()
        NSGraphicsContext.restoreGraphicsState()
        #else
        guard let ctx = UIGraphicsGetCurrentContext() else { body(); return }
        ctx.saveGState()
        ctx.clip(to: rect)
        body()
        ctx.restoreGState()
        #endif
    }
}

/// Colours for the cursor, from the theme.
struct VimCursorColors {
    var normal: PlatformColor
    var insert: PlatformColor
    var replace: PlatformColor
    var inverted: PlatformColor

    func color(for shape: VimCursorShape, mode: VimMode) -> PlatformColor {
        switch mode {
        case .insert: return insert
        case .replace: return replace
        default: return shape == .underline ? replace : normal
        }
    }
}
