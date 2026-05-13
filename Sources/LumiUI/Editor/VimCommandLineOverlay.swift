import SwiftUI
import LumiKit

/// Bottom-of-editor overlay that mirrors `VimMode.commandLine`'s prefix and
/// in-progress pattern. All state lives in the engine — this view is a
/// display-only reflection so there's no risk of de-syncing the engine's idea
/// of the pattern from the user-visible one.
///
/// The caret is a thin animated rectangle drawn at the trailing edge of the
/// buffer. We don't try to support cursor-mid-pattern (real vim does, but it's
/// not worth the engine surface for a v1 of search).
struct VimCommandLineOverlay: View {
    let prefix: Character
    let buffer: String
    @Environment(\.theme) private var theme
    @State private var caretVisible: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            Text(String(prefix))
                .foregroundStyle(theme.accent)
            Text(buffer)
                .foregroundStyle(theme.text)
            Rectangle()
                .fill(theme.accent)
                .frame(width: 8, height: 14)
                .opacity(caretVisible ? 1 : 0)
                .padding(.leading, 2)
            Spacer(minLength: 0)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.overlayBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 0.5)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                caretVisible.toggle()
            }
        }
    }
}
