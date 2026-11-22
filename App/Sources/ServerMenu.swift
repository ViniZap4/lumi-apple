import SwiftUI
import LumiKit
import LumiUI

/// Toolbar accounts menu: every (server, username) this device knows,
/// its sign-in state, and "Add server…". Several accounts per server are
/// allowed (SPEC-LIVROS §2.2).
struct ServerMenu: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        let accounts = appState.accounts.accounts
        Menu {
            if accounts.isEmpty {
                Text("no accounts on this device")
            }
            ForEach(accounts) { acc in
                let state = appState.accounts.state(acc.key)
                Menu {
                    Text(acc.displayName.isEmpty ? acc.username : acc.displayName)
                    Text(acc.serverURL)
                    Divider()
                    if state.isSignedIn {
                        Button("Sign out on this device") {
                            Task {
                                await appState.accounts.signOut(acc.key)
                                await appState.accountsChanged()
                            }
                        }
                    } else {
                        Button("Sign in…") {
                            appState.signInPrefill = acc.key
                            appState.showAddServer = true
                        }
                    }
                    Button("Remove account from this device", role: .destructive) {
                        Task {
                            await appState.accounts.remove(acc.key)
                            await appState.accountsChanged()
                        }
                    }
                } label: {
                    Label(acc.key.description, systemImage: state.isSignedIn ? "person.crop.circle.fill" : "exclamationmark.circle")
                }
            }
            Divider()
            Button("Add server…") {
                appState.signInPrefill = nil
                appState.showAddServer = true
            }
        } label: {
            Image(systemName: accounts.contains { appState.accounts.state($0.key).isSignedIn } ? "cloud.fill" : "cloud")
                .foregroundStyle(theme.primary)
        }
        .help("Accounts")
    }
}

/// "Add server…" / sign-in flow: URL → `GET /api/info` → credentials or
/// invite. Also used to re-sign-in an existing account.
struct SignInSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign In"
        case register = "Create Account"
        case invite = "Accept Invite"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .signIn
    @State private var serverURL: String = ""
    @State private var serverInfo: ServerInfo?
    @State private var serverInfoNote: String?
    @State private var isCheckingServer = false
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var displayName: String = ""
    @State private var tosVersion: String = ""
    @State private var privacyVersion: String = ""
    @State private var agreedToTerms: Bool = false
    @State private var errorMessage: String?

    // Invite-accept-only state.
    @State private var inviteToken: String = ""
    @State private var invitePreview: InvitePreview?
    @State private var isFetchingPreview: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(theme.text)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
            }

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, _ in
                errorMessage = nil
                invitePreview = nil
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Server URL")
                HStack {
                    TextField("https://lumi.example.com", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit { Task { await checkServer() } }
                        .onChange(of: serverURL) { _, _ in serverInfo = nil; serverInfoNote = nil }
                    Button {
                        Task { await checkServer() }
                    } label: {
                        if isCheckingServer { ProgressView().controlSize(.small) } else { Text("Check") }
                    }
                    .disabled(serverURL.isEmpty || isCheckingServer)
                }
                if let info = serverInfo {
                    Text("\(info.name ?? "lumi server")\(info.version.map { " · v\($0)" } ?? "")")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.text)
                }
                if let note = serverInfoNote {
                    Text(note)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }
                if let normalized = try? ServerURL.normalize(serverURL), ServerURL.isInsecure(normalized) {
                    Text("⚠︎ plain http: only use this on a private network — traffic and your password are not encrypted.")
                        .font(.caption)
                        .foregroundStyle(theme.warning)
                }

                if mode == .invite {
                    fieldLabel("Invite link or token")
                    TextField("https://lumi.example.com/invite/abc… or just the token", text: $inviteToken)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onChange(of: inviteToken) { _, raw in
                            if let parsed = extractServerAndToken(from: raw) {
                                serverURL = parsed.serverURL
                                inviteToken = parsed.token
                            }
                        }

                    HStack {
                        Button {
                            Task { await fetchPreview() }
                        } label: {
                            if isFetchingPreview {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Preview invite")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(serverURL.isEmpty || inviteToken.isEmpty || isFetchingPreview)
                        Spacer()
                    }

                    if let preview = invitePreview {
                        invitePreviewPanel(preview)
                    }
                } else {
                    fieldLabel("Username")
                    TextField("alice", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        #endif

                    fieldLabel("Password")
                    SecureField("•••••••••", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(mode == .signIn ? .password : .newPassword)
                }

                if mode == .register || (mode == .invite && (invitePreview?.requiresSignup ?? false)) {
                    if mode == .invite {
                        fieldLabel("Username (new account)")
                        TextField("alice", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            #if os(iOS) || os(visionOS)
                            .textInputAutocapitalization(.never)
                            #endif

                        fieldLabel("Password")
                        SecureField("•••••••••", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.newPassword)
                    }

                    fieldLabel("Display name")
                    TextField("Alice", text: $displayName)
                        .textFieldStyle(.roundedBorder)

                    DisclosureGroup("Consent (advanced)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Required only when the server enforces TOS/Privacy versions. Paste the strings from your server operator.")
                                .font(.caption)
                                .foregroundStyle(theme.textDim)
                            fieldLabel("ToS version")
                            TextField("v1", text: $tosVersion)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                #if os(iOS) || os(visionOS)
                                .textInputAutocapitalization(.never)
                                #endif
                            fieldLabel("Privacy version")
                            TextField("v1", text: $privacyVersion)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                #if os(iOS) || os(visionOS)
                                .textInputAutocapitalization(.never)
                                #endif
                        }
                        .padding(.top, 6)
                    }
                    .font(.caption)
                    .foregroundStyle(theme.text)

                    Toggle(isOn: $agreedToTerms) {
                        Text("I agree to the server's Terms of Service and Privacy Policy")
                            .font(.caption)
                            .foregroundStyle(theme.text)
                    }
                }
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
                    Task { await submit() }
                } label: {
                    if appState.accounts.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(submitButtonLabel)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(theme.background)
        .onAppear {
            if let prefill = appState.signInPrefill {
                serverURL = prefill.serverURL
                username = prefill.username
            }
        }
    }

    /// `GET /api/info`: show name/version; warn when the same public key
    /// is already registered under another URL (§2.1). Pre-feed servers
    /// answer 404 — that's fine, we just can't show the details.
    private func checkServer() async {
        errorMessage = nil
        guard let normalized = try? ServerURL.normalize(serverURL) else {
            errorMessage = "invalid server URL (http:// is only allowed for localhost, private IPs and *.local)"
            return
        }
        isCheckingServer = true
        defer { isCheckingServer = false }
        do {
            let info = try await appState.accounts.serverInfo(serverURL: normalized)
            serverInfo = info
            serverInfoNote = nil
            if let key = info.publicKey {
                let known = Set(appState.accounts.accounts.map(\.serverURL)).subtracting([normalized])
                for other in known {
                    if let otherInfo = try? await appState.accounts.serverInfo(serverURL: other), otherInfo.publicKey == key {
                        serverInfoNote = "this is the same server as \(other) — using that address"
                        serverURL = other
                        break
                    }
                }
            }
        } catch let error as LumiAPIError where error.isEndpointMissing {
            serverInfo = nil
            serverInfoNote = "server reachable (older version without /api/info)"
        } catch let error as LumiAPIError {
            serverInfo = nil
            errorMessage = describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var title: String {
        switch mode {
        case .signIn: return appState.signInPrefill == nil ? "Add server" : "Sign in"
        case .register: return "Create lumi account"
        case .invite: return "Accept lumi invitation"
        }
    }

    private var submitButtonLabel: String {
        switch mode {
        case .signIn: return "Sign In"
        case .register: return "Create Account"
        case .invite:
            return (invitePreview?.requiresSignup ?? !alreadySignedInToThisServer) ? "Accept & Create Account" : "Accept Invitation"
        }
    }

    /// Signed-in account on the typed server (invite accept as existing user).
    private var existingAccountOnThisServer: AccountKey? {
        guard let normalized = try? ServerURL.normalize(serverURL) else { return nil }
        let candidates = appState.accounts.accounts(on: normalized).filter { appState.accounts.state($0.key).isSignedIn }
        return (candidates.first { $0.username == username } ?? candidates.first)?.key
    }

    private var alreadySignedInToThisServer: Bool { existingAccountOnThisServer != nil }

    @ViewBuilder
    private func invitePreviewPanel(_ preview: InvitePreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.fill")
                    .foregroundStyle(theme.primary)
                Text(preview.vaultName)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(theme.text)
                Text("·").foregroundStyle(theme.textDim)
                Text(preview.roleName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.accent)
            }
            if let email = preview.emailHint, !email.isEmpty {
                Text("for \(email)")
                    .font(.caption)
                    .foregroundStyle(theme.textDim)
            }
            if let expiry = preview.expiresAt {
                Text("expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(theme.textDim)
            }
            if let max = preview.maxUses {
                Text("uses: \(preview.useCount) / \(max)")
                    .font(.caption)
                    .foregroundStyle(theme.textDim)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.overlayBackground)
        )
    }

    private var canSubmit: Bool {
        guard !appState.accounts.isBusy,
              (try? ServerURL.normalize(serverURL)) != nil
        else { return false }
        switch mode {
        case .signIn:
            return !username.isEmpty && !password.isEmpty
        case .register:
            return !username.isEmpty && !password.isEmpty && !displayName.isEmpty && agreedToTerms
        case .invite:
            guard !inviteToken.isEmpty, let preview = invitePreview else { return false }
            if preview.requiresSignup {
                return !username.isEmpty && !password.isEmpty && !displayName.isEmpty && agreedToTerms
            }
            // Existing-user path: must already be signed in to this server.
            return alreadySignedInToThisServer
        }
    }

    private func fetchPreview() async {
        errorMessage = nil
        isFetchingPreview = true
        defer { isFetchingPreview = false }
        do {
            invitePreview = try await appState.accounts.previewInvite(serverURL: serverURL, token: inviteToken)
        } catch let error as LumiAPIError {
            invitePreview = nil
            errorMessage = describe(error)
        } catch {
            invitePreview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func submit() async {
        errorMessage = nil
        do {
            switch mode {
            case .signIn:
                _ = try await appState.accounts.signIn(serverURL: serverURL, username: username, password: password)
            case .register:
                _ = try await appState.accounts.register(
                    serverURL: serverURL,
                    username: username,
                    password: password,
                    displayName: displayName,
                    tosVersion: tosVersion,
                    privacyVersion: privacyVersion
                )
            case .invite:
                guard let preview = invitePreview else {
                    errorMessage = "preview the invite first"
                    return
                }
                if preview.requiresSignup {
                    _ = try await appState.accounts.acceptInviteWithSignup(
                        serverURL: serverURL,
                        token: inviteToken,
                        username: username,
                        password: password,
                        displayName: displayName,
                        tosVersion: tosVersion,
                        privacyVersion: privacyVersion
                    )
                } else {
                    guard let key = existingAccountOnThisServer else {
                        errorMessage = "sign in to this server first"
                        return
                    }
                    _ = try await appState.accounts.acceptInviteAsExistingUser(key, token: inviteToken)
                }
            }
            appState.signInPrefill = nil
            await appState.accountsChanged()
            dismiss()
        } catch let error as LumiAPIError {
            errorMessage = describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Parse a pasted invite URL into (serverURL, token). Accepts shapes like
    /// `https://lumi.example.com/invite/abc123` or
    /// `https://lumi.example.com/api/invites/abc123`. Returns nil if `raw`
    /// doesn't look like a URL containing an `/invite[s]/` path component.
    private func extractServerAndToken(from raw: String) -> (serverURL: String, token: String)? {
        guard let url = URL(string: raw),
              let host = url.host,
              let scheme = url.scheme,
              !url.pathComponents.isEmpty
        else { return nil }
        let components = url.pathComponents
        guard let idx = components.firstIndex(where: { $0 == "invite" || $0 == "invites" }),
              idx + 1 < components.count
        else { return nil }
        let token = components[idx + 1]
        let server = "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
        return (server, token)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(theme.textDim)
    }

    private func describe(_ error: LumiAPIError) -> String {
        switch error {
        case .unauthorized:
            return "incorrect username or password"
        case .network(let message):
            return "network error — \(message)"
        case .server(_, let code, let detail):
            // Friendly translations for the common register-failure codes.
            switch code {
            case "registration_closed":
                return "this server doesn't allow new accounts here — you may need an invite link"
            case "consent_required":
                return "the server requires you to agree to its current Terms of Service and Privacy Policy (set the version strings under Consent (advanced))"
            case "validation_failed":
                return detail ?? "the server rejected the form — check your inputs"
            case "username_taken":
                return "that username is taken"
            case "invalid_credentials":
                return "incorrect username or password"
            case "invite_not_found":
                return "no such invite — the link may be wrong or has been revoked"
            case "invite_expired":
                return "this invite has expired — ask the inviter for a fresh one"
            case "invite_exhausted":
                return "this invite has already been used up"
            case "already_member":
                return "you're already a member of this vault"
            case "missing_token":
                return "missing invite token"
            default:
                return detail ?? code
            }
        case .invalidResponse(let status):
            return "unexpected server response (HTTP \(status))"
        case .decoding(let message):
            return "couldn't decode server response — \(message)"
        }
    }
}
