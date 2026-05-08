import SwiftUI
import LumiKit

/// Cross-platform plain markdown editor. No syntax highlighting, no vim — that
/// arrives in Phase D. The point of Phase C is a working write path with a
/// monospaced editor that respects the active theme.
public struct PlainEditor: View {
    @Binding var text: String

    public init(text: Binding<String>) {
        self._text = text
    }

    @Environment(\.theme) private var theme

    public var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(theme.text)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .tint(theme.primary)
            #if os(macOS)
            .textEditorStyle(.plain)
            #endif
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
    }
}
