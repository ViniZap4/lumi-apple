import SwiftUI
import LumiKit

/// Modal for creating a new server-side vault. Caller becomes the vault's
/// Admin. Name is required; slug is optional — when omitted the server
/// derives one from the name (and bumps with a suffix on collision).
struct CreateVaultSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var slug: String = ""
    @State private var slugTouched: Bool = false
    @State private var errorMessage: String?
    @State private var isSubmitting: Bool = false

    /// When the user hasn't manually edited slug, mirror name → derived slug.
    /// Matches the server's own derivation rules: lowercase, non-alphanumerics
    /// replaced with `-`, trimmed.
    private var derivedSlug: String {
        let lowered = name.lowercased()
        let chars = lowered.map { c -> Character in
            c.isLetter || c.isNumber ? c : "-"
        }
        let collapsed = String(chars).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("new vault")
                    .font(.headline)
                    .foregroundStyle(theme.text)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
            }

            fieldLabel("Name")
            TextField("Work team", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, _ in
                    if !slugTouched { slug = derivedSlug }
                }

            fieldLabel("Slug")
            TextField("work-team", text: $slug)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: slug) { _, new in
                    slugTouched = !new.isEmpty && new != derivedSlug
                }

            Text("slug appears in URLs and can't contain spaces. leave blank to let the server derive it from the name.")
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
                        Text("Create Vault")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || isSubmitting)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(theme.background)
    }

    private func submit() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let vault = try await appState.remoteVaultsStore.createVault(
                name: name,
                slug: slug.isEmpty ? nil : slug
            )
            // Auto-select the newly created vault so the user lands on its
            // detail view straight away.
            appState.selectedVaultID = nil
            appState.selectedRemoteVaultID = vault.id
            await appState.remoteVaultsStore.selectVault(vault.id)
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
            case "slug_taken":
                return "that slug is taken on this server — try a different one"
            case "validation", "validation_failed":
                return detail ?? "the server rejected the form — check your inputs"
            case "forbidden":
                return "you don't have permission to create vaults here"
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
