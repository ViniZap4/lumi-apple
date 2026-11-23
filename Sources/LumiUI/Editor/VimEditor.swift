import SwiftUI
import LumiKit

/// SwiftUI editor backed by the vim engine. `VimController` owns the text;
/// the platform text view receives ranged edits only.
///
/// - `init(text:)` (local notes): the binding is a *sink* — every change
///   is pushed into it synchronously; an outside change to the binding is
///   applied as a ranged diff that keeps mode, registers and history.
/// - `init(document:)` (server notes): the editor binds to the live CRDT
///   replica; local edits go out as ranged ops, remote edits come in as
///   ranged edits with the cursor preserved.
public struct VimEditor: View {
    private let text: Binding<String>?
    let onModeChange: ((VimMode) -> Void)?
    let onEffect: ((VimEffect) -> Void)?
    let jjEscapeEnabled: Bool
    let showLineNumbers: Bool
    let relativeLineNumbers: Bool
    /// Per-device editor settings (web parity): escape sequences, their
    /// timeout, font size and soft wrap.
    let options: VimEditorOptions

    @State private var controller: VimController

    public init(
        text: Binding<String>,
        onModeChange: ((VimMode) -> Void)? = nil,
        onEffect: ((VimEffect) -> Void)? = nil,
        jjEscapeEnabled: Bool = false,
        showLineNumbers: Bool = false,
        relativeLineNumbers: Bool = false,
        options: VimEditorOptions = VimEditorOptions()
    ) {
        self.options = options
        self.text = text
        self.onModeChange = onModeChange
        self.onEffect = onEffect
        self.jjEscapeEnabled = jjEscapeEnabled
        self.showLineNumbers = showLineNumbers
        self.relativeLineNumbers = relativeLineNumbers
        self._controller = State(initialValue: VimController(initialText: text.wrappedValue))
    }

    /// Collaborative editor over a live replica. `vimEnabled: false` gives
    /// plain native editing that still emits ranged CRDT ops.
    public init(
        document: CollaborativeDocument,
        vimEnabled: Bool = true,
        onModeChange: ((VimMode) -> Void)? = nil,
        onEffect: ((VimEffect) -> Void)? = nil,
        jjEscapeEnabled: Bool = false,
        showLineNumbers: Bool = false,
        relativeLineNumbers: Bool = false,
        options: VimEditorOptions = VimEditorOptions()
    ) {
        self.options = options
        self.text = nil
        self.onModeChange = onModeChange
        self.onEffect = onEffect
        self.jjEscapeEnabled = jjEscapeEnabled
        self.showLineNumbers = showLineNumbers
        self.relativeLineNumbers = relativeLineNumbers
        self._controller = State(initialValue: VimController(document: document, vimEnabled: vimEnabled))
    }

    @Environment(\.theme) private var theme

    public var body: some View {
        VStack(spacing: 0) {
            VimTextViewBridge(
                controller: controller,
                mode: controller.state.mode,
                highlights: controller.searchHighlights,
                theme: theme,
                showLineNumbers: showLineNumbers,
                relativeLineNumbers: relativeLineNumbers,
                fontSize: options.fontSize,
                lineWrapping: options.lineWrapping
            )
            if case let .commandLine(prefix, buffer) = controller.state.mode {
                VimCommandLineOverlay(prefix: prefix, buffer: buffer)
            }
        }
        .onChange(of: text?.wrappedValue) { _, new in
            // Our own pushes arrive here equal to the buffer; anything
            // else is an outside change (reload, revert).
            if let new, new != controller.buffer.text {
                controller.replaceAll(with: new)
            }
        }
        .onChange(of: controller.state.mode) { _, mode in
            onModeChange?(mode)
        }
        .onAppear {
            controller.bindDocument()
            controller.onEffect = onEffect
            if let text {
                controller.onTextChange = { text.wrappedValue = $0 }
            }
            controller.setJJEscapeEnabled(jjEscapeEnabled)
            controller.setEscapeSequences(options.escapeSequences, timeout: options.escapeTimeout)
            onModeChange?(controller.state.mode)
        }
        .onChange(of: jjEscapeEnabled) { _, newValue in
            controller.setJJEscapeEnabled(newValue)
        }
        .onChange(of: options) { _, new in
            controller.setEscapeSequences(new.escapeSequences, timeout: new.escapeTimeout)
        }
        .background(theme.background)
    }
}

/// Editor settings that come from per-device preferences.
public struct VimEditorOptions: Equatable, Sendable {
    public var escapeSequences: [String]
    /// Seconds between the keys of an escape sequence.
    public var escapeTimeout: TimeInterval
    public var fontSize: CGFloat
    public var lineWrapping: Bool

    public init(escapeSequences: [String] = [], escapeTimeout: TimeInterval = 0.2, fontSize: CGFloat? = nil, lineWrapping: Bool = true) {
        self.escapeSequences = escapeSequences
        self.escapeTimeout = escapeTimeout
        #if os(macOS)
        self.fontSize = fontSize ?? 13
        #else
        self.fontSize = fontSize ?? 16
        #endif
        self.lineWrapping = lineWrapping
    }
}

/// Convenience accessor so callers (e.g. detail toolbar) can show the current
/// mode without owning a `VimController` reference.
public extension VimMode {
    var label: String {
        switch self {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case let .visual(kind, _):
            switch kind {
            case .characterwise: return "VISUAL"
            case .linewise: return "V-LINE"
            }
        case let .commandLine(prefix, buffer):
            return "\(prefix)\(buffer)"
        }
    }
}
