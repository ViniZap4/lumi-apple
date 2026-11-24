import SwiftUI
import LumiKit

/// One line of the keys that matter right now (web legend parity): the
/// items in priority order, measured and fitted to the width — as many
/// as fit, "⋯" only when some are left out — clickable when they carry
/// an action, an optional pending-keys pill and a small right-aligned
/// stat. Buttons never take keyboard focus.
public struct LegendLine: View {
    let items: [LegendItem]
    let pending: String
    let stat: String?
    let onAction: ((LegendAction) -> Void)?
    @Environment(\.theme) private var theme

    public static let gap: CGFloat = 14

    public init(items: [LegendItem], pending: String = "", stat: String? = nil, onAction: ((LegendAction) -> Void)? = nil) {
        self.items = items
        self.pending = pending
        self.stat = stat
        self.onAction = onAction
    }

    public var body: some View {
        HStack(spacing: 10) {
            if !pending.isEmpty {
                Text(pending)
                    .font(ShellFont.chromeBold)
                    .foregroundStyle(theme.background)
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 3).fill(theme.accent))
                    .fixedSize()
            }
            LegendFitLayout(gap: Self.gap) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    LegendChip(item: item, onAction: onAction)
                }
                Button {
                    onAction?(.keys("?"))
                } label: {
                    Text("⋯")
                        .font(ShellFont.chromeBold)
                        .foregroundStyle(theme.textDim)
                        .fixedSize()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("More keys (?)")
                .accessibilityLabel("More keys")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let stat {
                Text(stat)
                    .font(ShellFont.small)
                    .monospacedDigit()
                    .foregroundStyle(theme.textDim)
                    .fixedSize()
            }
        }
        .lineLimit(1)
    }
}

/// `keys label`, a button when it has an action.
struct LegendChip: View {
    let item: LegendItem
    let onAction: ((LegendAction) -> Void)?
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        let label = HStack(spacing: 5) {
            Text(item.keys)
                .font(ShellFont.chromeBold)
                .foregroundStyle(theme.accent)
            Text(item.label)
                .font(ShellFont.small)
                .foregroundStyle(hover ? theme.text : theme.textDim)
        }
        .fixedSize()
        if let action = item.action, let onAction {
            Button { onAction(action) } label: {
                label
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(hover ? theme.text.opacity(0.07) : .clear))
                    .padding(.horizontal, -3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { hover = $0 }
            .help(item.tip ?? "\(item.keys) — \(item.label)")
        } else {
            label.help(item.tip ?? "")
        }
    }
}

/// Places items left to right in priority order; whatever does not fit
/// (`CommandLegend.fit`) is left out, and the last subview — the "⋯"
/// marker — shows only then.
struct LegendFitLayout: Layout {
    var gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let h = sizes.map(\.height).max() ?? 0
        let natural = sizes.dropLast().map(\.width).reduce(0, +) + gap * CGFloat(max(0, subviews.count - 2))
        return CGSize(width: proposal.width ?? natural, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let marker = subviews.last else { return }
        let items = subviews.dropLast()
        let sizes = items.map { $0.sizeThatFits(.unspecified) }
        let markerSize = marker.sizeThatFits(.unspecified)
        let fit = CommandLegend.fit(widths: sizes.map { Double($0.width) }, available: Double(bounds.width),
                                    gap: Double(gap), reserve: Double(markerSize.width))
        let shown = Set(fit.shown)
        var x = bounds.minX
        let away = CGPoint(x: bounds.minX - 100_000, y: bounds.midY)
        for (i, sub) in items.enumerated() {
            if shown.contains(i) {
                sub.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + gap
            } else {
                sub.place(at: away, anchor: .leading, proposal: .zero)
            }
        }
        if fit.overflow {
            marker.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(markerSize))
        } else {
            marker.place(at: away, anchor: .leading, proposal: .zero)
        }
    }
}
