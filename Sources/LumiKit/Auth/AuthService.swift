import Foundation
import Observation

/// Owns the live `AuthSession` (if any) and orchestrates the API client +
/// keychain on the host's behalf. UI binds to `currentSession` and calls
/// `signIn` / `signOut` / `restore`.
///
/// All public state is `@MainActor` so SwiftUI observation is cheap; network
/// calls jump to the API actor and back.
@Observable
@MainActor
public final class AuthService {
    public private(set) var currentSession: AuthSession?
    /// True while a sign-in or restore is in flight. UI uses this to disable
    /// the submit button and show a spinner.
    public private(set) var isBusy: Bool = false

    private let client: LumiAPIClient
    private let defaults: UserDefaults
    private let sessionDefaultsKey = "lumi.auth.session.v1"

    public init(client: LumiAPIClient = LumiAPIClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
    }

    /// Attempt to rehydrate a previous session at app launch. Reads the JSON
    /// sidecar from UserDefaults; looks up the token in the Keychain; sets the
    /// client's base URL + token; verifies via `/users/me`. On any failure the
    /// stored session is purged so the UI shows the sign-in form.
    public func restore() async {
        guard let data = defaults.data(forKey: sessionDefaultsKey) else { return }
        guard let stored = try? JSONDecoder().decode(AuthSession.self, from: data) else {
            defaults.removeObject(forKey: sessionDefaultsKey)
            return
        }
        guard let token = try? Keychain.get(account: stored.serverURL.absoluteString) else {
            // Token missing — wipe the sidecar; user must sign in again.
            defaults.removeObject(forKey: sessionDefaultsKey)
            return
        }
        isBusy = true
        await client.setBaseURL(stored.serverURL)
        await client.setToken(token)
        do {
            let user = try await client.currentUser()
            currentSession = AuthSession(serverURL: stored.serverURL, user: user, expiresAt: stored.expiresAt)
        } catch {
            await client.setToken(nil)
            try? Keychain.delete(account: stored.serverURL.absoluteString)
            defaults.removeObject(forKey: sessionDefaultsKey)
        }
        isBusy = false
    }

    /// Sign in against `serverURL` with `username` / `password`. On success,
    /// `currentSession` is set and the token is persisted to the Keychain.
    @discardableResult
    public func signIn(serverURL: URL, username: String, password: String) async throws(LumiAPIError) -> AuthSession {
        isBusy = true
        defer { isBusy = false }
        await client.setBaseURL(serverURL)
        await client.setToken(nil)
        let resp = try await client.login(username: username, password: password)
        return try await persist(serverURL: serverURL, response: resp)
    }

    /// Create a new account against `serverURL`. Only works when the server's
    /// `RegistrationPolicy` is `open` — a closed server returns
    /// `.server(status: 403, code: "registration_closed", …)`. `tosVersion`
    /// and `privacyVersion` must match the server's configured versions if it
    /// requires consent; pass empty strings otherwise.
    @discardableResult
    public func register(
        serverURL: URL,
        username: String,
        password: String,
        displayName: String,
        tosVersion: String,
        privacyVersion: String
    ) async throws(LumiAPIError) -> AuthSession {
        isBusy = true
        defer { isBusy = false }
        await client.setBaseURL(serverURL)
        await client.setToken(nil)
        let resp = try await client.register(
            username: username,
            password: password,
            displayName: displayName,
            tosVersion: tosVersion,
            privacyVersion: privacyVersion
        )
        return try await persist(serverURL: serverURL, response: resp)
    }

    /// Common tail of `signIn` and `register`: store the token in the
    /// Keychain, mirror to the API client + UserDefaults, publish the
    /// `currentSession`. Awaits the actor's token write before returning so
    /// the next outbound request is authenticated.
    private func persist(serverURL: URL, response: SessionResponse) async throws(LumiAPIError) -> AuthSession {
        do {
            try Keychain.set(response.token, account: serverURL.absoluteString)
        } catch {
            throw LumiAPIError.network(message: "keychain write failed: \(error)")
        }
        await client.setToken(response.token)
        let session = AuthSession(serverURL: serverURL, user: response.user, expiresAt: response.expiresAt)
        currentSession = session
        if let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: sessionDefaultsKey)
        }
        return session
    }

    /// Fetch the invite preview without committing — used by the UI to show
    /// "Join Work as Editor?" before the user agrees. Doesn't touch
    /// `currentSession`.
    public func previewInvite(serverURL: URL, token: String) async throws(LumiAPIError) -> InvitePreview {
        await client.setBaseURL(serverURL)
        return try await client.previewInvite(token: token)
    }

    /// Accept an invite as the currently-signed-in user. Requires that the
    /// session was issued by `serverURL` — otherwise the token won't match.
    /// Returns the joined vault so the UI can navigate to it.
    @discardableResult
    public func acceptInviteAsExistingUser(serverURL: URL, token: String) async throws(LumiAPIError) -> AcceptedVault {
        isBusy = true
        defer { isBusy = false }
        await client.setBaseURL(serverURL)
        // Token should already be set from a prior signIn/register; if not,
        // the client will throw .unauthorized.
        return try await client.acceptInviteAsExistingUser(token: token)
    }

    /// Accept an invite *and* create the account in one step. The session
    /// returned by the server is persisted the same way as login/register.
    @discardableResult
    public func acceptInviteWithSignup(
        serverURL: URL,
        token: String,
        username: String,
        password: String,
        displayName: String,
        tosVersion: String,
        privacyVersion: String
    ) async throws(LumiAPIError) -> AcceptedInviteSession {
        isBusy = true
        defer { isBusy = false }
        await client.setBaseURL(serverURL)
        await client.setToken(nil)
        let accepted = try await client.acceptInviteWithSignup(
            token: token,
            username: username,
            password: password,
            displayName: displayName,
            tosVersion: tosVersion,
            privacyVersion: privacyVersion
        )
        // Build a SessionResponse-equivalent so persist() can do its job.
        // The signup-accept response doesn't include the full user object,
        // so we synthesize one from the captured display name / username.
        let userDTO = UserDTO(id: "", username: username, displayName: displayName)
        let synthetic = SessionResponse(token: accepted.token, expiresAt: accepted.expiresAt, user: userDTO)
        _ = try await persist(serverURL: serverURL, response: synthetic)
        return accepted
    }

    /// Drop the current session locally and tell the server to invalidate the
    /// token. Server errors are swallowed (the local clear is the important
    /// part — if the network is down, the user still expects to be signed
    /// out on this device).
    public func signOut() async {
        guard let session = currentSession else { return }
        isBusy = true
        defer { isBusy = false }
        try? await client.logout()
        await client.setToken(nil)
        try? Keychain.delete(account: session.serverURL.absoluteString)
        defaults.removeObject(forKey: sessionDefaultsKey)
        currentSession = nil
    }

    /// Exposes the underlying client so subsequent phases (vault discovery,
    /// note sync) can issue requests on the authenticated session without
    /// having to plumb a second copy of the configuration.
    public var apiClient: LumiAPIClient { client }
}
