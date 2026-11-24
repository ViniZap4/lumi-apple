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
    let onSelect: (NoteViewMode) -> Void
    let onClose: () -> Void
    @Environment(\.theme) private var theme
    @State private var hoverClose = false

    public init(title: String, folder: String, views: [NoteViewMode], selection: NoteViewMode, canEdit: Bool,
                focused: Bool, badge: String? = nil,
                onSelect: @escaping (NoteViewMode) -> Void, onClose: @escaping () -> Void) {
        self.title = title
        self.folder = folder
        self.views = views
        self.selection = selection
        self.canEdit = canEdit
        self.focused = focused
        self.badge = badge
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
            Text(title)
                .font(ShellFont.chromeBold)
                .foregroundStyle(focused ? theme.text : theme.textDim)
                .lineLimit(1)
                .truncationMode(.tail)
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
    @Environment(\.theme) private var theme

    public init(name: String, isFolder: Bool, count: Int, isCursor: Bool, active: Bool, isOpen: Bool, hidden: Bool) {
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
            Image(systemName: isFolder ? "folder" : "doc.text")
                .font(.system(size: 10.5))
                .foregroundStyle(isFolder ? theme.accent.opacity(0.9) : theme.textDim)
                .frame(width: 14)
            Text(name)
                .font(isFolder ? ShellFont.rowBold : ShellFont.row)
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if isFolder {
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
    let onDismiss: () -> Void
    let content: Content
    let footer: Footer
    @Environment(\.theme) private var theme

    public init(title: String, path: String, hints: [(String, String)], onDismiss: @escaping () -> Void,
                @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
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
                Color.black.opacity(theme.isDark ? 0.42 : 0.18)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                    .accessibilityHidden(true)
                panel
                    .frame(width: max(360, geo.size.width * 0.8), height: max(260, geo.size.height * 0.8))
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
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
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
            if let body {
                VStack(spacing: 0) {
                    MarkdownReader(title: title, text: body, scale: 0.84 * scale, fontFamily: fontFamily,
                                   readingWidth: 420, showsHeader: false)
                        .environment(\.markdownLite, true)
                        .environment(\.markdownScrollViewSink, onScrollView.map { f in MarkdownScrollViewSink { f($0) } })
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
