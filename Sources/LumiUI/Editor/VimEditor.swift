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
    /// Parsed per-device `.vimrc` (mappings, leader, options).
    let vimrc: ParsedVimrc?
    /// Draw a block cursor in normal mode (preference).
    let blockCursor: Bool
    /// Name of the open note (`"%`, Ctrl-G).
    let fileName: String?
    /// Mode / pending keys / messages for the chrome (legend, status).
    let onStatusChange: ((VimStatus) -> Void)?
    /// Source (raw markdown) or Live Preview.
    var presentation: EditorPresentation = .source
    /// ⌘-click on a Live Preview link.
    var onOpenLink: ((LiveLink) -> Void)?

    @State private var controller: VimController

    public init(
        text: Binding<String>,
        onModeChange: ((VimMode) -> Void)? = nil,
        onEffect: ((VimEffect) -> Void)? = nil,
        jjEscapeEnabled: Bool = false,
        showLineNumbers: Bool = false,
        relativeLineNumbers: Bool = false,
        options: VimEditorOptions = VimEditorOptions(),
        vimrc: ParsedVimrc? = nil,
        blockCursor: Bool = true,
        fileName: String? = nil,
        onStatusChange: ((VimStatus) -> Void)? = nil
    ) {
        self.options = options
        self.vimrc = vimrc
        self.blockCursor = blockCursor
        self.fileName = fileName
        self.onStatusChange = onStatusChange
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
        options: VimEditorOptions = VimEditorOptions(),
        vimrc: ParsedVimrc? = nil,
        blockCursor: Bool = true,
        fileName: String? = nil,
        onStatusChange: ((VimStatus) -> Void)? = nil
    ) {
        self.options = options
        self.vimrc = vimrc
        self.blockCursor = blockCursor
        self.fileName = fileName
        self.onStatusChange = onStatusChange
        self.text = nil
        self.onModeChange = onModeChange
        self.onEffect = onEffect
        self.jjEscapeEnabled = jjEscapeEnabled
        self.showLineNumbers = showLineNumbers
        self.relativeLineNumbers = relativeLineNumbers
        self._controller = State(initialValue: VimController(document: document, vimEnabled: vimEnabled))
    }

    @Environment(\.theme) private var theme
    @Environment(\.splitScrollSync) private var splitSync
    /// Hands the controller to the host (task toggles from a preview,
    /// `:preview split`), on appear.
    @Environment(\.vimControllerSink) private var controllerSink

    public var body: some View {
        let opts = controller.state.options
        VStack(spacing: 0) {
            VimTextViewBridge(
                controller: controller,
                mode: controller.state.mode,
                highlights: controller.searchHighlights,
                theme: theme,
                showLineNumbers: opts.number ?? showLineNumbers,
                relativeLineNumbers: opts.relativenumber ?? relativeLineNumbers,
                fontSize: options.fontSize,
                lineWrapping: opts.wrap ?? options.lineWrapping,
                blockRanges: controller.visualHighlightRanges,
                blockCursor: blockCursor,
                presentation: presentation,
                onOpenLink: onOpenLink
            )
            if case let .commandLine(prefix, buffer) = controller.state.mode {
                VimCommandLineOverlay(prefix: prefix, buffer: buffer)
            } else if let message = controller.state.message {
                VimMessageView(message: message)
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
        .onChange(of: controller.status) { _, status in
            onStatusChange?(status)
        }
        .onChange(of: vimrc) { _, parsed in
            controller.applyVimrc(parsed)
        }
        .onChange(of: fileName) { _, name in
            controller.setFileName(name)
        }
        .onAppear {
            controller.bindDocument()
            splitSync?.attach(editor: controller)
            controllerSink?(controller)
            controller.onEffect = onEffect
            if let text {
                controller.onTextChange = { text.wrappedValue = $0 }
            }
            controller.setJJEscapeEnabled(jjEscapeEnabled)
            controller.setEscapeSequences(options.escapeSequences, timeout: options.escapeTimeout)
            controller.applyVimrc(vimrc)
            controller.setFileName(fileName)
            onModeChange?(controller.state.mode)
            onStatusChange?(controller.status)
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

public extension VimEditor {
    /// Show the note as Source or Live Preview.
    func presentation(_ p: EditorPresentation, onOpenLink: ((LiveLink) -> Void)? = nil) -> VimEditor {
        var copy = self
        copy.presentation = p
        copy.onOpenLink = onOpenLink
        return copy
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
/// One-line message (or a multi-line panel such as `:registers`) under
/// the editor; replaced by the next key.
struct VimMessageView: View {
    let message: VimMessage
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if message.isMultiline {
                ScrollView {
                    Text(message.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
            } else {
                Text(message.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(message.isError ? theme.error : theme.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.overlayBackground)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 0.5) }
        .allowsHitTesting(message.isMultiline)
        .accessibilityLabel(message.text)
    }
}

public extension VimMode {
    var label: String {
        switch self {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .replace: return "REPLACE"
        case let .visual(kind, _):
            switch kind {
            case .characterwise: return "VISUAL"
            case .linewise: return "V-LINE"
            case .block: return "V-BLOCK"
            }
        case let .commandLine(prefix, buffer):
            return "\(prefix)\(buffer)"
        }
    }
}

public extension EnvironmentValues {
    /// Receives the editor's `VimController` when it appears.
    @Entry var vimControllerSink: (@MainActor (VimController) -> Void)? = nil
}
