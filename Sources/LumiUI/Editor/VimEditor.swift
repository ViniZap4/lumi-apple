import SwiftUI
import LumiKit

/// SwiftUI editor backed by the vim engine. Drop-in replacement for
/// `PlainEditor`. The caller binds to a `String` for text and observes
/// `controller.state.mode` (via a callback) for mode changes — useful for
/// rendering a NORMAL/INSERT indicator in the surrounding chrome.
public struct VimEditor: View {
    @Binding var text: String
    let onModeChange: ((VimMode) -> Void)?
    let onEffect: ((VimEffect) -> Void)?

    @State private var controller: VimController

    public init(
        text: Binding<String>,
        onModeChange: ((VimMode) -> Void)? = nil,
        onEffect: ((VimEffect) -> Void)? = nil
    ) {
        self._text = text
        self.onModeChange = onModeChange
        self.onEffect = onEffect
        self._controller = State(initialValue: VimController(initialText: text.wrappedValue))
    }

    @Environment(\.theme) private var theme

    public var body: some View {
        VStack(spacing: 0) {
            VimTextViewBridge(
                text: controller.buffer.text,
                selection: controller.selectionUTF16Range,
                isInsertMode: controller.state.mode == .insert,
                highlights: controller.searchHighlights,
                controller: controller,
                theme: theme
            )
            if case let .commandLine(prefix, buffer) = controller.state.mode {
                VimCommandLineOverlay(prefix: prefix, buffer: buffer)
            }
        }
        .onChange(of: text) { _, new in
            if new != controller.buffer.text {
                controller.replace(text: new)
            }
        }
        .onChange(of: controller.buffer.text) { _, new in
            if new != text {
                text = new
            }
        }
        .onChange(of: controller.state.mode) { _, mode in
            onModeChange?(mode)
        }
        .onAppear {
            controller.onEffect = onEffect
            onModeChange?(controller.state.mode)
        }
        .background(theme.background)
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
