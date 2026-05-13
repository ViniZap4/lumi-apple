import SwiftUI
import LumiKit

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Modal form for generating a new vault invite. Picks a role from the
/// vault's role list, sets max uses + expiry, optional email hint. On
/// submit, the result panel surfaces the shareable URL (or token) with a
/// copy-to-clipboard button.
struct CreateInviteSheet: View {
    let vault: RemoteVault
    let roles: [RemoteRole]
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedRoleID: UUID?
    @State private var maxUses: Int = 1
    @State private var expiryDate: Date = Date().addingTimeInterval(7 * 24 * 3600)
    @State private var emailHint: String = ""
    @State private var errorMessage: String?
    @State private var created: CreatedInvite?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(created == nil ? "new invite for \(vault.name)" : "invite created")
                    .font(.headline)
                    .foregroundStyle(theme.text)
                Spacer()
                Button(created == nil ? "Cancel" : "Done") { dismiss() }
                    .buttonStyle(.borderless)
            }

            if let created {
                resultPanel(created)
            } else {
                form
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(theme.background)
        .onAppear {
            if selectedRoleID == nil {
                // Default to the non-Admin seed role with the fewest capabilities
                // (typically Viewer) to nudge least-privilege selection.
                selectedRoleID = defaultRoleID()
            }
        }
    }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Role")
            Picker("Role", selection: $selectedRoleID) {
                ForEach(roles) { role in
                    Text(role.name).tag(Optional(role.id))
                }
            }
            .pickerStyle(.menu)

            fieldLabel("Max uses (0 = unlimited)")
            Stepper(value: $maxUses, in: 0...100) {
                Text("\(maxUses)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.text)
            }

            fieldLabel("Expires")
            DatePicker(
                "Expires",
                selection: $expiryDate,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()

            fieldLabel("Email hint (optional)")
            TextField("alice@example.com", text: $emailHint)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS) || os(visionOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                #endif

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
                    Text("Create Invite")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedRoleID == nil)
            }
        }
    }

    @ViewBuilder
    private func resultPanel(_ invite: CreatedInvite) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("share this link with the invitee:")
                .font(.callout)
                .foregroundStyle(theme.textDim)
            Text(shareString(invite))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.text)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.overlayBackground)
                )
                .textSelection(.enabled)
            HStack {
                Button {
                    copyToPasteboard(shareString(invite))
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Spacer()
                Text(maxUsesLabel(invite))
                    .font(.caption)
                    .foregroundStyle(theme.textDim)
            }
            if let expiry = invite.expiresAt {
                Text("expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(theme.textDim)
            }
        }
    }

    private func defaultRoleID() -> UUID? {
        // Prefer seed Viewer / non-Admin if present; otherwise the last role.
        if let viewer = roles.first(where: { $0.isSeed && $0.name.localizedCaseInsensitiveCompare("Viewer") == .orderedSame }) {
            return viewer.id
        }
        if let nonAdmin = roles.first(where: { !$0.name.localizedCaseInsensitiveContains("admin") }) {
            return nonAdmin.id
        }
        return roles.last?.id
    }

    private func shareString(_ invite: CreatedInvite) -> String {
        invite.url ?? invite.token
    }

    private func maxUsesLabel(_ invite: CreatedInvite) -> String {
        invite.maxUses == 0 ? "unlimited uses" : "\(invite.maxUses) use\(invite.maxUses == 1 ? "" : "s")"
    }

    private func copyToPasteboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    private func submit() async {
        errorMessage = nil
        guard let roleID = selectedRoleID else {
            errorMessage = "pick a role first"
            return
        }
        do {
            created = try await appState.remoteVaultsStore.createInvite(
                roleID: roleID,
                maxUses: maxUses,
                expiresAt: expiryDate,
                emailHint: emailHint
            )
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
            case "forbidden", "capability_required":
                return "you don't have permission to create invites in this vault (members.invite)"
            case "invalid_role_id", "validation_failed":
                return detail ?? "the server rejected the form — check your inputs"
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
