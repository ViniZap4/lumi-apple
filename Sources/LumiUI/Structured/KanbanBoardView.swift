import SwiftUI
import LumiKit

/// Kanban Board view (SPEC-PARTE2 §5) over a `KanbanBoardModel`.
///
/// Columns side by side, cards rendered with the shared prose renderer
/// (compact). Keys: h/l j/k, H/L J/K, a/o/O, A, Enter/i, x, dd (inline
/// confirm), /, r, < >, u / ⌃r. Mouse: drag cards and columns (animated
/// reordering, Reduce Motion aware), double-click edits.
public struct KanbanBoardView: View {
    @Bindable var model: KanbanBoardModel
    let title: String
    let status: String?
    let motion: Bool
    let onSource: (() -> Void)?

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var focused: Bool
    @FocusState private var fieldFocused: Bool
    @FocusState private var filterFocused: Bool

    static let laneWidth: CGFloat = 272
    static let space = "kanban-board"

    public init(model: KanbanBoardModel, title: String = "", status: String? = nil, motion: Bool = true, onSource: (() -> Void)? = nil) {
        self.model = model
        self.title = title
        self.status = status
        self.motion = motion
        self.onSource = onSource
    }

    private var animates: Bool { motion && !systemReduceMotion }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(theme.separator)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(model.laneOrder.enumerated()), id: \.element?.id) { _, lane in
                            if let lane, let li = model.lanes.firstIndex(where: { $0.id == lane.id }) {
                                laneColumn(lane, index: li)
                                    .id(lane.id)
                            } else {
                                lanePlaceholder
                            }
                        }
                        addLaneColumn
                    }
                    .padding(16)
                    .animation(StructuredStyle.animation(animates), value: model.laneOrder.map { $0?.id })
                }
                .scrollIndicators(.automatic)
                .onChange(of: model.cur) { _, c in
                    guard model.lanes.indices.contains(c.lane) else { return }
                    withAnimation(StructuredStyle.animation(animates)) { proxy.scrollTo(model.lanes[c.lane].id) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: Self.space)
        .overlay(alignment: .topLeading) { ghost }
        .overlay(alignment: .bottom) { noticeView }
        .background(theme.background)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in
            guard let k = StructuredKey(press: press) else { return .ignored }
            return model.handleKey(k) ? .handled : .ignored
        }
        .onAppear { focused = true }
        .onChange(of: model.focusRequest) { _, _ in focused = true }
        .onChange(of: model.filterOpen) { _, open in if open { filterFocused = true } }
        .onChange(of: model.editing) { _, e in if e != nil { fieldFocused = true } }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1")
                .foregroundStyle(theme.accent)
            Text(title.isEmpty ? "Board" : title)
                .font(.headline)
                .foregroundStyle(theme.text)
                .lineLimit(1)
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(theme.textDim)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(theme.muted.opacity(0.18)))
            }
            if let p = model.pending {
                Text(p)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.accent)
            }
            Spacer(minLength: 8)
            if model.filterOpen || !model.filter.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(theme.textDim)
                    TextField("Filter cards", text: $model.filter)
                        .textFieldStyle(.plain)
                        .frame(width: 160)
                        .focused($filterFocused)
                        .onSubmit { model.submitFilter() }
                        .onKeyPress(.escape) {
                            model.clearFilter()
                            return .handled
                        }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.overlayBackground))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border, lineWidth: 0.5))
            }
            if let onSource {
                ViewToggle(selection: "Board", onSource: onSource)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    // MARK: - Lanes

    private func laneColumn(_ lane: KanbanBoardModel.LaneVM, index li: Int) -> some View {
        let focusedLane = model.cur.lane == li
        return VStack(alignment: .leading, spacing: 8) {
            laneHeader(lane, index: li, focused: focusedLane)
            VStack(spacing: 8) {
                ForEach(Array(model.slots(lane: li).enumerated()), id: \.element.id) { pos, slot in
                    if case let .new(nl, _, idx) = model.editing, nl == li, idx == pos { newCardField }
                    switch slot {
                    case let .card(vm):
                        cardView(vm, lane: li, index: pos)
                    case let .placeholder(h):
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent.opacity(0.08)))
                            .frame(height: h)
                            .transition(.opacity)
                    }
                }
                if case let .new(nl, _, idx) = model.editing, nl == li, idx >= model.slots(lane: li).count { newCardField }
                if lane.cards.isEmpty && model.drag == nil && model.editing == nil {
                    Text(model.isFiltering ? "No matches" : "No cards")
                        .font(.caption)
                        .foregroundStyle(theme.textDim)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
            }
            .animation(StructuredStyle.animation(animates), value: model.slots(lane: li).map(\.id))
            Button {
                model.startNew(lane: li, index: lane.total)
            } label: {
                Label("Add card", systemImage: "plus")
                    .font(.callout)
                    .foregroundStyle(theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
        }
        .padding(10)
        .frame(width: Self.laneWidth, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.overlayBackground.opacity(theme.isDark ? 0.55 : 0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(focusedLane ? theme.accent.opacity(0.35) : theme.border.opacity(0.6), lineWidth: focusedLane ? 1 : 0.5)
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { model.laneFrames[lane.id] = $0 }
        .opacity(model.drag?.kind == .lane && model.drag?.key == lane.id ? 0 : 1)
    }

    private func laneHeader(_ lane: KanbanBoardModel.LaneVM, index li: Int, focused: Bool) -> some View {
        HStack(spacing: 6) {
            if case let .lane(el, _) = model.editing, el == li {
                TextField("Column title", text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline, weight: .semibold))
                    .focused($fieldFocused)
                    .onSubmit { model.commitEdit() }
                    .onKeyPress(.escape) { model.cancelEdit(); return .handled }
            } else {
                Text(lane.lane.title.isEmpty ? "Untitled" : lane.lane.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(focused ? theme.text : theme.text.opacity(0.85))
                    .lineLimit(1)
            }
            if lane.lane.complete {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(StructuredStyle.preset(4))
                    .help("Cards moved here are marked done")
            }
            Spacer(minLength: 4)
            Text(model.isFiltering ? "\(lane.cards.count)/\(lane.total)" : "\(lane.total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.textDim)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(theme.muted.opacity(0.18)))
        }
        .padding(.horizontal, 4)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.startRename(lane: li) }
        .gesture(laneDrag(lane, index: li))
    }

    private var lanePlaceholder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .frame(width: Self.laneWidth, height: max(120, model.drag?.size.height ?? 200))
    }

    private var addLaneColumn: some View {
        Group {
            if model.editing == .newLane {
                TextField("New column", text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline, weight: .semibold))
                    .focused($fieldFocused)
                    .onSubmit { model.commitEdit() }
                    .onKeyPress(.escape) { model.cancelEdit(); return .handled }
                    .padding(12)
                    .frame(width: Self.laneWidth, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.overlayBackground))
            } else {
                Button { model.startNewLane() } label: {
                    Label("Add column", systemImage: "plus")
                        .font(.callout)
                        .foregroundStyle(theme.textDim)
                        .padding(12)
                        .frame(width: 160, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.border.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Cards

    private var newCardField: some View {
        TextField("Card text", text: $model.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .focused($fieldFocused)
            .onSubmit { model.commitEdit() }
            .onKeyPress(.escape) { model.cancelEdit(); return .handled }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.background))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.accent, lineWidth: 1.5))
    }

    @ViewBuilder
    private func cardView(_ vm: KanbanBoardModel.CardVM, lane li: Int, index ci: Int) -> some View {
        let isFocused = model.focusedCard?.id == vm.id
        if case let .card(key, _) = model.editing, key == vm.id {
            newCardField
        } else {
            KanbanCardView(card: vm.card, focused: isFocused, confirming: model.confirmKey == vm.id,
                           onToggle: { model.setCursor(KanbanCursor(lane: li, card: ci)); model.toggle(vm) })
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { model.cardFrames[vm.id] = $0 }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.setCursor(KanbanCursor(lane: li, card: ci)); model.startEdit(vm) }
                .onTapGesture { model.setCursor(KanbanCursor(lane: li, card: ci)); focused = true }
                .gesture(cardDrag(vm, lane: li, index: ci))
                .transition(.opacity)
        }
    }

    private func cardDrag(_ vm: KanbanBoardModel.CardVM, lane li: Int, index ci: Int) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.space))
            .onChanged { v in
                if model.drag == nil {
                    model.setCursor(KanbanCursor(lane: li, card: ci))
                    let f = model.cardFrames[vm.id] ?? CGRect(origin: v.startLocation, size: CGSize(width: Self.laneWidth - 20, height: 48))
                    model.beginDrag(.init(kind: .card, key: vm.id, fromLane: li, fromIndex: ci, size: f.size,
                                          grab: CGPoint(x: v.startLocation.x - f.minX, y: v.startLocation.y - f.minY),
                                          location: v.location))
                }
                withAnimation(StructuredStyle.animation(animates)) { model.updateDrag(to: v.location) }
            }
            .onEnded { _ in
                withAnimation(StructuredStyle.animation(animates)) { model.endDrag() }
                focused = true
            }
    }

    private func laneDrag(_ lane: KanbanBoardModel.LaneVM, index li: Int) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.space))
            .onChanged { v in
                if model.drag == nil {
                    model.setCursor(KanbanCursor(lane: li, card: model.cur.lane == li ? model.cur.card : 0))
                    let f = model.laneFrames[lane.id] ?? CGRect(origin: v.startLocation, size: CGSize(width: Self.laneWidth, height: 200))
                    model.beginDrag(.init(kind: .lane, key: lane.id, fromLane: li, fromIndex: li, size: f.size,
                                          grab: CGPoint(x: v.startLocation.x - f.minX, y: v.startLocation.y - f.minY),
                                          location: v.location))
                }
                withAnimation(StructuredStyle.animation(animates)) { model.updateDrag(to: v.location) }
            }
            .onEnded { _ in
                withAnimation(StructuredStyle.animation(animates)) { model.endDrag() }
                focused = true
            }
    }

    // MARK: - Ghost + notices

    @ViewBuilder
    private var ghost: some View {
        if let d = model.drag {
            Group {
                if d.kind == .card, let vm = model.lanes.flatMap(\.cards).first(where: { $0.id == d.key }) {
                    KanbanCardView(card: vm.card, focused: true, confirming: false, onToggle: {})
                        .frame(width: d.size.width)
                } else if d.kind == .lane, let lane = model.lanes.first(where: { $0.id == d.key }) {
                    Text(lane.lane.title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .padding(12)
                        .frame(width: d.size.width, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(theme.overlayBackground))
                }
            }
            .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.18), radius: 14, y: 6)
            .rotationEffect(.degrees(animates ? 1.5 : 0))
            .scaleEffect(animates ? 1.03 : 1)
            .offset(x: d.location.x - d.grab.x, y: d.location.y - d.grab.y)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var noticeView: some View {
        if let n = model.notice {
            Text(n)
                .font(.callout)
                .foregroundStyle(theme.text)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(theme.overlayBackground))
                .overlay(Capsule().stroke(theme.border, lineWidth: 0.5))
                .padding(.bottom, 16)
                .transition(.opacity)
        }
    }
}

/// One card: checkbox + compact prose, focus ring, inline delete confirm.
struct KanbanCardView: View {
    let card: KanbanCard
    let focused: Bool
    let confirming: Bool
    let onToggle: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                if card.hasCheckbox {
                    Button(action: onToggle) {
                        Image(systemName: card.checked ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(card.checked ? StructuredStyle.preset(4) : theme.textDim)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 1)
                }
                CompactProse(text: card.text)
                    .opacity(card.checked ? 0.55 : 1)
                    .strikethrough(card.checked, color: theme.textDim)
            }
            if confirming {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("Delete card?  y / n")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(theme.error)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.error.opacity(0.12)))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.background)
                .shadow(color: .black.opacity(theme.isDark ? 0.25 : 0.06), radius: focused ? 6 : 1.5, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(confirming ? theme.error : focused ? theme.accent : theme.border.opacity(0.7), lineWidth: focused || confirming ? 1.5 : 0.5)
        )
    }
}

/// Board/Canvas ⇄ Source switch.
struct ViewToggle: View {
    let selection: String
    let onSource: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            segment(selection, active: true) {}
            segment("Source", active: false, action: onSource)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.muted.opacity(0.16)))
    }

    private func segment(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? theme.text : theme.textDim)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(active ? theme.background : .clear))
        }
        .buttonStyle(.plain)
    }
}
