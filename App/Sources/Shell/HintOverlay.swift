import SwiftUI
import LumiKit
import LumiUI

/// Hint mode labels (web `HintOverlay.svelte`): a small tag at the left
/// edge of every clickable thing; typed letters dim, the rest stay
/// bright; type the label to click.
struct HintOverlay: View {
    let session: HintSession
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.06).allowsHitTesting(false)
            ForEach(session.live, id: \.self) { i in
                let frame = session.targets[i].frame
                label(session.labels[i])
                    .position(x: frame.minX + 14, y: frame.midY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func label(_ text: String) -> some View {
        let typed = session.typed.count
        return HStack(spacing: 0) {
            Text(text.prefix(typed)).foregroundStyle(theme.background.opacity(0.55))
            Text(text.dropFirst(typed)).foregroundStyle(theme.background)
        }
        .font(.system(size: 11, weight: .bold, design: .monospaced))
        .textCase(.uppercase)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(theme.warning))
        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(theme.background.opacity(0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .fixedSize()
    }
}
