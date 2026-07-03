import SwiftUI
import LumiKit

/// Modal form for handing a vault to another member (SPEC-V3 ownership).
/// Owner-only — the caller gates presentation on `isOwner`; the server
/// enforces the same rule with a 403. Picks the new owner from the vault's
/// member list (current owner excluded) and requires an explicit
/// confirmation before firing the irreversible transfer.
struct TransferOwnershipSheet: View {
    let vault: RemoteVault
    let members: [RemoteMember]
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedUserID: UUID?
    @State private var showConfirm: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var transferred: RemoteVault?

    /// Everyone the vault can be handed to: members minus the current owner.
    private var candidates: [RemoteMember] {
        members.filter { $0.userID != vault.ownerUserID }
    }

    private var selectedMember: RemoteMember? {
        candidates.first { $0.userID == selectedUserID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(transferred == nil ? "transfer ownership of \(vault.name)" : "ownership transferred")
                    .font(.headline)
                    .foregroundStyle(theme.text)
                Spacer()
                Button(transferred == nil ? "Cancel" : "Done") { dismiss() }
                    .buttonStyle(.borderless)
            }

            if let transferred {
                resultPanel(transferred)
            } else {
                form
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(theme.background)
        .onAppear {
            if selectedUserID == nil {
                selectedUserID = candidates.first?.userID
            }
        }
        .confirmationDialog(
            confirmTitle,
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Transfer ownership", role: .destructive) {
                Task { await submit() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The new owner gains a permanent Admin-equivalent grant and you lose owner status. This cannot be undone without their cooperation.")
        }
    }

    private var confirmTitle: String {
        if let member = selectedMember {
            return "Make @\(member.username) the owner of \"\(vault.name)\"?"
        }
        return "Transfer ownership?"
    }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            if candidates.isEmpty {
                Text("no other members to transfer to — invite someone first")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            } else {
                fieldLabel("New owner")
                Picker("New owner", selection: $selectedUserID) {
                    ForEach(candidates) { member in
                        Text(memberLabel(member)).tag(Optional(member.userID))
                    }
                }
                .pickerStyle(.menu)

                Text("The target must already be a member. Ownership carries a non-removable Admin-equivalent grant.")
                    .font(.caption)
                    .foregroundStyle(theme.textDim)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(theme.error)
                    .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button {
                    showConfirm = true
                } label: {
                    Text(isSubmitting ? "Transferring…" : "Transfer Ownership…")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedUserID == nil || isSubmitting)
            }
        }
    }

    @ViewBuilder
    private func resultPanel(_ vault: RemoteVault) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(resultLabel(vault))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.text)
            } icon: {
                Image(systemName: "crown.fill")
                    .foregroundStyle(theme.warning)
            }
            Text("You keep your current role; the new owner now holds the protected grant.")
                .font(.caption)
                .foregroundStyle(theme.textDim)
        }
    }

    private func resultLabel(_ vault: RemoteVault) -> String {
        if let owner = members.first(where: { $0.userID == vault.ownerUserID }) {
            return "@\(owner.username) now owns \(vault.name)"
        }
        return "\(vault.name) has a new owner"
    }

    private func memberLabel(_ member: RemoteMember) -> String {
        member.displayName.isEmpty
            ? "@\(member.username)"
            : "\(member.displayName) (@\(member.username))"
    }

    private func submit() async {
        errorMessage = nil
        guard let userID = selectedUserID else {
            errorMessage = "pick a member first"
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            transferred = try await appState.remoteVaultsStore.transferOwnership(newOwnerUserID: userID)
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
                return "only the current owner can transfer ownership"
            case "validation", "validation_failed":
                return detail ?? "the target must already be a member of this vault"
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
