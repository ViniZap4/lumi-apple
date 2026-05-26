import Foundation
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

    /// Replace the entire body. Used for "seed editor from a server
    /// snapshot" flows where the prior CRDT history isn't preserved
    /// — H.2 will replace this with a `apply(update:)` of the
    /// server's encoded state so concurrent edits don't get wiped.
    /// Kept here so H.1 callers can still drive the editor through
    /// the actor.
    ///
    /// Removes the current text and inserts `newText` at offset 0.
    /// Both ops happen in a single transaction so observers see
    /// exactly one change event.
    public func setText(_ newText: String) {
        let doc = self.doc
        let ytext = self.ytext
        doc.transactSync { txn in
            let currentLen = ytext.length(in: txn)
            if currentLen > 0 {
                ytext.removeRange(start: 0, length: currentLen, in: txn)
            }
            if !newText.isEmpty {
                ytext.insert(newText, at: 0, in: txn)
            }
        }
    }
}
