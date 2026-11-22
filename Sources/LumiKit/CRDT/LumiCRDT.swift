import Foundation

#if canImport(YSwift)
@preconcurrency import YSwift

/// Actor wrapper around a single Yjs document for the Apple client's
/// open note. Owns one `YText` keyed by `textName` (default "body") —
/// matching the server's `domain.NoteCRDT` shape so updates round-trip
/// untranslated.
///
/// Phase H slice 1 lays down the binding only: callers can apply
/// server-sent updates, encode their own state, and read the current
/// text. Slice H.2 will plumb WS `.syncUpdate` events into `apply`,
/// and H.3 will switch the commit path from POSTing a full body to
/// POSTing a raw Yjs update (computed via `encodeDiff`).
///
/// Why an `actor`: `YDocument` already serialises every transaction
/// onto its own `DispatchQueue` *and* fails a `dispatchPrecondition`
/// if a transaction is opened from within another. Putting our
/// outer-edge calls on an actor means Swift 6's strict-concurrency
/// checker sees a single isolation domain instead of a free-floating
/// reference, and `@preconcurrency import YSwift` confines the
/// non-Sendable surface (YDocument / YrsTransaction) to this file.
public actor LumiCRDT {
    /// The underlying YSwift document. Held as a private property so
    /// no caller can reach the inner DispatchQueue directly — every
    /// operation goes through the actor's async API.
    private let doc: YDocument
    /// The shared `YText` we manage. Cached at init time because
    /// calling `doc.getOrCreateText(named:)` inside a `transactSync`
    /// closure opens an inner transaction → yrs panics with
    /// `ExclusiveAcqFailed(BorrowMutError)`. Match yswift's own
    /// tests: grab the YText outside, use it inside.
    private let ytext: YText
    /// Name of the shared `YText` we manage. Matches the server's
    /// canonical key so wire updates land in the same shared type on
    /// both sides.
    public let textName: String

    /// Build a fresh, empty Y.Doc with one named text channel.
    /// Pass `seed` to install an initial body; the seeded text counts
    /// as a CRDT insertion at the current actor's clock origin (so a
    /// subsequent diff against a remote peer's state vector will
    /// include it).
    public init(textName: String = "body", seed: String = "") {
        let doc = YDocument()
        let ytext = doc.getOrCreateText(named: textName)
        if !seed.isEmpty {
            doc.transactSync { txn in
                ytext.insert(seed, at: 0, in: txn)
            }
        }
        self.doc = doc
        self.ytext = ytext
        self.textName = textName
    }

    // MARK: - Wire-facing

    /// Apply a raw Yjs update (lib0-v1 encoded bytes). The update may
    /// originate from a `POST .../diff` response, a WS `SyncUpdate`
    /// frame, or any other peer; the CRDT merges it idempotently. A
    /// malformed payload throws; well-formed updates that the doc
    /// already has the changes for are a no-op.
    public func apply(update: Data) throws {
        let doc = self.doc
        // YSwift's transactSync closure is non-throwing — capture any
        // error via a Result and rethrow after the queue hop.
        let result: Result<Void, Error> = doc.transactSync { txn in
            do {
                try txn.transactionApplyUpdate(update: Array(update))
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    /// Compute the current state vector. Sent to a peer in
    /// `SyncStep1` so the peer can compute a minimal diff to send
    /// back. lib0-v1 encoded.
    public func stateVector() -> Data {
        let doc = self.doc
        return doc.transactSync { txn in
            Data(txn.transactionStateVector())
        }
    }

    /// Encode the document's full state as a single update. Suitable
    /// for `SyncStep2` reply to a peer whose state vector is empty
    /// (i.e. brand-new doc on the other end). lib0-v1 encoded.
    public func encodeStateAsUpdate() -> Data {
        let doc = self.doc
        return doc.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
    }

    /// Compute a diff update against `remoteStateVector`. Suitable
    /// for `SyncStep2` reply when the remote announced their state
    /// vector in `SyncStep1`. Empty `remoteStateVector` behaves like
    /// `encodeStateAsUpdate()` — yrs's `encodeDiffV1` rejects an
    /// empty byte buffer (it expects a valid lib0-v1 state vector,
    /// not "nothing"), so we route the empty case to the full-state
    /// encoder. lib0-v1 encoded.
    public func encodeDiff(againstStateVector remote: Data) throws -> Data {
        if remote.isEmpty {
            return encodeStateAsUpdate()
        }
        let doc = self.doc
        let result: Result<Data, Error> = doc.transactSync { txn in
            do {
                let bytes = try txn.transactionEncodeStateAsUpdateFromSv(stateVector: Array(remote))
                return .success(Data(bytes))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    // MARK: - Text content

    /// Current contents of the managed `YText`. Returns the empty
    /// string when nothing has been inserted yet.
    public func text() -> String {
        let doc = self.doc
        let ytext = self.ytext
        return doc.transactSync { txn in
            ytext.getString(in: txn)
        }
    }

    /// Make the managed text equal `newText` with the smallest single
    /// contiguous edit: the common prefix and suffix are kept, and only
    /// the differing middle is removed and re-inserted (one `removeRange`
    /// plus one `insert`, in a single transaction so observers see one
    /// change event). Unchanged text produces no ops at all.
    ///
    /// Previously this deleted and re-inserted the whole body, which
    /// tombstoned the entire document on every save and turned any
    /// concurrent edit from another peer into a duplicate/clobber on
    /// merge. A ranged edit keeps untouched regions' CRDT identity, so
    /// concurrent edits in other regions merge cleanly. It is still a
    /// coarse diff — one changed range per call — which the upcoming
    /// sync-layer rewrite will replace with per-keystroke ops.
    public func setText(_ newText: String) {
        let doc = self.doc
        let ytext = self.ytext
        doc.transactSync { txn in
            let current = ytext.getString(in: txn)
            guard let edit = LumiCRDT.rangedEdit(from: current, to: newText) else { return }
            if edit.deleteLength > 0 {
                ytext.removeRange(start: UInt32(edit.start), length: UInt32(edit.deleteLength), in: txn)
            }
            if !edit.insert.isEmpty {
                ytext.insert(edit.insert, at: UInt32(edit.start), in: txn)
            }
        }
    }
}

extension LumiCRDT {
    /// `true` on platforms where the yrs binding is linked.
    public static let isSupported = true

    /// Factory used by callers that must degrade gracefully on platforms
    /// without the binding (visionOS). Always non-nil here.
    public static func makeIfSupported(textName: String = "body") -> LumiCRDT? {
        LumiCRDT(textName: textName)
    }
}

#else

/// Stub for platforms where yswift has no binary slice (visionOS). It can
/// never be instantiated — `makeIfSupported()` returns nil — so every
/// `LumiCRDT?` in the app stays nil and the save path falls back to the
/// text-diff endpoint (`applyNoteDiff`), and live sync uses the
/// snapshot's state vector. The API surface mirrors the real actor so
/// call sites compile unchanged.
public actor LumiCRDT {
    public static let isSupported = false

    public static func makeIfSupported(textName: String = "body") -> LumiCRDT? { nil }

    public let textName: String

    private init(textName: String) { self.textName = textName }

    private static func unreachable() -> Never {
        preconditionFailure("LumiCRDT is unavailable on this platform")
    }

    public func apply(update: Data) throws { Self.unreachable() }
    public func stateVector() -> Data { Self.unreachable() }
    public func encodeStateAsUpdate() -> Data { Self.unreachable() }
    public func encodeDiff(againstStateVector remote: Data) throws -> Data { Self.unreachable() }
    public func text() -> String { Self.unreachable() }
    public func setText(_ newText: String) { Self.unreachable() }
}

#endif

// MARK: - Ranged diff (platform-neutral, pure)

extension LumiCRDT {
    /// A single contiguous replacement, in UTF-16 code units — the
    /// offset kind YSwift configures its documents with
    /// (`OffsetKind::Utf16`), matching Yjs/JS string indexing.
    struct RangedEdit: Equatable, Sendable {
        /// UTF-16 offset where the edit starts.
        var start: Int
        /// UTF-16 code units to remove at `start`.
        var deleteLength: Int
        /// Text inserted at `start` after the removal.
        var insert: String
    }

    /// Smallest single edit turning `old` into `new`: strip the common
    /// prefix, then the common suffix (never overlapping the prefix), and
    /// replace what's left. Comparison is by exact Unicode scalar — not
    /// `Character`, whose `==` uses canonical equivalence and would treat
    /// "é" and "e\u{301}" as equal even though their UTF-16 lengths
    /// differ — so the range never splits a surrogate pair and the result
    /// reproduces `new` exactly. Offsets are converted to UTF-16. Returns
    /// nil when the strings are identical.
    static func rangedEdit(from old: String, to new: String) -> RangedEdit? {
        let a = Array(old.unicodeScalars)
        let b = Array(new.unicodeScalars)
        if a == b { return nil }
        var prefix = 0
        let maxPrefix = min(a.count, b.count)
        while prefix < maxPrefix, a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        let maxSuffix = min(a.count, b.count) - prefix
        while suffix < maxSuffix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let start = a[0..<prefix].reduce(0) { $0 + $1.utf16.count }
        let deleteLength = a[prefix..<(a.count - suffix)].reduce(0) { $0 + $1.utf16.count }
        var insert = String.UnicodeScalarView()
        insert.append(contentsOf: b[prefix..<(b.count - suffix)])
        return RangedEdit(start: start, deleteLength: deleteLength, insert: String(insert))
    }
}
