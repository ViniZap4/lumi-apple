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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(mode == .signIn ? "Sign in to lumi server" : "Create lumi account")
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
            .onChange(of: mode) { _, _ in errorMessage = nil }

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

                if mode == .register {
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
                        Text(mode == .signIn ? "Sign In" : "Create Account")
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

    private var canSubmit: Bool {
        guard !appState.authService.isBusy,
              URL(string: serverURL) != nil,
              !username.isEmpty,
              !password.isEmpty
        else { return false }
        if mode == .register {
            return !displayName.isEmpty && agreedToTerms
        }
        return true
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
            }
            dismiss()
        } catch let error as LumiAPIError {
            errorMessage = describe(error)
        } catch {
            errorMessage = error.localizedDescription
        }
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
