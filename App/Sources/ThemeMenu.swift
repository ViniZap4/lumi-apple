import SwiftUI
import LumiUI

struct ThemeMenu: View {
    @Binding var selection: LumiTheme
    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            Section("Dark") {
                ForEach(LumiTheme.darkThemes) { item in
                    button(for: item)
                }
            }
            Section("Light") {
                ForEach(LumiTheme.lightThemes) { item in
                    button(for: item)
                }
            }
        } label: {
            Image(systemName: "paintpalette")
                .foregroundStyle(theme.primary)
        }
    }

    private func button(for item: LumiTheme) -> some View {
        Button {
            selection = item
        } label: {
            HStack {
                Text(item.tokens.name)
                if item == selection {
                    Spacer()
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}
