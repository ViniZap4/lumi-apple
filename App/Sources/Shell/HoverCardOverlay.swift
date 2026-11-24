import SwiftUI
import LumiKit
import LumiUI

/// Places the hover card next to its link (below it, or above when there
/// is no room) and morphs it out of the link (scale from the link's
/// position + fade; instant under Reduce Motion).
struct HoverCardOverlay: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        GeometryReader { geo in
            if let card = appState.hoverCard {
                let size = CGSize(width: HoverCardView.size.width, height: card.isNote ? HoverCardView.size.height : 150)
                let x = min(max(8, card.anchor.minX - 12), max(8, geo.size.width - size.width - 8))
                let below = card.anchor.maxY + 6
                let y = below + size.height <= geo.size.height - 8 ? below : max(8, card.anchor.minY - size.height - 6)
                let anchorPoint = UnitPoint(x: max(0, min(1, (card.anchor.midX - x) / size.width)),
                                            y: y >= below ? 0 : 1)
                Self.card(HoverCardView(
                    kind: card.kind(appState),
                    keyboard: card.keyboard,
                    scale: appState.preferences.readingScale,
                    fontFamily: appState.preferences.readingFontFamily.markdownFamily,
                    onOpen: { appState.hoverOpen(.current) },
                    onSplit: card.isNote ? { appState.hoverOpen(.vsplit) } : nil,
                    onClose: { appState.closeHoverCard() },
                    onScrollView: { appState.hoverCoordinator.attach(scrollView: $0) }
                ), structured: card.structured)
                .onHover { inside in
                    if inside { appState.hoverIntentStore?.hold() } else if !card.keyboard { appState.hoverIntentStore?.leave() }
                }
                .offset(x: x, y: y)
                .id(card.id)
                .transition(appState.transition(.scale(scale: 0.4, anchor: anchorPoint).combined(with: .opacity)))
            }
        }
        .animation(appState.motionEnabled ? .spring(response: 0.22, dampingFraction: 0.82) : nil, value: appState.hoverCard?.id)
    }

    static func card(_ v: HoverCardView, structured: StructuredMini?) -> HoverCardView {
        var v = v
        v.structured = structured
        return v
    }
}

extension HoverCardState {
    var isNote: Bool {
        if case .note = target { return true }
        return false
    }

    @MainActor
    func kind(_ appState: AppState) -> HoverCardView.Kind {
        switch target {
        case let .note(n):
            let path = n.path.isEmpty ? n.id : n.path
            let title = n.title.isEmpty ? NoteTree.stem(path) : n.title
            return .note(title: title, folder: NoteTree.dirOf(path), updated: HoverPreview.updatedLabel(n.updatedAt),
                         body: body, truncated: truncated, error: error)
        case let .missing(p):
            return .missing(path: p)
        case let .external(u):
            if let card = LinkRouting.urlCard(u) { return .external(card, href: u) }
            return .missing(path: u)
        }
    }
}
