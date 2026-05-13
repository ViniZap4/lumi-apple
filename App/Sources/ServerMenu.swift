import SwiftUI
import LumiKit

/// Toolbar entry point for server sign-in. When signed out, opens a sheet
/// with the sign-in form. When signed in, shows a menu with the current user
/// and a sign-out action.
struct ServerMenu: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var showSignIn: Bool = false

    var body: some View {
        Group {
            if let session = appState.authService.currentSession {
                Menu {
                    Section("Signed in") {
                        Label(session.user.displayName, systemImage: "person.crop.circle")
                        if !session.user.username.isEmpty {
                            Text("@\(session.user.username)")
                        }
                        Text(session.serverURL.absoluteString)
                            .font(.caption)
                    }
                    Divider()
                    Button(role: .destructive) {
                        Task { await appState.authService.signOut() }
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "cloud.fill")
                        .foregroundStyle(theme.primary)
                }
            } else {
                Button {
                    showSignIn = true
                } label: {
                    Image(systemName: "cloud")
                }
            }
        }
        .sheet(isPresented: $showSignIn) {
            SignInSheet()
                .environment(appState)
                .environment(\.theme, theme)
        }
    }
}

private struct SignInSheet: View {
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
                TextField("https://lumi.example.com", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS) || os(visionOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif

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
                    if appState.authService.isBusy {
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
    }

    private var title: String {
        switch mode {
        case .signIn: return "Sign in to lumi server"
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

    private var alreadySignedInToThisServer: Bool {
        guard let session = appState.authService.currentSession,
              let url = URL(string: serverURL)
        else { return false }
        return session.serverURL == url
    }

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
        guard !appState.authService.isBusy,
              URL(string: serverURL) != nil
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
        guard let url = URL(string: serverURL) else {
            errorMessage = "invalid server URL"
            return
        }
        isFetchingPreview = true
        defer { isFetchingPreview = false }
        do {
            invitePreview = try await appState.authService.previewInvite(serverURL: url, token: inviteToken)
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
        guard let url = URL(string: serverURL) else {
            errorMessage = "invalid server URL"
            return
        }
        do {
            switch mode {
            case .signIn:
                _ = try await appState.authService.signIn(serverURL: url, username: username, password: password)
            case .register:
                _ = try await appState.authService.register(
                    serverURL: url,
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
                    _ = try await appState.authService.acceptInviteWithSignup(
                        serverURL: url,
                        token: inviteToken,
                        username: username,
                        password: password,
                        displayName: displayName,
                        tosVersion: tosVersion,
                        privacyVersion: privacyVersion
                    )
                } else {
                    _ = try await appState.authService.acceptInviteAsExistingUser(serverURL: url, token: inviteToken)
                }
            }
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
