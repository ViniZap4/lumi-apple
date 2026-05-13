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

    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sign in to lumi server")
                    .font(.headline)
                    .foregroundStyle(theme.text)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
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
                    .textContentType(.password)
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
                        Text("Sign In")
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
        !appState.authService.isBusy
            && URL(string: serverURL) != nil
            && !username.isEmpty
            && !password.isEmpty
    }

    private func submit() async {
        errorMessage = nil
        guard let url = URL(string: serverURL) else {
            errorMessage = "invalid server URL"
            return
        }
        do {
            _ = try await appState.authService.signIn(serverURL: url, username: username, password: password)
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
            return detail ?? code
        case .invalidResponse(let status):
            return "unexpected server response (HTTP \(status))"
        case .decoding(let message):
            return "couldn't decode server response — \(message)"
        }
    }
}
