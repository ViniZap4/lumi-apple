import SwiftUI
import LumiKit

// MARK: - View switch (Reading | Live | Source, Board | Source, …)

/// Compact segmented switch with a sliding selection. The views come
/// from the note-view registry, so any kind that registers several views
/// (kanban Board ⇄ Source, canvas Canvas ⇄ Source) gets one for free.
public struct ViewSwitchControl: View {
    let views: [NoteViewMode]
    let selection: NoteViewMode
    let canEdit: Bool
    var compact = false
    let onSelect: (NoteViewMode) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.lumiMotion) private var motion
    @Namespace private var pill
    @State private var hover: NoteViewMode?

    public init(views: [NoteViewMode], selection: NoteViewMode, canEdit: Bool, compact: Bool = false,
                onSelect: @escaping (NoteViewMode) -> Void) {
        self.views = views
        self.selection = selection
        self.canEdit = canEdit
        self.compact = compact
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(views, id: \.self) { view in
                let selected = view == selection
                let enabled = canEdit || !view.isEditing
                Button {
                    onSelect(view)
                } label: {
                    Text(view.label)
                        .font(.system(size: compact ? 10.5 : 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? theme.text : (enabled ? theme.textDim : theme.textDim.opacity(0.45)))
                        .padding(.horizontal, compact ? 7 : 10)
                        .frame(height: compact ? 18 : 22)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: compact ? 5 : 6, style: .continuous)
                                    .fill(theme.background)
                                    .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 1.5, y: 0.5)
                                    .overlay(RoundedRectangle(cornerRadius: compact ? 5 : 6, style: .continuous).stroke(theme.border.opacity(0.6), lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            } else if hover == view, enabled {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.text.opacity(0.05))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .onHover { hover = $0 ? view : (hover == view ? nil : hover) }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: compact ? 7 : 8, style: .continuous).fill(theme.text.opacity(0.06)))
        .animation(motion ? .smooth(duration: 0.12) : nil, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }
}

// MARK: - Pane header

/// Slim header of a secondary pane: folder / title, the view switch
/// (only when the note offers several views) and close.
public struct PaneHeaderBar: View {
    let title: String
    let folder: String
    let views: [NoteViewMode]
    let selection: NoteViewMode
    let canEdit: Bool
    let focused: Bool
    var badge: String?
    /// Kind glyph before the title (doc / board / canvas).
    var icon: String?
    /// tmux-style zoom: the pane fills the note area.
    var zoomed: Bool
    /// Zoom / unzoom (button, double-click); nil hides the button.
    var onZoom: (() -> Void)?
    let onSelect: (NoteViewMode) -> Void
    let onClose: () -> Void
    @Environment(\.theme) private var theme
    @State private var hoverClose = false
    @State private var hoverZoom = false

    public init(title: String, folder: String, views: [NoteViewMode], selection: NoteViewMode, canEdit: Bool,
                focused: Bool, badge: String? = nil, icon: String? = nil, zoomed: Bool = false, onZoom: (() -> Void)? = nil,
                onSelect: @escaping (NoteViewMode) -> Void, onClose: @escaping () -> Void) {
        self.title = title
        self.folder = folder
        self.views = views
        self.selection = selection
        self.canEdit = canEdit
        self.focused = focused
        self.badge = badge
        self.icon = icon
        self.zoomed = zoomed
        self.onZoom = onZoom
        self.onSelect = onSelect
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(focused ? theme.primary : theme.textDim.opacity(0.35))
                .frame(width: 5, height: 5)
            if !folder.isEmpty {
                Text(folder.split(separator: "/").joined(separator: " / ") + " /")
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textDim)
            }
            Text(title)
                .font(ShellFont.chromeBold)
                .foregroundStyle(focused ? theme.text : theme.textDim)
                .lineLimit(1)
                .truncationMode(.tail)
            if zoomed { ZoomBadge() }
            if let badge {
                Text(badge)
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 6)
            if views.count > 1 {
                ViewSwitchControl(views: views, selection: selection, canEdit: canEdit, compact: true, onSelect: onSelect)
            }
            if let onZoom {
                PaneZoomButton(zoomed: zoomed, action: onZoom)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(hoverClose ? theme.text : theme.textDim)
                    .frame(width: 20, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(hoverClose ? theme.text.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverClose = $0 }
            .help("Close pane (⌃w q · :q)")
            .accessibilityLabel("Close pane")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 30)
        .background(focused ? theme.text.opacity(theme.isDark ? 0.035 : 0.025) : Color.clear)
        .overlay(alignment: .bottom) { Hairline() }
        // Double-click the header: zoom (buttons inside keep their clicks).
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onZoom?() }
    }
}

/// "zoomed" pill (pane header, note bar, status line).
public struct ZoomBadge: View {
    @Environment(\.theme) private var theme
    public init() {}
    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 8, weight: .bold))
            Text("zoomed")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(theme.primary)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(Capsule().fill(theme.primary.opacity(0.14)))
        .fixedSize()
        .accessibilityLabel("Pane zoomed")
    }
}

/// Zoom / unzoom button (⌃w z).
public struct PaneZoomButton: View {
    let zoomed: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hover = false

    public init(zoomed: Bool, action: @escaping () -> Void) {
        self.zoomed = zoomed
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(zoomed ? theme.primary : (hover ? theme.text : theme.textDim))
                .frame(width: 20, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(zoomed ? theme.primary.opacity(0.12) : (hover ? theme.text.opacity(0.08) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(zoomed ? "Unzoom (⌃w z · :zoom · double-click the header)" : "Zoom this pane (⌃w z · :zoom · double-click the header)")
        .accessibilityLabel(zoomed ? "Unzoom pane" : "Zoom pane")
    }
}

/// Where a dragged note will land on a pane: the half it will take
/// (edges) or the whole pane (centre), with a caption.
public struct PaneDropHighlight: View {
    let zone: PaneDropZone
    @Environment(\.theme) private var theme

    public init(zone: PaneDropZone) { self.zone = zone }

    public var body: some View {
        GeometryReader { geo in
            let r = zone.highlight
            let rect = CGRect(x: r.x * geo.size.width, y: r.y * geo.size.height,
                              width: r.width * geo.size.width, height: r.height * geo.size.height).insetBy(dx: 4, dy: 4)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.primary.opacity(0.14))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.primary.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: zone == .center ? [6, 4] : []))
                Label(zone.label, systemImage: Self.symbol(zone))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(theme.background.opacity(0.92)))
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    public static func symbol(_ zone: PaneDropZone) -> String {
        switch zone {
        case .left: return "rectangle.lefthalf.inset.filled"
        case .right: return "rectangle.righthalf.inset.filled"
        case .top: return "rectangle.tophalf.inset.filled"
        case .bottom: return "rectangle.bottomhalf.inset.filled"
        case .center: return "rectangle.inset.filled"
        }
    }
}

/// Inline row actions in the explorer (hovered / selected note): Open,
/// Open right, Open below.
public struct ExplorerRowActions: View {
    let onOpen: () -> Void
    let onRight: () -> Void
    let onBelow: () -> Void
    @Environment(\.theme) private var theme

    public init(onOpen: @escaping () -> Void, onRight: @escaping () -> Void, onBelow: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onRight = onRight
        self.onBelow = onBelow
    }

    public static let items: [(symbol: String, help: String)] = [
        ("arrow.up.right.square", "Open (⏎)"),
        ("rectangle.righthalf.inset.filled", "Open right (⌃v)"),
        ("rectangle.bottomhalf.inset.filled", "Open below (⌃s)"),
    ]

    public var body: some View {
        HStack(spacing: 2) {
            RowActionButton(symbol: Self.items[0].symbol, help: Self.items[0].help, action: onOpen)
            RowActionButton(symbol: Self.items[1].symbol, help: Self.items[1].help, action: onRight)
            RowActionButton(symbol: Self.items[2].symbol, help: Self.items[2].help, action: onBelow)
        }
        .padding(.horizontal, 3)
        .frame(height: ShellMetrics.rowHeight - 4)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.overlayBackground.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(theme.border.opacity(0.7), lineWidth: 0.5))
    }
}

struct RowActionButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(hover ? theme.primary : theme.textDim)
                .frame(width: 22, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(hover ? theme.primary.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Explorer row

/// One explorer row (yazi look): icon, name, folder count, cursor bar.
/// Shared by the full-screen explorer and the floating one.
public struct ExplorerRowLabel: View {
    let name: String
    let isFolder: Bool
    let count: Int
    let isCursor: Bool
    let active: Bool
    let isOpen: Bool
    let hidden: Bool
    var icon: String?
    @Environment(\.theme) private var theme

    public init(name: String, isFolder: Bool, count: Int, isCursor: Bool, active: Bool, isOpen: Bool, hidden: Bool,
                icon: String? = nil) {
        self.icon = icon
        self.name = name
        self.isFolder = isFolder
        self.count = count
        self.isCursor = isCursor
        self.active = active
        self.isOpen = isOpen
        self.hidden = hidden
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon ?? (isFolder ? "folder" : "doc.text"))
                .font(.system(size: 10.5))
                .foregroundStyle(isFolder ? theme.accent.opacity(0.9) : theme.textDim)
                .frame(width: 14)
            Text(name)
                .font(isFolder ? ShellFont.rowBold : ShellFont.row)
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if isFolder, count > 0 || icon == nil {
                Text("\(count)")
                    .font(ShellFont.small)
                    .foregroundStyle(theme.textDim)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(height: ShellMetrics.rowHeight)
        .background(alignment: .leading) {
            if isCursor {
                ZStack(alignment: .leading) {
                    Rectangle().fill(active ? theme.selectionRow : theme.text.opacity(0.06))
                    if active {
                        Rectangle().fill(theme.accent).frame(width: 2)
                    }
                }
            }
        }
    }

    private var nameColor: Color {
        if isOpen { return theme.primary }
        let base = isFolder ? theme.accent : theme.text
        return hidden ? base.opacity(0.55) : base
    }
}

// MARK: - Floating panel (floating explorer)

/// Centred overlay (about 80% × 80%) on a scrim: the floating explorer's
/// frame (SPEC-PARTE2 §2). A click on the scrim dismisses. The host adds
/// the scale / fade transition (instant under Reduce Motion).
public struct FloatingPanel<Content: View, Footer: View>: View {
    let title: String
    let path: String
    let hints: [(String, String)]
    /// Narrow window: a full-height sheet instead of the centred card.
    var compact = false
    let onDismiss: () -> Void
    let content: Content
    let footer: Footer
    @Environment(\.theme) private var theme

    public init(title: String, path: String, hints: [(String, String)], compact: Bool = false, onDismiss: @escaping () -> Void,
                @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.compact = compact
        self.title = title
        self.path = path
        self.hints = hints
        self.onDismiss = onDismiss
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(theme.isDark ? 0.42 : 0.12)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                    .accessibilityHidden(true)
                if compact {
                    panel
                        .frame(width: geo.size.width - 12, height: geo.size.height - 8)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                } else {
                    panel
                        .frame(width: max(360, geo.size.width * 0.8), height: max(260, geo.size.height * 0.8))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(ShellFont.chromeBold)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(path)
                    .font(ShellFont.chrome)
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                ForEach(Array(hints.enumerated()), id: \.offset) { _, h in
                    HStack(spacing: 4) {
                        KeyCap(h.0)
                        Text(h.1).font(ShellFont.small).foregroundStyle(theme.textDim)
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .overlay(alignment: .bottom) { Hairline() }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(ElevatedSurface(radius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {} // clicks inside never reach the scrim
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Floating explorer")
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - Hover card

/// The hover link preview card (SPEC-PARTE2 §4): a note's title, folder
/// and updated time over a compact rendering of its first ~40 lines, or
/// a URL card for external links (no fetch). Open / Split / close.
public struct HoverCardView: View {
    public enum Kind {
        case note(title: String, folder: String, updated: String, body: String?, truncated: Bool, error: String?)
        case missing(path: String)
        case external(LinkRouting.URLCard, href: String)
    }

    let kind: Kind
    let keyboard: Bool
    let scale: Double
    let fontFamily: MarkdownFontFamily
    let onOpen: () -> Void
    let onSplit: (() -> Void)?
    let onClose: () -> Void
    var onScrollView: ((MarkdownPlatformScrollView) -> Void)?
    /// Test seam: render the excerpt with another view (offscreen PNGs).
    var excerptOverride: ((String) -> AnyView)?
    /// A canvas / board target: drawn as a mini canvas / board instead of
    /// its raw text.
    public var structured: StructuredMini?
    @Environment(\.theme) private var theme

    public static let size = CGSize(width: 460, height: 360)

    public init(kind: Kind, keyboard: Bool, scale: Double = 1, fontFamily: MarkdownFontFamily = .system,
                onOpen: @escaping () -> Void, onSplit: (() -> Void)?, onClose: @escaping () -> Void,
                onScrollView: ((MarkdownPlatformScrollView) -> Void)? = nil) {
        self.kind = kind
        self.keyboard = keyboard
        self.scale = scale
        self.fontFamily = fontFamily
        self.onOpen = onOpen
        self.onSplit = onSplit
        self.onClose = onClose
        self.onScrollView = onScrollView
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 11)
                .padding(.bottom, 9)
            Hairline()
            content
            Hairline()
            actions
                .padding(.horizontal, 10)
                .frame(height: 32)
        }
        .frame(width: Self.size.width)
        .frame(maxHeight: isNote ? Self.size.height : nil)
        .background(ElevatedSurface(radius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Link preview")
    }

    private var isNote: Bool {
        if case .note = kind { return true }
        return false
    }

    @ViewBuilder
    private var header: some View {
        switch kind {
        case let .note(title, folder, updated, _, _, _):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if let structured {
                        Image(systemName: structured.kind.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textDim)
                    }
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 9))
                    Text(folder.isEmpty ? "/" : folder)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if !updated.isEmpty {
                        Text("·").opacity(0.5)
                        Text("updated \(updated)").lineLimit(1)
                    }
                }
                .font(ShellFont.small)
                .foregroundStyle(theme.textDim)
            }
        case let .missing(path):
            VStack(alignment: .leading, spacing: 3) {
                Text(NoteTree.stem(path))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.textDim)
                Text("no note at \(path) yet")
                    .font(ShellFont.small)
                    .foregroundStyle(theme.warning)
            }
        case let .external(card, _):
            HStack(spacing: 10) {
                Image(systemName: card.mail ? "envelope" : (card.secure ? "lock" : "globe"))
                    .font(.system(size: 14))
                    .foregroundStyle(card.secure || card.mail ? theme.info : theme.warning)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.host)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    if !card.path.isEmpty {
                        Text(card.path)
                            .font(ShellFont.small)
                            .foregroundStyle(theme.textDim)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case let .note(title, _, _, body, truncated, error):
            if let structured {
                StructuredMiniView(structured)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let body {
                VStack(spacing: 0) {
                    Group {
                        if let excerptOverride {
                            excerptOverride(body)
                        } else {
                            MarkdownReader(title: title, text: body, scale: 0.84 * scale, fontFamily: fontFamily,
                                           readingWidth: 420, showsHeader: false)
                                .environment(\.markdownLite, true)
                                .environment(\.markdownScrollViewSink, onScrollView.map { f in MarkdownScrollViewSink { f($0) } })
                        }
                    }
                    .frame(maxHeight: .infinity)
                    if truncated {
                        Text("…")
                            .font(ShellFont.small)
                            .foregroundStyle(theme.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 4)
                    }
                }
            } else if let error {
                Text(error)
                    .font(ShellFont.chrome)
                    .foregroundStyle(theme.textDim)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("loading…").font(ShellFont.chrome).foregroundStyle(theme.textDim)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            }
        case .missing:
            Text("Open creates nothing — follow the link from the note to create it.")
                .font(ShellFont.small)
                .foregroundStyle(theme.textDim)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .external(_, href):
            Text(href)
                .font(ShellFont.small)
                .foregroundStyle(theme.textDim)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if case .external = kind {
                cardButton("Open in browser", keys: keyboard ? "⏎" : nil, prominent: true, action: onOpen)
            } else if case .note = kind {
                cardButton("Open", keys: keyboard ? "⏎" : nil, prominent: true, action: onOpen)
                if let onSplit { cardButton("Split", keys: keyboard ? "⌃w f" : nil, prominent: false, action: onSplit) }
            }
            Spacer(minLength: 6)
            if keyboard, isNote {
                HStack(spacing: 4) {
                    KeyCap("j k")
                    Text("scroll").font(ShellFont.small).foregroundStyle(theme.textDim)
                }
            }
            cardButton("Close", keys: keyboard ? "esc" : nil, prominent: false, action: onClose)
        }
    }

    private func cardButton(_ label: String, keys: String?, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 11.5, weight: prominent ? .semibold : .medium))
                if let keys {
                    Text(keys).font(ShellFont.small).opacity(0.7)
                }
            }
            .foregroundStyle(prominent ? theme.primary : theme.textDim)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(prominent ? theme.primary.opacity(0.12) : theme.text.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
