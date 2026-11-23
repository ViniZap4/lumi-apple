import Foundation

#if canImport(YSwift)
extension LumiCRDT {
    /// Text of a stored replica (state + log updates), for recovery
    /// copies. nil when the updates do not decode.
    public static func materializeText(_ updates: [Data]) -> String? {
        let doc = LumiCRDT()
        do {
            for u in updates { try doc.applyRemote(update: u) }
        } catch {
            return nil
        }
        return doc.text
    }
}
#endif

/// Turns stored updates into text where a CRDT is available (macOS/iOS);
/// nil elsewhere (visionOS never persists replicas).
public enum ReplicaText {
    public static func materialize(_ updates: [Data]) -> String? {
        #if canImport(YSwift)
        return LumiCRDT.materializeText(updates)
        #else
        return nil
        #endif
    }
}
