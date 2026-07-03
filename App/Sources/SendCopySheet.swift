import SwiftUI
import LumiKit

/// Modal form for SPEC-V3 "share a copy": forks the vault's current state
/// into a brand-new vault owned by another user on the same server. The
/// copy shares nothing after creation — no membership, no live link. On
/// success the result panel shows the fork's name + slug so the sender can
/// tell the recipient what to look for.
struct SendCopySheet: View {
    let vault: RemoteVault
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var recipientUsername: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var fork: RemoteVault?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(fork == nil ? "send a copy of \(vault.name)" : "copy sent")
                    .font(.headline)
                    .foregroundStyle(theme.text)
                Spacer()
                Button(fork == nil ? "Cancel" : "Done") { dismiss() }
                    .buttonStyle(.borderless)
            }

            if let fork {
                resultPanel(fork)
            } else {
                form
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(theme.background)
    }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Recipient username")
            TextField("username on this server", text: $recipientUsername)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { Task { await submit() } }

            Text("Creates an independent fork owned by the recipient. Edits diverge permanently — nothing stays shared.")
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
                    Text(isSubmitting ? "Sending…" : "Send Copy")
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedRecipient.isEmpty || isSubmitting)
            }
        }
    }

    @ViewBuilder
    private func resultPanel(_ fork: RemoteVault) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("@\(trimmedRecipient) now owns a copy named \"\(fork.name)\"")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.text)
            } icon: {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundStyle(theme.accent)
            }
            Text(fork.slug)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .textSelection(.enabled)
            Text("The copy is fully theirs — it won't receive any future changes from this vault.")
                .font(.caption)
                .foregroundStyle(theme.textDim)
        }
    }

    private var trimmedRecipient: String {
        recipientUsername.trimmingCharacters(in: .whitespaces)
    }

    private func submit() async {
        errorMessage = nil
        let recipient = trimmedRecipient
        guard !recipient.isEmpty else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            fork = try await appState.remoteVaultsStore.sendCopy(recipientUsername: recipient)
        } catch let error as LumiAPIError {
            errorMessage = describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func describe(_ error: LumiAPIError) -> String {
        if error.isRecipientNotFound {
            return "no user named @\(trimmedRecipient) on this server — check the username"
        }
        switch error {
        case .unauthorized: return "session expired — sign in again"
        case .network(let m): return "network error: \(m)"
        case .server(_, let code, let detail):
            switch code {
            case "forbidden":
                return "you don't have permission to export this vault (vault.export)"
            case "validation", "validation_failed":
                return detail ?? "the server rejected the request — check the username"
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
