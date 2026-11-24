import SwiftUI
import LumiKit

/// Source mode with the rendered preview beside it (web
/// `SourceSplit.svelte`).
///
/// - The preview re-renders ~120 ms after typing stops; the reader only
///   re-renders the blocks that changed.
/// - Scroll sync maps editor lines ↔ preview offsets through each block's
///   source line (`SplitScrollSync`); the pane the user last touched
///   drives.
/// - The divider drags, and takes ←/→ / h/l (⇧ for big steps), Home/End
///   and ⏎/= (reset) when focused.
/// - Narrow windows (and iPhone) collapse to Source | Preview tabs.
///
/// The editor stays mounted whether the preview shows or not, so
/// toggling keeps the cursor, the mode and the history.
public struct SourceSplit<Editor: View>: View {
    let enabled: Bool
    /// The source as the editor has it (debounced into the preview).
    let text: String
    @Binding var ratio: Double
    let scale: Double
    let fontFamily: MarkdownFontFamily
    let baseURL: URL?
    let vaultRoot: URL?
    let onToggleTask: ((Int) -> Void)?
    let onInAppLink: ((URL) -> Bool)?
    /// Which side has keyboard focus (pane navigation): a thin accent
    /// line marks it. nil → no marker.
    let focus: ScrollSync.Side?
    /// The split's coordinator, for the host (pane focus, keyboard
    /// reading of the preview).
    let onSync: ((SplitScrollSync) -> Void)?
    @ViewBuilder let editor: () -> Editor

    @State private var sync = SplitScrollSync()
    @State private var previewText = ""
    @State private var dragRatio: Double?
    @State private var tab: Tab = .source
    @FocusState private var dividerFocused: Bool
    @Environment(\.theme) private var theme
    @Environment(\.lumiMotion) private var motion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    enum Tab: Hashable { case source, preview }

    /// Below this width the panes become tabs (web: 860 px).
    public static var narrowWidth: CGFloat { 860 }

    public init(
        enabled: Bool,
        text: String,
        ratio: Binding<Double>,
        scale: Double = 1,
        fontFamily: MarkdownFontFamily = .system,
        baseURL: URL? = nil,
        vaultRoot: URL? = nil,
        onToggleTask: ((Int) -> Void)? = nil,
        onInAppLink: ((URL) -> Bool)? = nil,
        focus: ScrollSync.Side? = nil,
        onSync: ((SplitScrollSync) -> Void)? = nil,
        @ViewBuilder editor: @escaping () -> Editor
    ) {
        self.focus = focus
        self.onSync = onSync
        self.enabled = enabled
        self.text = text
        self._ratio = ratio
        self.scale = scale
        self.fontFamily = fontFamily
        self.baseURL = baseURL
        self.vaultRoot = vaultRoot
        self.onToggleTask = onToggleTask
        self.onInAppLink = onInAppLink
        self.editor = editor
    }

    public var body: some View {
        GeometryReader { geo in
            let narrow = isNarrow(geo.size.width)
            let r = dragRatio ?? ratio
            VStack(spacing: 0) {
                if enabled && narrow { tabs }
                HStack(spacing: 0) {
                    editor()
                        .overlay(alignment: .top) { focusMark(.source, enabled: enabled) }
                        .frame(width: enabled && !narrow ? max(200, geo.size.width * r - 4) : nil)
                        .frame(maxWidth: enabled && !narrow ? nil : .infinity)
                        .opacity(enabled && narrow && tab == .preview ? 0 : 1)
                        .frame(width: enabled && narrow && tab == .preview ? 0 : nil)
                        .clipped()
                    if enabled && !narrow {
                        divider(width: geo.size.width)
                    }
                    if enabled && (!narrow || tab == .preview) {
                        preview
                            .overlay(alignment: .top) { focusMark(.preview, enabled: true) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // Split open / close slides the preview in
                            // from the trailing edge (instant under
                            // Reduce Motion).
                            .transition(motion ? .move(edge: .trailing).combined(with: .opacity) : .identity)
                    }
                }
                .animation(motion ? .smooth(duration: 0.18) : nil, value: enabled)
            }
            .coordinateSpace(.named("lumi.split"))
            .onAppear {
                sync.isActive = enabled && !narrow
                place(enabled: enabled, narrow: narrow)
                sync.showTab = { tab = $0 ? .preview : .source }
                onSync?(sync)
            }
            .onChange(of: narrow) { _, n in
                sync.isActive = enabled && !n
                place(enabled: enabled, narrow: n)
            }
            .onChange(of: tab) { _, t in
                // The hidden pane must not keep the keyboard: the tab
                // that shows takes it.
                guard enabled && narrow else { return }
                if t == .preview {
                    DispatchQueue.main.async { sync.focusPreview() }
                } else {
                    sync.focusEditor()
                }
            }
            .onChange(of: enabled) { _, on in
                sync.isActive = on && !narrow
                place(enabled: on, narrow: narrow)
                if on { previewText = text }
            }
        }
        .environment(\.splitScrollSync, sync)
        .task(id: enabled ? text : "") {
            guard enabled else { return }
            if previewText.isEmpty {
                previewText = text
                return
            }
            try? await Task.sleep(for: ScrollSync.previewDebounce)
            if !Task.isCancelled { previewText = text }
        }
    }

    private func place(enabled: Bool, narrow: Bool) {
        sync.placement = !enabled ? .off : (narrow ? .tabbed : .beside)
    }

    /// Thin accent line on top of the focused side (only while both
    /// panes show, so a lone editor never wears it).
    @ViewBuilder
    private func focusMark(_ side: ScrollSync.Side, enabled: Bool) -> some View {
        if enabled, focus == side {
            Rectangle()
                .fill(theme.primary.opacity(0.85))
                .frame(height: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func isNarrow(_ width: CGFloat) -> Bool {
        #if os(iOS)
        if sizeClass == .compact { return true }
        #endif
        return width < Self.narrowWidth
    }

    private var preview: some View {
        MarkdownReader(
            title: "",
            text: previewText,
            baseURL: baseURL,
            vaultRoot: vaultRoot,
            isDirty: true,
            scale: scale,
            fontFamily: fontFamily,
            readingWidth: 720,
            onInAppLink: onInAppLink,
            onToggleTask: onToggleTask,
            showsHeader: false
        )
        .background(theme.background)
        .accessibilityLabel("Preview")
    }

    private var tabs: some View {
        Picker("Pane", selection: $tab) {
            Text("Source").tag(Tab.source)
            Text("Preview").tag(Tab.preview)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border.opacity(0.5)).frame(height: 0.5) }
    }

    private func divider(width: CGFloat) -> some View {
        let active = dragRatio != nil || dividerFocused
        return ZStack {
            Rectangle()
                .fill(active ? theme.primary : theme.border.opacity(0.7))
                .frame(width: active ? 2 : 1)
        }
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        #endif
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("lumi.split"))
                .onChanged { g in
                    guard width > 0 else { return }
                    dragRatio = ScrollSync.clampRatio(g.location.x / width)
                }
                .onEnded { _ in
                    if let dragRatio { ratio = dragRatio }
                    dragRatio = nil
                }
        )
        .focusable()
        .focused($dividerFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in
            let step = press.modifiers.contains(.shift) ? 0.1 : 0.02
            switch press.key {
            case .leftArrow: ratio = ScrollSync.clampRatio(ratio - step)
            case .rightArrow: ratio = ScrollSync.clampRatio(ratio + step)
            case .home: ratio = ScrollSync.ratioRange.lowerBound
            case .end: ratio = ScrollSync.ratioRange.upperBound
            case .return: ratio = 0.5
            default:
                switch press.characters.lowercased() {
                case "h": ratio = ScrollSync.clampRatio(ratio - step)
                case "l": ratio = ScrollSync.clampRatio(ratio + step)
                case "=": ratio = 0.5
                default: return .ignored
                }
            }
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel("Resize editor and preview")
        .accessibilityValue("\(Int((ratio * 100).rounded())) percent editor")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: ratio = ScrollSync.clampRatio(ratio + 0.05)
            case .decrement: ratio = ScrollSync.clampRatio(ratio - 0.05)
            @unknown default: break
            }
        }
        .help("Drag, or focus and use ← → / h l to resize · ⏎ resets")
    }
}
