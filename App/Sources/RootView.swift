import SwiftUI
import LumiKit
import LumiUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var bound = appState

        ZStack {
            theme.background.ignoresSafeArea()

            VStack(spacing: 32) {
                Logo()

                VStack(spacing: 6) {
                    Text("no vaults yet")
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(theme.text)
                    Text("open a folder or connect to a server to get started")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }
                .multilineTextAlignment(.center)

                ThemePicker(selection: $bound.theme)
                    .padding(.top, 8)
            }
            .padding(40)
            .frame(maxWidth: 520)
        }
    }
}

private struct Logo: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array("lumi".enumerated()), id: \.offset) { index, char in
                Text(String(char))
                    .foregroundStyle(theme.logoColors[index % theme.logoColors.count])
            }
        }
        .font(.system(size: 72, weight: .light, design: .monospaced))
    }
}

private struct ThemePicker: View {
    @Binding var selection: LumiTheme
    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            Section("Dark") {
                ForEach(LumiTheme.darkThemes) { t in
                    button(for: t)
                }
            }
            Section("Light") {
                ForEach(LumiTheme.lightThemes) { t in
                    button(for: t)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(theme.primary)
                    .frame(width: 10, height: 10)
                Text(selection.tokens.name)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.text)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.overlayBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
    }

    private func button(for t: LumiTheme) -> some View {
        Button {
            selection = t
        } label: {
            HStack {
                Text(t.tokens.name)
                if t == selection {
                    Spacer()
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}

#Preview("Empty state — tokyo-night") {
    RootView()
        .environment(AppState())
        .environment(\.theme, LumiTheme.tokyoNight.tokens)
        .preferredColorScheme(.dark)
}
