import Foundation
import LumiKit

/// Sign out / remove account with offline edits still pending.
struct AccountActionPrompt: Identifiable, Equatable {
    enum Kind: Equatable { case signOut, remove }
    let id = UUID()
    let kind: Kind
    let key: AccountKey
    /// Notes with unsent offline edits (+ recovered texts) on the account.
    let pending: Int
}

/// Offline texts that can no longer be synced: export or discard.
struct RecoveryPrompt: Identifiable, Equatable {
    let id = UUID()
    var notes: [RecoveredNote]
    var message: String
}

/// Offline editing of server books: replica lifecycle (LGPD wipes),
/// pending counts and the "needs a connection" guard for explorer
/// actions. Storage lives in `ReplicaStore`; sessions in
/// `RemoteVaultsStore`.
extension AppState {
    private var replicas: ReplicaStore? { remoteVaultsStore.replicaStore }

    /// The open server book cannot reach its server (listing from cache,
    /// or the book status says Offline).
    var isRemoteOffline: Bool {
        guard let book = openBook, book.kind == .bound else { return false }
        if remoteVaultsStore.isOffline { return true }
        return sync.status(for: book) == .offline
    }

    /// Creating, renaming, deleting and duplicating server notes need the
    /// server (metadata is not replicated). Returns false and explains.
    func requireOnline(_ action: String) -> Bool {
        guard !explorer.isLocal, isRemoteOffline else { return true }
        showToast("offline — \(action) needs a connection; open notes stay editable", tone: .warning)
        return false
    }

    /// Recompute `sync.pendingReplicas` from disk plus the open session.
    func refreshPendingReplicas() {
        guard let replicas else { return }
        var byBook: [String: Set<String>] = [:]
        for s in replicas.pending() {
            guard let book = books.book(vaultID: s.key.vaultID.uuidString.lowercased()),
                  book.accountKey == s.key.account else { continue }
            byBook[book.id, default: []].insert(s.key.noteID)
        }
        if let session = remoteVaultsStore.openSession, !session.isDestroyed, let book = openBook {
            if session.hasPendingLocalChanges {
                byBook[book.id, default: []].insert(session.noteID)
            } else {
                byBook[book.id]?.remove(session.noteID)
            }
        }
        let counts = byBook.mapValues(\.count).filter { $0.value > 0 }
        if counts != sync.pendingReplicas { sync.pendingReplicas = counts }
    }

    /// Pending notes of the open book (status line).
    var openBookPendingCount: Int {
        openBook.flatMap { sync.pendingReplicas[$0.id] } ?? 0
    }

    // MARK: LGPD wipes

    func wireOfflineHooks() {
        sync.onAccessRevoked = { [weak self] book in
            guard let self, let key = book.accountKey, let vault = book.vaultUUID else { return }
            self.purgeOffline(account: key, vaultID: vault, reason: .accessRevoked,
                              why: "Access to \(book.name) ended.")
        }
        sync.onSessionEnded = { [weak self] key in
            self?.purgeOffline(account: key, vaultID: nil, reason: .sessionEnded,
                               why: "The session of \(key.description) ended.")
        }
    }

    /// Delete replicas + listing caches; pending texts become export-only
    /// records and the user is asked to export or discard them.
    func purgeOffline(account: AccountKey, vaultID: UUID?, reason: RecoveredNote.Reason, why: String) {
        remoteVaultsStore.purgeReplicas(account: account, vaultID: vaultID, reason: reason)
        refreshPendingReplicas()
        let stranded = (replicas?.recovered(account: account) ?? []).filter {
            !$0.uploadable && (vaultID == nil || $0.vaultID == vaultID)
        }
        guard !stranded.isEmpty else { return }
        recoveryPrompt = RecoveryPrompt(
            notes: stranded,
            message: "\(why) \(stranded.count) note\(stranded.count == 1 ? " had" : "s had") offline edits that were never sent.")
    }

    /// Palette: every recovered text not uploaded yet.
    func showRecoveredNotes() {
        let all = replicas?.recovered() ?? []
        guard !all.isEmpty else {
            showToast("no offline copies waiting")
            return
        }
        recoveryPrompt = RecoveryPrompt(notes: all, message: "\(all.count) offline cop\(all.count == 1 ? "y" : "ies") could not be synced.")
    }

    /// Write recovered texts as `.md` files under Documents/lumi recovered
    /// and drop the records. Returns the folder.
    @discardableResult
    func exportRecovered(_ notes: [RecoveredNote]) -> URL? {
        guard !notes.isEmpty else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let dir = docs.appendingPathComponent("lumi recovered", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        do {
            let urls = try ReplicaStore.export(notes, to: dir)
            remoteVaultsStore.deleteRecovered(notes.map(\.id))
            showToast("exported \(urls.count) note\(urls.count == 1 ? "" : "s") to \(dir.path)", tone: .success)
            return dir
        } catch {
            showToast("export failed: \(error.localizedDescription)", tone: .error)
            return nil
        }
    }

    func discardRecovered(_ notes: [RecoveredNote]) {
        remoteVaultsStore.deleteRecovered(notes.map(\.id))
    }

    // MARK: Sign out / remove account

    private func pendingCount(_ key: AccountKey) -> Int {
        guard let replicas else { return 0 }
        var notes = Set(replicas.pending(account: key).map(\.key))
        if let s = remoteVaultsStore.openSession, s.hasPendingLocalChanges, remoteVaultsStore.replicaAccount == key {
            notes.insert(ReplicaKey(account: key, vaultID: s.vaultID, noteID: s.noteID))
        }
        return notes.count + replicas.recovered(account: key).count
    }

    func requestSignOut(_ key: AccountKey) {
        let n = pendingCount(key)
        if n > 0 {
            accountActionPrompt = AccountActionPrompt(kind: .signOut, key: key, pending: n)
        } else {
            Task { await performSignOut(key) }
        }
    }

    func requestRemoveAccount(_ key: AccountKey) {
        let n = pendingCount(key)
        if n > 0 {
            accountActionPrompt = AccountActionPrompt(kind: .remove, key: key, pending: n)
        } else {
            Task { await performRemoveAccount(key, export: false) }
        }
    }

    /// Sign-out keeps the replicas: they sync after signing in again as
    /// the same account.
    func performSignOut(_ key: AccountKey) async {
        if remoteVaultsStore.replicaAccount == key { remoteVaultsStore.destroyOpenSession() }
        await accounts.signOut(key)
        await accountsChanged()
    }

    /// Account removal wipes everything of the account on this device
    /// (LGPD); `export` first writes pending texts to Documents.
    func performRemoveAccount(_ key: AccountKey, export: Bool) async {
        remoteVaultsStore.purgeReplicas(account: key, reason: .accountRemoved)
        let recovered = replicas?.recovered(account: key) ?? []
        if export {
            exportRecovered(recovered)
        } else {
            discardRecovered(recovered)
        }
        refreshPendingReplicas()
        await accounts.remove(key)
        await accountsChanged()
    }
}
