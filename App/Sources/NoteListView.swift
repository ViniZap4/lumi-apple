import SwiftUI
import LumiKit
import LumiUI

struct NoteListView: View {
    let vault: VaultRecord
    let notes: [Note]
    @Binding var selectedNoteID: String?

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if notes.isEmpty {
                VStack(spacing: 8) {
                    Text(vault.name)
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(theme.text)
                    Text("no markdown files in this vault yet")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.background)
            } else {
                List(selection: $selectedNoteID) {
                    ForEach(notes) { note in
                        NoteRow(note: note)
                            .tag(Optional(note.id))
                    }
                }
                .scrollContentBackground(.hidden)
                .background(theme.background)
            }
        }
        .navigationTitle(vault.name)
    }
}

private struct NoteRow: View {
    let note: Note
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.title)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(theme.text)
            HStack(spacing: 6) {
                Text(note.updatedAt.formatted(.relative(presentation: .numeric)))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                if !note.tags.isEmpty {
                    Text("·")
                        .foregroundStyle(theme.textDim)
                    Text(note.tags.joined(separator: " "))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
