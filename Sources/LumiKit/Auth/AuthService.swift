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
        do {
            try Keychain.set(resp.token, account: serverURL.absoluteString)
        } catch {
            throw LumiAPIError.network(message: "keychain write failed: \(error)")
        }
        await client.setToken(resp.token)
        let session = AuthSession(serverURL: serverURL, user: resp.user, expiresAt: resp.expiresAt)
        currentSession = session
        if let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: sessionDefaultsKey)
        }
        return session
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
