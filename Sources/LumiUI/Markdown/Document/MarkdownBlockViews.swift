import SwiftUI
import LumiKit

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

public extension EnvironmentValues {
    /// Width the hosted attachment is laid out at (tables use it as the
    /// minimum width so they span the column like the web's `width: 100%`).
    @Entry var markdownAttachmentWidth: CGFloat = 0
}

// MARK: - Code block

/// Fenced code as the web draws it (`.md-code`): a header with the
/// language label, Copy and a wrap toggle; a highlighted body that
/// scrolls horizontally unless wrapped.
struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String

    @Environment(\.theme) private var theme
    @Environment(\.markdownScale) private var scale
    @Environment(\.markdownFontFamily) private var family
    @State private var wrapped: Bool
    @State private var copied = false
    @State private var hovering = false

    init(language: String?, code: String) {
        self.language = language
        self.code = code
        _wrapped = State(initialValue: MarkdownCodeWrapStore.isWrapped(code))
    }

    private var em: CGFloat {
        MarkdownRenderStyle(theme: theme, scale: scale, fontFamily: family).em
    }

    private var body_: String {
        var s = code
        while s.hasSuffix("\n") { s.removeLast() }
        return s.isEmpty ? " " : s
    }

    var body: some View {
        let palette = MarkdownPalette.shared(theme)
        VStack(alignment: .leading, spacing: 0) {
            header(palette)
            Rectangle().fill(Color(palette.codeBorder)).frame(height: 1)
            content(palette)
        }
        .background(Color(palette.codeBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(palette.codeBorder), lineWidth: 1))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(language ?? "code") block")
    }

    private func header(_ palette: MarkdownPalette) -> some View {
        HStack(spacing: 2) {
            Text((language ?? "text").lowercased())
                .font(.system(size: 11, design: .monospaced))
                .tracking(0.44)
                .foregroundStyle(Color(palette.marker))
            Spacer(minLength: 8)
            toolButton(copied ? "copied" : "copy", active: copied, palette: palette) {
                copy()
            }
            .help("Copy code")
            toolButton("wrap", active: wrapped, palette: palette) {
                wrapped.toggle()
                MarkdownCodeWrapStore.set(code, wrapped: wrapped)
            }
            .help(wrapped ? "Don't wrap long lines" : "Wrap long lines")
            .accessibilityAddTraits(wrapped ? .isSelected : [])
        }
        .padding(.leading, 1.0 * em)
        .padding(.trailing, 0.45 * em)
        .frame(height: max(26, 2.15 * 11 + 2))
    }

    private func toolButton(_ title: String, active: Bool, palette: MarkdownPalette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(active ? theme.primary : Color(palette.marker))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovering || active ? 1 : 0.55)
    }

    @ViewBuilder
    private func content(_ palette: MarkdownPalette) -> some View {
        let text = Text(highlighted(palette))
            .font(.system(size: 0.84 * em, design: .monospaced))
            .lineSpacing(0.84 * em * 0.42)
            .textSelection(.enabled)
            .padding(.horizontal, 1.1 * em)
            .padding(.top, 0.85 * em)
            .padding(.bottom, 0.95 * em)
        if wrapped {
            text.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal) {
                text.fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func highlighted(_ palette: MarkdownPalette) -> AttributedString {
        let source = body_
        var attr = AttributedString(source)
        attr.foregroundColor = Color(palette.text)
        let ns = source as NSString
        for token in CodeHighlighter.tokens(source, language: language) {
            guard NSMaxRange(token.range) <= ns.length,
                  let r = Range(token.range, in: source),
                  let lo = AttributedString.Index(r.lowerBound, within: attr),
                  let hi = AttributedString.Index(r.upperBound, within: attr)
            else { continue }
            let (color, italic) = Self.color(token.kind, theme: theme, palette: palette)
            attr[lo..<hi].foregroundColor = color
            if italic { attr[lo..<hi].font = .system(size: 0.84 * em, design: .monospaced).italic() }
        }
        return attr
    }

    /// Token colours: the web's `.tok-*` rules (app.css).
    static func color(_ kind: CodeHighlighter.Kind, theme: ThemeTokens, palette: MarkdownPalette) -> (Color, Bool) {
        switch kind {
        case .keyword: return (theme.secondary, false)
        case .string: return (theme.accent, false)
        case .number: return (theme.warning, false)
        case .comment: return (Color(palette.marker), true)
        case .function: return (theme.info, false)
        case .type, .heading: return (theme.primary, false)
        case .property: return (Color(MarkdownPalette.mix(palette.info, palette.text, 0.7)), false)
        case .tag, .deleted: return (theme.error, false)
        case .punctuation: return (Color(palette.dim), false)
        case .inserted: return (theme.accent, false)
        }
    }

    private func copy() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body_, forType: .string)
        #else
        UIPasteboard.general.string = body_
        #endif
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

/// Wrap toggles survive the hosted view being unmounted when it scrolls
/// away (and re-renders of the note).
@MainActor
enum MarkdownCodeWrapStore {
    private static var wrapped: Set<Int> = []
    static func isWrapped(_ code: String) -> Bool { wrapped.contains(code.hashValue) }
    static func set(_ code: String, wrapped on: Bool) {
        if on { wrapped.insert(code.hashValue) } else { wrapped.remove(code.hashValue) }
    }
}

// MARK: - Table

/// GFM table (`.md-table`): hairline frame and row rules, a tinted
/// header band, zebra rows, tabular numbers, horizontal scroll when the
/// columns don't fit.
struct MarkdownTableView: View {
    let table: MarkdownTable

    @Environment(\.theme) private var theme
    @Environment(\.markdownScale) private var scale
    @Environment(\.markdownFontFamily) private var family
    @Environment(\.markdownAttachmentWidth) private var width

    private var em: CGFloat {
        MarkdownRenderStyle(theme: theme, scale: scale, fontFamily: family).em
    }

    var body: some View {
        let palette = MarkdownPalette.shared(theme)
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { col, cell in
                        cellView(cell, col: col, header: true, palette: palette)
                    }
                }
                .background(Color(palette.tableHeader))
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { col, cell in
                            cellView(cell, col: col, header: false, palette: palette, last: index == table.rows.count - 1)
                        }
                    }
                    .background(index % 2 == 1 ? Color(palette.tableZebra) : Color.clear)
                }
            }
            .frame(minWidth: max(0, width - 2), alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(palette.rule), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("table")
    }

    private func alignment(_ col: Int) -> (Alignment, TextAlignment) {
        switch col < table.alignments.count ? table.alignments[col] : .none {
        case .right: return (.trailing, .trailing)
        case .center: return (.center, .center)
        default: return (.leading, .leading)
        }
    }

    private func cellView(_ cell: [InlineNode], col: Int, header: Bool, palette: MarkdownPalette, last: Bool = false) -> some View {
        let (frameAlign, textAlign) = alignment(col)
        let size = 0.92 * em
        return Text(InlineRenderer.render(cell, theme: theme))
            .font(.system(size: size, weight: header ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(header ? Color(palette.heading(1)) : theme.text)
            .multilineTextAlignment(textAlign)
            .lineSpacing(size * 0.25)
            .fixedSize(horizontal: header, vertical: true)
            .frame(minWidth: 40, maxWidth: header ? nil : 420, alignment: frameAlign)
            .padding(.horizontal, 0.95 * size)
            .padding(.vertical, 0.55 * size)
            .frame(maxWidth: .infinity, alignment: frameAlign)
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(Color(palette.rule)).frame(height: 1) }
            }
            .textSelection(.enabled)
    }
}

// MARK: - Image zoom

/// Click-to-zoom for reader images. One shared model: the reader shows
/// the overlay, the app's key router closes it on any key.
@MainActor
@Observable
public final class MarkdownZoom {
    public static let shared = MarkdownZoom()

    public struct Item: Equatable {
        public var url: URL
        public var caption: String?
    }

    public var item: Item?

    public func present(_ url: URL, caption: String?) { item = Item(url: url, caption: caption) }
    public func dismiss() { item = nil }
}

/// Full-pane zoomed image over a dimmed backdrop; click or any key closes.
struct MarkdownZoomOverlay: View {
    let item: MarkdownZoom.Item
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                AsyncImage(url: item.url) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if let caption = item.caption {
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(32)
        }
        .contentShape(Rectangle())
        .onTapGesture { MarkdownZoom.shared.dismiss() }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { MarkdownZoom.shared.dismiss() }
        #if os(macOS)
        .onHover { inside in if inside { NSCursor.pointingHand.set() } }
        #endif
    }
}
