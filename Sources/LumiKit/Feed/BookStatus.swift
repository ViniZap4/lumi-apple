import Foundation

/// The seven per-book sync states (SPEC-LIVROS §4.1), in precedence order.
public enum BookSyncStatus: Sendable, Equatable {
    case local
    case needsSignIn(reason: String)
    case error(reason: String)
    case offline
    case syncing
    case readOnly
    case upToDate

    /// Stable identifier shared with the TUI/web test tables.
    public var code: String {
        switch self {
        case .local: return "local"
        case .needsSignIn: return "needs_sign_in"
        case .error: return "error"
        case .offline: return "offline"
        case .syncing: return "syncing"
        case .readOnly: return "read_only"
        case .upToDate: return "up_to_date"
        }
    }

    public var label: String {
        switch self {
        case .local: return "local"
        case .needsSignIn: return "sign in"
        case .error: return "error"
        case .offline: return "offline"
        case .syncing: return "syncing"
        case .readOnly: return "read-only"
        case .upToDate: return "up to date"
        }
    }
}

/// Book-level facts the status needs.
public struct BookStatusBook: Sendable, Equatable {
    public var kind: Book.Kind
    /// An account for `(server_url, account)` exists on this client.
    public var hasAccount: Bool
    public var hasToken: Bool
    public var hasVaultID: Bool
    /// `vault.revoked` received / missing from `hello` or the listing.
    public var revoked: Bool
    public var canEdit: Bool

    public init(kind: Book.Kind, hasAccount: Bool = true, hasToken: Bool = true, hasVaultID: Bool = true,
                revoked: Bool = false, canEdit: Bool = true) {
        self.kind = kind
        self.hasAccount = hasAccount
        self.hasToken = hasToken
        self.hasVaultID = hasVaultID
        self.revoked = revoked
        self.canEdit = canEdit
    }
}

/// `catchUp` input: `idle`, `running` or `failed(n, reason)` plus cursor/head.
public struct CatchUpSnapshot: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case running
        case failed(count: Int, reason: String)
    }

    public var phase: Phase
    public var cursor: Int64
    /// nil when unknown (feed disabled and no `head` in the listing).
    public var head: Int64?

    public init(phase: Phase = .idle, cursor: Int64 = 0, head: Int64? = nil) {
        self.phase = phase
        self.cursor = cursor
        self.head = head
    }
}

/// CRDT editor session phase (CRDT-CLIENT-PROTOCOL §2.1) for the open note
/// of this book, plus "pending" = local edits not yet confirmed.
public struct EditorSnapshot: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case closed, connecting, syncing, live, offline
    }

    public var phase: Phase
    public var pending: Bool

    public init(phase: Phase = .closed, pending: Bool = false) {
        self.phase = phase
        self.pending = pending
    }
}

/// Failures before a non-transient error becomes the "Erro" state.
public let bookStatusErrorThreshold = 3

/// Pure state function (SPEC-LIVROS §4.2). Precedence, first match wins:
/// Não ligado → Precisa entrar → Erro → Offline → Sincronizando →
/// Somente leitura → Atualizado.
///
/// `feed == .disabled` (server without `/api/events`) is not "Offline":
/// the book degrades to REST-only and is judged by REST health, catch-up
/// and the editor.
public func bookStatus(
    book: BookStatusBook,
    accountFeed: AccountFeedState?,
    catchUp: CatchUpSnapshot,
    editor: EditorSnapshot,
    restHealth: RestHealth?
) -> BookSyncStatus {
    if book.kind == .local { return .local }

    if !book.hasAccount { return .needsSignIn(reason: "no account for this server on this device") }
    if !book.hasToken { return .needsSignIn(reason: "not signed in") }
    if accountFeed == .authDead { return .needsSignIn(reason: "session ended") }
    if restHealth == .unauthorized { return .needsSignIn(reason: "session rejected (401)") }

    if !book.hasVaultID { return .error(reason: "incomplete link (no vault id)") }
    if book.revoked { return .error(reason: "you no longer have access to this book") }
    if case let .failed(count, reason) = catchUp.phase, count >= bookStatusErrorThreshold {
        return .error(reason: reason)
    }
    if case let .failing(count, reason) = restHealth, count >= bookStatusErrorThreshold {
        return .error(reason: reason)
    }

    if case .network = restHealth { return .offline }
    switch accountFeed {
    case .open, .disabled: break
    case .none, .connecting, .backoff, .authDead: return .offline
    }

    let behind = catchUp.head.map { $0 > catchUp.cursor } ?? false
    let editorBusy = editor.phase == .connecting || editor.phase == .syncing || editor.phase == .offline
    if catchUp.phase == .running || behind || editorBusy || editor.pending { return .syncing }

    if !book.canEdit { return .readOnly }
    return .upToDate
}
