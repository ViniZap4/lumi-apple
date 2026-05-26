import Foundation
import Observation

/// Coordinates server-vault state for the UI. Holds the list of vaults the
/// signed-in user belongs to plus the members/roles of whichever vault the
/// user has selected. Network failures are surfaced as `lastError`; transient
/// loading state via `isLoading`.
///
/// The store doesn't subscribe to `AuthService`; the host calls `refresh()`
/// at the right moments (post-sign-in, manual refresh button) and `clear()`
/// on sign-out. Keeping the wiring imperative makes the lifecycle easy to
/// reason about.
@Observable
@MainActor
public final class RemoteVaultsStore {
    public private(set) var vaults: [RemoteVault] = []
    public private(set) var selectedVaultID: UUID?
    public private(set) var members: [RemoteMember] = []
    public private(set) var roles: [RemoteRole] = []
    public private(set) var invites: [VaultInvite] = []
    public private(set) var auditEntries: [AuditEntry] = []
    /// True once we've loaded *less* than a full page — paginated views use
    /// this to decide whether to render a "Load more" button.
    public private(set) var auditHasMore: Bool = false
    public private(set) var notes: [RemoteNote] = []
    public private(set) var notesHasMore: Bool = false
    /// The currently-open server note's CRDT snapshot (body text + base64
    /// state vector). Set by `loadOpenNote`; cleared by `closeOpenNote`.
    /// Slice 4d migrated the underlying transport from `GET .../content`
    /// to `GET .../snapshot` so the same round-trip seeds the editor *and*
    /// arms the clock for the eventual `applyDiff` save.
    public private(set) var openNoteSnapshot: RemoteNoteSnapshot?
    public private(set) var openNoteIsLoading: Bool = false
    /// Non-nil when the most recent `loadOpenNote` failed. Cleared on a
    /// successful subsequent load or on `closeOpenNote`.
    public private(set) var openNoteError: LumiAPIError?

    /// True when the WS sync subscription has flagged that a remote update
    /// landed since the host last refreshed. Reset by
    /// `acknowledgeRemoteUpdate()` (typically called by the host after a
    /// `loadOpenNote` refetch settles the screen). Slice 4e.
    public private(set) var hasRemoteUpdate: Bool = false

    /// Non-nil when the store is currently waiting out a backoff before
    /// re-subscribing the WS sync channel. Hosts render this as a small
    /// "reconnecting in Ns…" hint above the editor; nil means the WS is
    /// either connected (`.opened` cleared it) or the host stopped
    /// subscribing (`unsubscribeFromOpenNote` cleared it). Slice 4f.2.
    public private(set) var reconnectStatus: ReconnectStatus?
    /// Active WS sync client; nil when no note is open or the host is
    /// running in REST-only mode.
    @ObservationIgnored private var syncClient: NoteSyncClient?
    /// Task pumping `syncClient.events` onto the main actor. Cancelled by
    /// `unsubscribeFromOpenNote()`.
    @ObservationIgnored private var syncEventsTask: Task<Void, Never>?
    /// Pending reconnect Task created in response to a `.willReconnect`
    /// event. Cancelled by `unsubscribeFromOpenNote()` so an explicit
    /// stop never gets undone by a delayed wake-up. Slice 4f.
    @ObservationIgnored private var syncReconnectTask: Task<Void, Never>?
    /// (vaultID, noteID) of whatever note the WS client is currently
    /// subscribed to. Recorded so the reconnect path knows what to
    /// re-subscribe to without the host having to re-issue. Cleared by
    /// `unsubscribeFromOpenNote()`. Slice 4f.
    @ObservationIgnored private var syncOpenNoteKey: (vaultID: UUID, noteID: String)?
    /// Wall-clock instant at which the WS most recently received an
    /// `.opened` event. Used by `decideReconnect` to detect a long-
    /// lived connection that drops — the next failure is then treated
    /// as a fresh curve (attempt 1) instead of inheriting the prior
    /// backoff state. Cleared on `.willReconnect` (consumed for the
    /// decision) and on `unsubscribeFromOpenNote()`. Slice 4f.1.
    @ObservationIgnored private var syncOpenedAt: Date?
    /// Max consecutive transient-close reconnect attempts before we give
    /// up. With 1s base + 2^n growth capped at 32s, 8 attempts ≈ 2.5
    /// minutes of trying — beyond that the server is presumably down or
    /// the network is gone for good, and silently retrying forever just
    /// burns battery. The host can re-arm by re-opening the note.
    private static let maxReconnectAttempts: Int = 8
    /// Connections that survive at least this many seconds before a
    /// transient close are considered "stabilised" — the next drop
    /// starts a fresh backoff curve instead of continuing the prior
    /// one. Tuned for "user moved off coffee shop wifi for a minute
    /// after typing for half an hour" — not for "server is flapping".
    /// Slice 4f.1.
    public static let reconnectStabilitySeconds: TimeInterval = 30

    /// CRDT mirroring the server's state for the currently-open note.
    /// Lifecycle is bound to (loadOpenNote → subscribeToOpenNote →
    /// closeOpenNote): fresh on every open, populated by the first
    /// SyncStep2 the server replies with, kept up-to-date by
    /// subsequent SyncUpdate frames. nil when no note is open.
    /// Phase H slice 2. Exposed read-only (slice 3) so the editor's
    /// commit path can encode a diff against the local CRDT's state.
    @ObservationIgnored public private(set) var openNoteCRDT: LumiCRDT?

    /// Latest text the open-note CRDT holds. Updated after each
    /// successfully-applied WS update (`.syncStep2` / `.syncUpdate`).
    /// Hosts observe this to merge live edits into the editor when
    /// the user isn't dirty; nil means no update has arrived yet.
    /// Phase H slice 2.
    public private(set) var openNoteLiveText: String?

    /// Other peers currently subscribed to the open note, sorted by
    /// clientID for a stable rendering order. Phase H slice 4. The
    /// local user's own presence is broadcast on subscribe but is
    /// NOT included in this list — `openNotePresence` is "everyone
    /// else viewing".
    public private(set) var openNotePresence: [PresenceState] = []

    /// Our own presence broadcast on the awareness channel for the
    /// open note. Echoed back from the server but filtered out of
    /// `openNotePresence` via `clientID`. Set by `subscribeToOpenNote`
    /// when the caller passes a non-nil `presence`. Phase H slice 4.
    @ObservationIgnored private var ownPresence: PresenceState?

    /// Peer-keyed presence map populated by incoming awareness frames.
    /// Republished as the sorted `openNotePresence` whenever it
    /// changes. Phase H slice 4.
    @ObservationIgnored private var presenceByClient: [UUID: PresenceState] = [:]

    /// Background Task that re-broadcasts `ownPresence` every
    /// `presenceHeartbeatSeconds` while a WS subscription is alive.
    /// Without this, a peer who joined the room *after* our initial
    /// broadcast wouldn't see us (the server only relays; it doesn't
    /// keep state). Matches canonical y-protocols cadence
    /// (`outdatedTimeout / 2 = 15s`) — peers locally evict us at
    /// `outdatedTimeout = 30s`, so a 15s heartbeat keeps us alive
    /// with margin. Cancelled by `unsubscribeFromOpenNote()`.
    @ObservationIgnored private var presenceHeartbeatTask: Task<Void, Never>?

    /// Canonical y-protocols Awareness outdatedTimeout is 30s; we
    /// re-broadcast at half that so peers always have a fresh stamp
    /// before they'd evict us. Public so tests can pin the contract.
    public static let presenceHeartbeatSeconds: TimeInterval = 15

    public private(set) var isLoading: Bool = false
    public private(set) var lastError: LumiAPIError?

    private let auditPageSize: Int = 50
    private let notesPageSize: Int = 100

    private let client: LumiAPIClient

    public init(client: LumiAPIClient) {
        self.client = client
    }

    /// Pull the vault list from the server. Replaces the current `vaults`
    /// snapshot on success.
    public func refresh() async {
        isLoading = true
        lastError = nil
        do {
            vaults = try await client.listVaults()
        } catch {
            lastError = error
        }
        isLoading = false
    }

    /// Select a vault by id and load its members + roles + invites + audit
    /// entries. Passing `nil` clears the selection and the cached arrays.
    public func selectVault(_ id: UUID?) async {
        guard let id else {
            selectedVaultID = nil
            members = []
            roles = []
            invites = []
            auditEntries = []
            auditHasMore = false
            notes = []
            notesHasMore = false
            openNoteSnapshot = nil
            openNoteError = nil
            openNoteCRDT = nil
            openNoteLiveText = nil
            return
        }
        selectedVaultID = id
        isLoading = true
        lastError = nil
        members = []
        roles = []
        invites = []
        auditEntries = []
        auditHasMore = false
        notes = []
        notesHasMore = false
        openNoteSnapshot = nil
        openNoteError = nil
        openNoteCRDT = nil
        openNoteLiveText = nil
        // Sequential rather than `async let` — Swift 6 typed throws don't
        // propagate through `async let` bindings, and serializing a few short
        // requests is fine for the UI flow.
        do {
            members = try await client.listMembers(vaultID: id)
            roles = try await client.listRoles(vaultID: id)
            // Invite listing requires the `members.invite` capability; audit
            // listing requires `audit.read`. For members without either, the
            // server returns 403. Treat as "nothing visible to me" rather
            // than poisoning lastError.
            do {
                invites = try await client.listInvites(vaultID: id)
            } catch let error where isForbidden(error) {
                invites = []
                _ = error
            }
            do {
                let resp = try await client.listAuditEntries(vaultID: id, limit: auditPageSize, offset: 0)
                auditEntries = resp.entries
                auditHasMore = resp.entries.count >= auditPageSize
            } catch let error where isForbidden(error) {
                auditEntries = []
                auditHasMore = false
                _ = error
            }
            do {
                let resp = try await client.listNotes(vaultID: id, limit: notesPageSize, offset: 0)
                notes = resp.notes
                notesHasMore = resp.notes.count >= notesPageSize
            } catch let error where isForbidden(error) {
                notes = []
                notesHasMore = false
                _ = error
            }
        } catch {
            lastError = error
        }
        isLoading = false
    }

    /// Load the CRDT snapshot for a server note. Sets `openNoteSnapshot` on
    /// success; surfaces failures via `openNoteError`. Idempotent — calling
    /// twice with the same arguments simply re-fetches and re-arms the
    /// clock. Also implicitly acknowledges any pending remote-update
    /// signal — the screen is current again.
    public func loadOpenNote(vaultID: UUID, noteID: String) async {
        openNoteIsLoading = true
        openNoteError = nil
        do {
            let snapshot = try await client.getNoteSnapshot(vaultID: vaultID, noteID: noteID)
            openNoteSnapshot = snapshot
            hasRemoteUpdate = false
            // Phase H slice 2: spin up a fresh CRDT for this note. Its
            // initial state is empty; the WS SyncStep2 reply will seed
            // it with the server's full state (see subscribeToOpenNote).
            // openNoteLiveText stays nil until the first apply lands —
            // the host falls back to snapshot.text for the initial
            // render.
            openNoteCRDT = LumiCRDT()
            openNoteLiveText = nil
        } catch {
            openNoteSnapshot = nil
            openNoteError = error
            openNoteCRDT = nil
            openNoteLiveText = nil
        }
        openNoteIsLoading = false
    }

    /// Replace the cached snapshot in place — used after a successful
    /// `applyDiff` returns the post-merge text + new clock so the next
    /// save anchors against the right CRDT position. Caller is expected
    /// to have updated its own editor baseline already.
    public func setOpenNoteSnapshot(_ snapshot: RemoteNoteSnapshot) {
        openNoteSnapshot = snapshot
    }

    /// Clear the currently-open server note. UI calls this when the user
    /// navigates back to the vault detail view. Also tears down the WS
    /// sync subscription if one is active.
    public func closeOpenNote() {
        unsubscribeFromOpenNote()
        openNoteSnapshot = nil
        openNoteError = nil
        openNoteIsLoading = false
        hasRemoteUpdate = false
        openNoteCRDT = nil
        openNoteLiveText = nil
    }

    /// Mark the pending remote-update signal as observed. Host calls this
    /// after refetching the snapshot (or after deciding the user's dirty
    /// edits will absorb the change on save). Cleared automatically by
    /// `loadOpenNote` too.
    public func acknowledgeRemoteUpdate() {
        hasRemoteUpdate = false
    }

    // MARK: - WS sync subscription (slice 4e)

    /// Open the live-sync WebSocket against the currently-open note.
    /// Idempotent — call after `loadOpenNote` has settled. Pass the
    /// `stateVector` so the server can compute Step2 against our position;
    /// pass empty Data if unknown.
    ///
    /// `attempt` is the 1-based attempt counter. Hosts always pass the
    /// default (1) on a fresh subscribe; the reconnect path passes the
    /// bumped value so emitted `.willReconnect` events carry an honest
    /// attempt number all the way back. Slice 4f.
    ///
    /// The store consumes the resulting event stream on the main actor;
    /// the only host-observable signal is `hasRemoteUpdate`, which flips
    /// to `true` when the server fans out a SyncUpdate from another
    /// client. Hosts decide policy from there (refetch if clean, banner
    /// if dirty).
    public func subscribeToOpenNote(
        vaultID: UUID,
        noteID: String,
        attempt: Int = 1,
        presence: PresenceState? = nil
    ) async {
        unsubscribeFromOpenNote()
        ownPresence = presence
        let baseURL = await client.baseURL
        let token = await client.token
        guard let baseURL, let token, !token.isEmpty else {
            // No session → skip silently. The REST path may still work
            // with a stale token; we just won't have live updates.
            return
        }
        // Phase H slice 2: prefer the local CRDT's state vector over the
        // snapshot's `vector_clock`. The snapshot SV is *the server's*
        // notion of "fully synced", which is only correct if our local
        // doc already mirrors the server. After a fresh open the local
        // CRDT is empty, so an empty SV → server replies with the full
        // state in SyncStep2 → we apply and converge. Falls back to the
        // snapshot's SV when no CRDT is present (e.g. tests bypassing
        // loadOpenNote).
        let stateVector: Data
        if let crdt = openNoteCRDT {
            stateVector = await crdt.stateVector()
        } else {
            stateVector = decodeBase64StateVector(openNoteSnapshot?.vectorClock)
        }
        let sub = NoteSyncClient(
            baseURL: baseURL,
            token: token,
            vaultID: vaultID,
            noteID: noteID,
            attempt: max(1, attempt)
        )
        syncClient = sub
        syncOpenNoteKey = (vaultID, noteID)
        sub.start(stateVector: stateVector)

        syncEventsTask = Task { @MainActor [weak self] in
            for await event in sub.events {
                guard let self else { return }
                switch event {
                case .syncStep2(let payload), .syncUpdate(let payload):
                    // Server sent a diff or another client's update.
                    // Apply to the local CRDT (Phase H slice 2); on
                    // success, publish the new live text so hosts can
                    // merge clean-state edits. Also keep the legacy
                    // `hasRemoteUpdate` flag set so dirty-state hosts
                    // still surface the merge banner.
                    await self.applyLiveUpdate(payload)
                    self.hasRemoteUpdate = true
                case .opened:
                    // Arm the stability window — `decideReconnect` reads
                    // this on the next willReconnect to decide whether
                    // this drop continues the prior backoff curve or
                    // starts a fresh one. Slice 4f.1.
                    self.syncOpenedAt = Date()
                    // Clear the reconnect hint — we're connected again.
                    // Slice 4f.2.
                    self.reconnectStatus = nil
                    // Phase H slice 4: broadcast our own presence so
                    // peers see we're here. The server fans this out
                    // to other subscribers but echoes it back to us
                    // too — the `applyPresenceFrame` filter drops the
                    // self-echo. The heartbeat keeps us alive in
                    // peers' lists past the 30s outdatedTimeout and
                    // makes us visible to peers who joined after
                    // .opened fired.
                    self.broadcastOwnPresence()
                    self.startPresenceHeartbeat()
                case .willReconnect(let nextAttempt, let delaySeconds):
                    // Transient close — schedule a re-subscribe. The
                    // host-layer decision honours stability: if we'd
                    // been connected long enough before the drop, the
                    // curve resets to attempt 1. Capping (8 attempts)
                    // is enforced here, not in NoteSyncClient.
                    let decision = Self.decideReconnect(
                        suggestedAttempt: nextAttempt,
                        suggestedDelay: delaySeconds,
                        openedAt: self.syncOpenedAt,
                        now: Date(),
                        stabilityWindow: Self.reconnectStabilitySeconds
                    )
                    // Consume the stamp so a subsequent willReconnect
                    // (without an intervening `.opened`) inherits the
                    // bumped attempt instead of looping at 1.
                    self.syncOpenedAt = nil
                    // Publish a hint so the UI can render "reconnecting
                    // in Ns…" while the sleep elapses. Cleared on the
                    // next .opened or on unsubscribe. Slice 4f.2.
                    //
                    // Skipped when the host-side cap is about to drop
                    // the attempt entirely — `scheduleReconnect` no-ops
                    // beyond maxReconnectAttempts, and surfacing a hint
                    // that never fires would just confuse the user.
                    if decision.attempt <= Self.maxReconnectAttempts {
                        self.reconnectStatus = ReconnectStatus(
                            attempt: decision.attempt,
                            delaySeconds: decision.delaySeconds,
                            scheduledAt: Date()
                        )
                    } else {
                        self.reconnectStatus = nil
                    }
                    self.scheduleReconnect(
                        vaultID: vaultID,
                        noteID: noteID,
                        attempt: decision.attempt,
                        delaySeconds: decision.delaySeconds
                    )
                case .awareness(let payload):
                    // Phase H slice 4: decode peer presence + update
                    // the room list. Malformed/foreign-format payloads
                    // are silently ignored so a stray frame from a
                    // different presence protocol doesn't disrupt us.
                    self.applyPresenceFrame(payload)
                case .closed:
                    // No host-actionable signal beyond what
                    // .willReconnect already conveyed.
                    continue
                }
            }
        }
    }

    /// Decide the effective (attempt, delay) for a reconnect cycle.
    /// Pure — exposed `internal` for tests; production call site lives
    /// in `subscribeToOpenNote`'s event loop.
    ///
    /// Rule: if the WS had been `.opened` and stayed connected for at
    /// least `stabilityWindow` seconds before the willReconnect arrived,
    /// the connection is treated as healthy-then-blipped and the next
    /// retry starts at attempt = 1 (with the corresponding short delay).
    /// Otherwise we honour `NoteSyncClient`'s suggestion (a continuation
    /// of the prior backoff curve).
    ///
    /// Slice 4f.1.
    static func decideReconnect(
        suggestedAttempt: Int,
        suggestedDelay: Double,
        openedAt: Date?,
        now: Date,
        stabilityWindow: TimeInterval
    ) -> (attempt: Int, delaySeconds: Double) {
        if let openedAt, now.timeIntervalSince(openedAt) >= stabilityWindow {
            return (1, NoteSyncClient.backoffSeconds(attempt: 1))
        }
        return (suggestedAttempt, suggestedDelay)
    }

    /// Apply a WS-delivered Y.Doc update payload to the open-note CRDT
    /// and republish the resulting text. Phase H slice 2.
    ///
    /// Tolerant of failure: a malformed payload from a misbehaving peer
    /// shouldn't tear down the subscription. We log nothing (no logging
    /// surface in LumiKit yet) but leave `openNoteLiveText` unchanged
    /// so the host renders the prior known-good state. The next valid
    /// update will overwrite it.
    ///
    /// Internal because the host never drives this directly — the WS
    /// event loop is the only caller. `package` would be nicer but
    /// LumiKit doesn't ship sub-modules yet; `func`-default visibility
    /// (internal) is fine because LumiKitTests has `@testable import`.
    func applyLiveUpdate(_ payload: Data) async {
        guard let crdt = openNoteCRDT, !payload.isEmpty else { return }
        do {
            try await crdt.apply(update: payload)
            openNoteLiveText = await crdt.text()
        } catch {
            // Apply failed (malformed bytes). Don't tear down the WS
            // subscription — a single bad frame may still be followed
            // by valid ones. Don't touch openNoteLiveText so the host's
            // last known-good render survives.
            _ = error
        }
    }

    /// Encode our own `ownPresence` (if set) and ship it over the WS
    /// awareness channel. Called from the `.opened` handler so the
    /// frame goes out the moment we know peers can hear us. Silent
    /// no-op when no own presence has been registered (e.g. the host
    /// chose REST-only mode or the user hasn't completed auth).
    /// Phase H slice 4.
    private func broadcastOwnPresence() {
        guard let presence = ownPresence, let client = syncClient else { return }
        do {
            let payload = try presence.encoded()
            client.send(awareness: payload)
        } catch {
            // JSON-encoding a Codable struct can't realistically fail
            // for our shape, but if it does the host has no recourse —
            // peers just won't see us. Swallow.
            _ = error
        }
    }

    /// Decode an incoming awareness payload and update the presence
    /// list. Drops our own echo (server fans out to ALL subscribers
    /// including the origin) by matching on `clientID`. Phase H slice 4.
    func applyPresenceFrame(_ payload: Data) {
        guard let peer = try? PresenceState.decoded(from: payload) else { return }
        // Filter our own echo. Different devices for the same user
        // sign in with different clientIDs so both show up as distinct
        // peers — only "this exact session" is filtered.
        if let mine = ownPresence, mine.clientID == peer.clientID { return }
        presenceByClient[peer.clientID] = peer
        openNotePresence = presenceByClient.values.sorted { $0.clientID.uuidString < $1.clientID.uuidString }
    }

    /// Start a recurring heartbeat that re-broadcasts `ownPresence`
    /// every `presenceHeartbeatSeconds`. Idempotent — cancels any
    /// prior task first. No-op when `ownPresence` is nil (listen-only
    /// host). Cancelled by `stopPresenceHeartbeat()` /
    /// `unsubscribeFromOpenNote()`. Phase H follow-up.
    private func startPresenceHeartbeat() {
        stopPresenceHeartbeat()
        guard ownPresence != nil else { return }
        let interval = Self.presenceHeartbeatSeconds
        presenceHeartbeatTask = Task { @MainActor [weak self] in
            let ns = UInt64(interval * 1_000_000_000)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: ns)
                } catch {
                    return
                }
                guard let self else { return }
                // If we've torn down the subscription mid-sleep,
                // ownPresence is nil and broadcastOwnPresence no-ops —
                // safe to keep ticking until the task is cancelled.
                self.broadcastOwnPresence()
            }
        }
    }

    /// Stop the heartbeat task. Idempotent.
    private func stopPresenceHeartbeat() {
        presenceHeartbeatTask?.cancel()
        presenceHeartbeatTask = nil
    }

    /// Reset the presence cache. Called from unsubscribe/close/clear
    /// so a re-open starts with no stale peers visible. Phase H slice 4.
    private func resetPresence() {
        stopPresenceHeartbeat()
        presenceByClient = [:]
        openNotePresence = []
        ownPresence = nil
    }

    /// Tear down the WS sync subscription. Idempotent.
    public func unsubscribeFromOpenNote() {
        syncReconnectTask?.cancel()
        syncReconnectTask = nil
        syncEventsTask?.cancel()
        syncEventsTask = nil
        syncClient?.stop()
        syncClient = nil
        syncOpenNoteKey = nil
        syncOpenedAt = nil
        reconnectStatus = nil
        resetPresence()
    }

    /// Sleep `delaySeconds`, then re-issue `subscribeToOpenNote` with the
    /// bumped attempt count. Caps at `maxReconnectAttempts` — beyond
    /// that we leave the WS quiet and let the host decide whether to
    /// surface a banner or wait for the user to re-open the note. Slice
    /// 4f.
    private func scheduleReconnect(vaultID: UUID, noteID: String,
                                   attempt: Int, delaySeconds: Double) {
        guard attempt <= Self.maxReconnectAttempts else {
            // Exhausted retries — clear the open-note key so a stale
            // entry doesn't leak into a future surprise reconnect.
            syncOpenNoteKey = nil
            return
        }
        syncReconnectTask?.cancel()
        syncReconnectTask = Task { @MainActor [weak self] in
            // Convert to nanoseconds. Negative/zero delay is fine — sleep
            // returns immediately. Cancellation throws, which is caught
            // below as the "stop while waiting" path.
            let ns = UInt64(max(0, delaySeconds) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: ns)
            } catch {
                return
            }
            guard let self else { return }
            // If the user closed the note (or re-opened a different one)
            // while we were sleeping, the key was cleared or replaced —
            // don't double-subscribe.
            guard let key = self.syncOpenNoteKey,
                  key.vaultID == vaultID,
                  key.noteID == noteID else {
                return
            }
            // Phase H slice 4: re-use the same presence on reconnect so
            // peers don't see us disappear+reappear when the network
            // blips. ownPresence is set by the original subscribe and
            // cleared on host-driven unsubscribe — re-passing it here
            // is safe even when it's nil.
            let presence = self.ownPresence
            await self.subscribeToOpenNote(vaultID: vaultID, noteID: noteID, attempt: attempt, presence: presence)
        }
    }

    /// Decode the base64 state vector from a `RemoteNoteSnapshot.vectorClock`
    /// into the raw `Data` we'd send as `SyncStep1`'s body. Returns empty
    /// Data when the clock string is empty or undecodable (server still
    /// replies with a full Step2 in that case).
    private func decodeBase64StateVector(_ clock: String?) -> Data {
        guard let clock, !clock.isEmpty else { return Data() }
        return Data(base64Encoded: clock) ?? Data()
    }

    /// Bump the `updatedAt` of a cached note row to now. Used after a
    /// successful `applyDiff` — the server's response doesn't carry a
    /// full noteDTO (only the snapshot shape), so we synthesize the bump
    /// locally. Path is also accepted in case it ever changes (it
    /// shouldn't for body-only diffs, but the snapshot includes it for
    /// completeness). No-op when no row matches.
    public func bumpNoteUpdatedAt(noteID: String, path: String) {
        guard let idx = notes.firstIndex(where: { $0.id == noteID }) else { return }
        let existing = notes[idx]
        notes[idx] = RemoteNote(
            id: existing.id,
            vaultID: existing.vaultID,
            path: path,
            title: existing.title,
            createdAt: existing.createdAt,
            updatedAt: Date()
        )
    }

    /// Merge an updated note row (e.g. the response of a successful PATCH)
    /// into the cached `notes` list. Replaces the existing row by id if
    /// present; no-op otherwise (the row may have been paginated off).
    /// Used by the editor flow after `LumiAPIClient.updateNote` returns so
    /// the list reflects the new `updated_at` / title without a full refetch.
    public func updateNoteRowFromPATCH(_ updated: RemoteNote) {
        if let idx = notes.firstIndex(where: { $0.id == updated.id }) {
            notes[idx] = updated
        }
    }

    /// Create a new note in the currently-selected vault and prepend it to
    /// the cached `notes` list. Returns the new row on success so the host
    /// can navigate to it (e.g. auto-open in edit mode).
    @discardableResult
    public func createNote(title: String, body: String = "", tags: [String] = []) async throws(LumiAPIError) -> RemoteNote {
        guard let id = selectedVaultID else {
            throw LumiAPIError.network(message: "no vault selected")
        }
        let created = try await client.createNote(
            vaultID: id,
            title: title,
            body: body,
            tags: tags
        )
        if !notes.contains(where: { $0.id == created.id }) {
            notes.insert(created, at: 0)
        }
        return created
    }

    /// Delete a note in the currently-selected vault and drop it from the
    /// cache. If the deleted note was the currently-open one, clear the
    /// open-note state too so the caller's UI doesn't get stranded.
    public func deleteNote(noteID: String) async throws(LumiAPIError) {
        guard let vaultID = selectedVaultID else {
            throw LumiAPIError.network(message: "no vault selected")
        }
        try await client.deleteNote(vaultID: vaultID, noteID: noteID)
        notes.removeAll { $0.id == noteID }
        if openNoteSnapshot?.id == noteID {
            unsubscribeFromOpenNote()
            openNoteSnapshot = nil
            openNoteError = nil
            openNoteIsLoading = false
            hasRemoteUpdate = false
            openNoteCRDT = nil
            openNoteLiveText = nil
        }
    }

    /// Append the next page of notes. Caller-driven via a "Load more" button
    /// on long vaults.
    public func loadMoreNotes() async {
        guard let id = selectedVaultID, notesHasMore else { return }
        do {
            let resp = try await client.listNotes(
                vaultID: id,
                limit: notesPageSize,
                offset: notes.count
            )
            notes.append(contentsOf: resp.notes)
            notesHasMore = resp.notes.count >= notesPageSize
        } catch let error where isForbidden(error) {
            notesHasMore = false
        } catch {
            lastError = error
            notesHasMore = false
        }
    }

    /// Append the next page of audit entries. Caller-driven — typically a
    /// "Load more" button hooked up to this method.
    public func loadMoreAudit() async {
        guard let id = selectedVaultID, auditHasMore else { return }
        do {
            let resp = try await client.listAuditEntries(
                vaultID: id,
                limit: auditPageSize,
                offset: auditEntries.count
            )
            auditEntries.append(contentsOf: resp.entries)
            auditHasMore = resp.entries.count >= auditPageSize
        } catch let error where isForbidden(error) {
            auditHasMore = false
        } catch {
            lastError = error
            auditHasMore = false
        }
    }

    /// Refresh just the invites list for the selected vault. Used after
    /// creating or revoking an invite to keep the displayed list current.
    public func refreshInvites() async {
        guard let id = selectedVaultID else { return }
        do {
            invites = try await client.listInvites(vaultID: id)
        } catch let error where isForbidden(error) {
            invites = []
        } catch {
            lastError = error
        }
    }

    /// Create an invite for the selected vault and prepend it to `invites`.
    /// Returns the full response (with the optional shareable `url`) so the
    /// UI can show / copy the link immediately.
    @discardableResult
    public func createInvite(
        roleID: UUID,
        maxUses: Int,
        expiresAt: Date,
        emailHint: String?
    ) async throws(LumiAPIError) -> CreatedInvite {
        guard let id = selectedVaultID else {
            throw LumiAPIError.network(message: "no vault selected")
        }
        let created = try await client.createInvite(
            vaultID: id,
            roleID: roleID,
            maxUses: maxUses,
            expiresAt: expiresAt,
            emailHint: emailHint
        )
        // Refresh the canonical list so newly-created rows include
        // server-assigned timestamps (created_at, vault_id, inviter_user_id).
        await refreshInvites()
        return created
    }

    /// Revoke an invite by token. Drops it from the local cache immediately
    /// on success so the UI updates without waiting for a list refresh.
    public func revokeInvite(token: String) async throws(LumiAPIError) {
        guard let id = selectedVaultID else {
            throw LumiAPIError.network(message: "no vault selected")
        }
        try await client.revokeInvite(vaultID: id, token: token)
        await refreshInvites()
    }

    /// Create a new vault server-side and prepend it to the local cache.
    /// Caller becomes Admin. Returns the created vault so the UI can select
    /// it without waiting for a full list refresh.
    @discardableResult
    public func createVault(name: String, slug: String? = nil) async throws(LumiAPIError) -> RemoteVault {
        let vault = try await client.createVault(name: name, slug: slug)
        // Server returns the canonical row; insert at the top so newest is
        // most visible. Avoid dupes if a refresh happens concurrently.
        if !vaults.contains(where: { $0.id == vault.id }) {
            vaults.insert(vault, at: 0)
        }
        return vault
    }

    /// Rename the given vault. Updates the cached row and (if it's the
    /// currently selected vault) keeps `selectedVaultID` intact.
    @discardableResult
    public func renameVault(vaultID: UUID, name: String) async throws(LumiAPIError) -> RemoteVault {
        let updated = try await client.renameVault(vaultID: vaultID, name: name)
        if let idx = vaults.firstIndex(where: { $0.id == vaultID }) {
            vaults[idx] = updated
        }
        return updated
    }

    /// Delete the given vault server-side. Drops it from the cache; clears
    /// the active selection if it was that vault.
    public func deleteVault(vaultID: UUID) async throws(LumiAPIError) {
        try await client.deleteVault(vaultID: vaultID)
        vaults.removeAll { $0.id == vaultID }
        if selectedVaultID == vaultID {
            selectedVaultID = nil
            members = []
            roles = []
            invites = []
            auditEntries = []
            auditHasMore = false
            notes = []
            notesHasMore = false
            openNoteSnapshot = nil
            openNoteCRDT = nil
            openNoteLiveText = nil
        }
    }

    /// Wipe all state. Call on sign-out so the next sign-in starts clean.
    public func clear() {
        unsubscribeFromOpenNote()
        vaults = []
        selectedVaultID = nil
        members = []
        roles = []
        invites = []
        auditEntries = []
        auditHasMore = false
        notes = []
        notesHasMore = false
        openNoteSnapshot = nil
        openNoteError = nil
        openNoteIsLoading = false
        hasRemoteUpdate = false
        openNoteCRDT = nil
        openNoteLiveText = nil
        lastError = nil
        isLoading = false
    }
}

private func isForbidden(_ error: LumiAPIError) -> Bool {
    if case let .server(status, _, _) = error, status == 403 { return true }
    return false
}
