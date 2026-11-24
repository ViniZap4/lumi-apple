// The book home as it was on main (fe1117a), for before/after renders only.
import SwiftUI
@testable import LumiUI

/// A book with no note open (SPEC-PARTE2 §2): calm — the name, its sync
/// state and recent notes. The floating explorer is the way in.
struct LegacyBookHomeView<Dot: View>: View {
    struct Recent: Identifiable, Hashable {
        let id: String
        let name: String
        let folder: String
        let updated: String
        init(id: String, name: String, folder: String, updated: String) {
            self.id = id
            self.name = name
            self.folder = folder
            self.updated = updated
        }
    }

    let name: String
    let status: String
    let location: String
    let noteCount: Int
    let recents: [Recent]
    let cursor: Int?
    let loading: Bool
    let dot: Dot
    let onOpen: (Int) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.lumiMotion) private var motion

    init(name: String, status: String, location: String, noteCount: Int, recents: [Recent], cursor: Int?,
                loading: Bool, @ViewBuilder dot: () -> Dot, onOpen: @escaping (Int) -> Void) {
        self.name = name
        self.status = status
        self.location = location
        self.noteCount = noteCount
        self.recents = recents
        self.cursor = cursor
        self.loading = loading
        self.dot = dot()
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text(name)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    dot
                    Text(status)
                    Text("·").opacity(0.5)
                    Text(location).lineLimit(1).truncationMode(.middle)
                    Text("·").opacity(0.5)
                    Text("\(noteCount) notes")
                }
                .font(ShellFont.chrome)
                .foregroundStyle(theme.textDim)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("RECENT")
                    .font(ShellFont.small)
                    .tracking(1.2)
                    .foregroundStyle(theme.textDim)
                    .padding(.bottom, 6)
                if recents.isEmpty {
                    if loading {
                        ForEach(0..<3, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 4).fill(theme.text.opacity(0.06))
                                .frame(width: [300, 240, 270][i], height: 12).padding(.vertical, 9)
                        }
                    } else {
                        Text("nothing opened here yet")
                            .font(ShellFont.chrome)
                            .foregroundStyle(theme.textDim)
                    }
                }
                ForEach(Array(recents.enumerated()), id: \.element.id) { i, r in
                    Button { onOpen(i) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textDim)
                            Text(r.name)
                                .font(ShellFont.row)
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Text(r.folder)
                                .font(ShellFont.small)
                                .foregroundStyle(theme.textDim)
                                .lineLimit(1)
                            Text(r.updated)
                                .font(ShellFont.small)
                                .foregroundStyle(theme.textDim)
                                .frame(width: 80, alignment: .trailing)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(i == cursor ? theme.selectionRow : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(LiftButtonStyle(enabled: motion))
                    .staggerIn(i, active: motion)
                }
            }
            .frame(maxWidth: 560)
            HStack(spacing: 14) {
                hint("-", "explorer")
                hint("gb", "books")
                hint("space", "palette")
                hint("?", "keys")
            }
        }
        .padding(.horizontal, 56)
        .padding(.top, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) home")
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(key)
            Text(label).font(ShellFont.small).foregroundStyle(theme.textDim)
        }
    }
}
