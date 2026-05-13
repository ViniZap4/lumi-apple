import SwiftUI
import LumiKit

/// Read-only overview of a server-hosted vault: name + slug, member list with
/// roles, role list with capabilities, plus invite management for users with
/// the `members.invite` capability. Note CRUD lives in a future phase (E.1.2)
/// — that's why we don't surface a "notes" tab here yet.
struct RemoteVaultDetailView: View {
    let vault: RemoteVault
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var showCreateInvite: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                memberSection
                roleSection
                inviteSection
                auditSection
                placeholder
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.background)
        .sheet(isPresented: $showCreateInvite) {
            CreateInviteSheet(vault: vault, roles: appState.remoteVaultsStore.roles)
                .environment(appState)
                .environment(\.theme, theme)
        }
    }

    @ViewBuilder
    private var auditSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Audit log")
            if !canReadAudit && appState.remoteVaultsStore.auditEntries.isEmpty {
                Text("not visible (audit.read required)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            } else if appState.remoteVaultsStore.auditEntries.isEmpty {
                Text(appState.remoteVaultsStore.isLoading ? "loading…" : "no audit entries yet")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            } else {
                ForEach(appState.remoteVaultsStore.auditEntries) { entry in
                    auditRow(entry)
                }
                if appState.remoteVaultsStore.auditHasMore {
                    Button {
                        Task { await appState.remoteVaultsStore.loadMoreAudit() }
                    } label: {
                        Label("Load more", systemImage: "arrow.down.circle")
                            .font(.system(.callout, design: .monospaced))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.primary)
                }
            }
        }
    }

    /// `audit.read` capability check against the current session's member row.
    private var canReadAudit: Bool {
        guard let session = appState.authService.currentSession else { return false }
        let me = appState.remoteVaultsStore.members.first { $0.username == session.user.username }
        guard let caps = me?.capabilities else { return false }
        return caps.contains { $0 == "*" || $0 == "audit.*" || $0 == "audit.read" || $0 == "vault.*" }
    }

    @ViewBuilder
    private func auditRow(_ entry: AuditEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(theme.accent)
                Text(entry.action)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(theme.text)
                Spacer()
                if let when = entry.createdAt {
                    Text(when.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(theme.textDim)
                }
            }
            HStack(spacing: 8) {
                if let actor = userLabel(for: entry.userID) {
                    Text(actor)
                        .font(.caption)
                        .foregroundStyle(theme.textDim)
                }
                if let ip = entry.ip, !ip.isEmpty {
                    Text("· \(ip)")
                        .font(.caption2)
                        .foregroundStyle(theme.textDim)
                }
            }
            if !entry.payload.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(entry.payload.keys.sorted(), id: \.self) { key in
                        if let value = entry.payload[key] {
                            payloadChip(key: key, value: value)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.overlayBackground)
        )
    }

    /// Resolve a user ID to a display label using the loaded members list.
    /// Falls back to a short UUID prefix when the user isn't in the vault's
    /// member list (e.g. a former member whose row was scrubbed).
    private func userLabel(for id: UUID?) -> String? {
        guard let id else { return nil }
        if let member = appState.remoteVaultsStore.members.first(where: { $0.userID == id }) {
            return "@\(member.username)"
        }
        return "user \(id.uuidString.prefix(8).lowercased())"
    }

    private func payloadChip(key: String, value: AuditJSONValue) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.textDim)
            Text(value.preview)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(theme.background)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Invites")
                Spacer()
                if canCreateInvites {
                    Button {
                        showCreateInvite = true
                    } label: {
                        Label("New invite", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.primary)
                }
            }

            if appState.remoteVaultsStore.invites.isEmpty {
                Text(canCreateInvites ? "no invites yet" : "no invites visible (members.invite required)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            } else {
                ForEach(appState.remoteVaultsStore.invites) { invite in
                    inviteRow(invite)
                }
            }
        }
    }

    /// `members.invite` capability is owned by the current session's member
    /// row. We look it up against the vault's member list.
    private var canCreateInvites: Bool {
        guard let session = appState.authService.currentSession else { return false }
        let me = appState.remoteVaultsStore.members.first { $0.username == session.user.username }
        guard let caps = me?.capabilities else { return false }
        return caps.contains { $0 == "*" || $0 == "members.*" || $0 == "members.invite" || $0 == "vault.*" }
    }

    @ViewBuilder
    private func inviteRow(_ invite: VaultInvite) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "envelope")
                    .foregroundStyle(invite.isActive ? theme.accent : theme.textDim)
                Text(roleName(for: invite.roleID))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(theme.text)
                if let hint = invite.emailHint, !hint.isEmpty {
                    Text("· \(hint)")
                        .font(.caption)
                        .foregroundStyle(theme.textDim)
                }
                Spacer()
                statusBadge(for: invite)
                if invite.isActive && canCreateInvites {
                    Button {
                        Task { await revoke(invite) }
                    } label: {
                        Label("Revoke", systemImage: "xmark.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.textDim)
                }
            }
            Text(invite.token)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 12) {
                if invite.maxUses > 0 {
                    Text("uses: \(invite.useCount) / \(invite.maxUses)")
                        .font(.caption2)
                        .foregroundStyle(theme.textDim)
                } else {
                    Text("unlimited uses · \(invite.useCount) used")
                        .font(.caption2)
                        .foregroundStyle(theme.textDim)
                }
                if let expires = invite.expiresAt {
                    Text("expires \(expires.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(theme.textDim)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.overlayBackground)
        )
        .opacity(invite.isActive ? 1.0 : 0.6)
    }

    @ViewBuilder
    private func statusBadge(for invite: VaultInvite) -> some View {
        let (label, color): (String, Color) = {
            if invite.isRevoked { return ("revoked", theme.error) }
            if invite.isExpired { return ("expired", theme.error) }
            if invite.isExhausted { return ("used up", theme.warning) }
            return ("active", theme.accent)
        }()
        Text(label)
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(theme.background)
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func roleName(for id: UUID) -> String {
        appState.remoteVaultsStore.roles.first(where: { $0.id == id })?.name ?? "(unknown role)"
    }

    private func revoke(_ invite: VaultInvite) async {
        try? await appState.remoteVaultsStore.revokeInvite(token: invite.token)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "cloud.fill")
                    .foregroundStyle(theme.primary)
                Text(vault.name)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer()
                Button {
                    Task { await appState.remoteVaultsStore.selectVault(vault.id) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.textDim)
                .disabled(appState.remoteVaultsStore.isLoading)
            }
            Text(vault.slug)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.textDim)
            if let created = vault.createdAt {
                Text("created \(created.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
            if let error = appState.remoteVaultsStore.lastError {
                Text(describe(error))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.error)
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var memberSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Members")
            if appState.remoteVaultsStore.members.isEmpty {
                Text(appState.remoteVaultsStore.isLoading ? "loading…" : "no members yet")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            } else {
                ForEach(appState.remoteVaultsStore.members) { member in
                    memberRow(member)
                }
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ member: RemoteMember) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName.isEmpty ? member.username : member.displayName)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(theme.text)
                Text("@\(member.username)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
            Spacer()
            roleChip(member.roleName, isSeed: member.isSeedRole)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.overlayBackground)
        )
    }

    @ViewBuilder
    private var roleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Roles")
            if appState.remoteVaultsStore.roles.isEmpty {
                Text(appState.remoteVaultsStore.isLoading ? "loading…" : "no roles defined")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            } else {
                ForEach(appState.remoteVaultsStore.roles) { role in
                    roleRow(role)
                }
            }
        }
    }

    @ViewBuilder
    private func roleRow(_ role: RemoteRole) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(role.name)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(theme.text)
                if role.isSeed {
                    Text("seed")
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(theme.overlayBackground)
                        .foregroundStyle(theme.textDim)
                        .clipShape(Capsule())
                }
            }
            if role.capabilities.isEmpty {
                Text("no capabilities")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(role.capabilities, id: \.self) { cap in
                        Text(cap)
                            .font(.system(.caption2, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.overlayBackground)
                            .foregroundStyle(theme.accent)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.border, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Notes")
            Text("server-side note sync is coming in a later phase.")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.textDim)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(.title3, design: .monospaced).weight(.semibold))
            .foregroundStyle(theme.text)
    }

    private func roleChip(_ name: String, isSeed: Bool) -> some View {
        Text(name)
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(theme.overlayBackground)
                    .overlay(Capsule().stroke(theme.border, lineWidth: 0.5))
            )
            .foregroundStyle(isSeed ? theme.accent : theme.primary)
    }

    private func describe(_ error: LumiAPIError) -> String {
        switch error {
        case .unauthorized: return "session expired — sign in again"
        case .network(let m): return "network error: \(m)"
        case .server(_, let code, let detail): return detail ?? code
        case .invalidResponse(let s): return "unexpected response (HTTP \(s))"
        case .decoding(let m): return "decode failed: \(m)"
        }
    }
}

/// Minimal wrapping HStack-of-rows. SwiftUI doesn't have a built-in flow
/// layout pre-iOS 16+ but Layout is available on our deployment target.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var current = CGPoint.zero
        var maxX: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if current.x + size.width > width {
                current.x = 0
                current.y += rowHeight + spacing
                rowHeight = 0
            }
            maxX = max(maxX, current.x + size.width)
            rowHeight = max(rowHeight, size.height)
            current.x += size.width + spacing
        }
        return CGSize(width: maxX, height: current.y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var current = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if current.x + size.width > bounds.minX + width {
                current.x = bounds.minX
                current.y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: current, proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            current.x += size.width + spacing
        }
    }
}
