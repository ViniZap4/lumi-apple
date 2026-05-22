import SwiftUI
import LumiKit

/// Modal for creating a new note in a server-hosted vault. Title is the only
/// required field — the server slugifies it to derive the note id, and the
/// initial body is empty so the user lands in the editor with a clean buffer.
///
/// On success the host auto-opens the new note in edit mode, mirroring the
/// "create-then-write" flow a markdown editor user expects.
struct CreateRemoteNoteSheet: View {
    /// The vault we're creating into. Passed in so the sheet doesn't have
    /// to depend on `remoteVaultsStore.selectedVaultID` race-free.
    let vault: RemoteVault

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var errorMessage: String?
    @State private var isSubmitting: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("new note")
                    .font(.headline)
                    .foregroundStyle(theme.text)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.escape, modifiers: [])
            }

            fieldLabel("Title")
            TextField("My new note", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await submit() } }

            Text("the server derives a slug id from the title (lowercase, non-alphanumerics → '-'). on collision the server bumps with a numeric suffix.")
                .font(.caption)
                .foregroundStyle(theme.textDim)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(theme.error)
                    .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create Note")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(theme.background)
    }

    private func submit() async {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let created = try await appState.remoteVaultsStore.createNote(title: trimmed)
            // Land the user inside the new note in edit mode so they can
            // start typing immediately. `loadFresh` seeds with empty
            // body + nil clock — the first save sends `base_clock: nil`
            // (advisory in server slice 2.2), the response populates the
            // clock for subsequent diffs.
            appState.remoteEditor.loadFresh(
                vaultID: vault.id,
                noteID: created.id,
                path: created.path
            )
            appState.selectedRemoteNoteID = created.id
            appState.remoteEditorMode = .edit
            dismiss()
        } catch let error as LumiAPIError {
            errorMessage = describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func describe(_ error: LumiAPIError) -> String {
        switch error {
        case .unauthorized: return "session expired — sign in again"
        case .network(let m): return "network error: \(m)"
        case .server(_, let code, let detail):
            switch code {
            case "forbidden":
                return "you don't have permission to create notes here (note.create)"
            case "validation", "validation_failed":
                return detail ?? "the server rejected the title — try a different one"
            case "slug_taken", "conflict":
                return "a note with that slug already exists in this vault"
            default:
                return detail ?? code
            }
        case .invalidResponse(let s): return "unexpected response (HTTP \(s))"
        case .decoding(let m): return "decode failed: \(m)"
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(theme.textDim)
    }
}
