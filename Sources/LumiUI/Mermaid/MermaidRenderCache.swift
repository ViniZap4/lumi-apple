import CoreGraphics
import Foundation

/// What a render is keyed by: the exact source, the theme fingerprint
/// (any token change re-renders) and the backing scale (Retina vs 1x vs
/// the zoom sheet's high-resolution pass).
public struct MermaidRenderKey: Hashable, Sendable {
    public let source: String
    public let themeFingerprint: String
    public let scale: CGFloat

    public init(source: String, themeFingerprint: String, scale: CGFloat) {
        self.source = source
        self.themeFingerprint = themeFingerprint
        // Quantise so 2.0 and 2.0000001 share an entry.
        self.scale = (scale * 4).rounded() / 4
    }
}

/// Immutable bitmap wrapper. `CGImage` is immutable and thread-safe;
/// the box only exists to carry it across actors under Swift 6.
public final class MermaidBitmap: @unchecked Sendable {
    public let cgImage: CGImage
    public init(_ cgImage: CGImage) { self.cgImage = cgImage }
    var byteCost: Int { cgImage.bytesPerRow * cgImage.height }
}

/// A finished diagram: sanitised SVG (for export), the rasterised
/// bitmap (for display), and its size in points.
public struct MermaidDiagram: Sendable {
    public let svg: String
    public let bitmap: MermaidBitmap
    public let size: CGSize
    public let scale: CGFloat

    public init(svg: String, bitmap: MermaidBitmap, size: CGSize, scale: CGFloat) {
        self.svg = svg
        self.bitmap = bitmap
        self.size = size
        self.scale = scale
    }
}

public enum MermaidRenderError: Error, Sendable, Equatable {
    /// Mermaid rejected the source; the message is mermaid's own
    /// ("Parse error on line 3: …").
    case syntax(String)
    case tooLarge(length: Int)
    case timedOut
    /// Bundle asset missing / web content process died.
    case unavailable(String)

    public var title: String {
        switch self {
        case .syntax: return "This diagram has a syntax error"
        case .tooLarge: return "This diagram is too large to render"
        case .timedOut: return "This diagram took too long to render"
        case .unavailable: return "Diagrams are unavailable right now"
        }
    }

    /// 1-based source line a syntax error points at ("… on line 3"),
    /// so the error card can highlight it.
    public var blamedLine: Int? {
        guard case let .syntax(message) = self,
              let range = message.range(of: #"line (\d+)"#, options: .regularExpression)
        else { return nil }
        return Int(message[range].dropFirst(5))
    }

    public var detail: String {
        switch self {
        case let .syntax(m): return m
        case let .tooLarge(n):
            return "\(n) characters — the limit is \(MermaidSource.maxSourceLength)."
        case .timedOut: return "Try splitting it into smaller diagrams."
        case let .unavailable(m): return m
        }
    }
}

public typealias MermaidRenderResult = Result<MermaidDiagram, MermaidRenderError>

/// Bounded LRU over render results. Successes are costed by bitmap
/// bytes, failures by a nominal amount (they are cached too, so a broken
/// diagram doesn't re-run mermaid every time its view remounts).
/// Not thread-safe by itself; owned by the `@MainActor` renderer.
struct MermaidRenderCache {
    let maxEntries: Int
    let maxBytes: Int
    private var entries: [MermaidRenderKey: MermaidRenderResult] = [:]
    private var order: [MermaidRenderKey] = []
    private(set) var totalBytes = 0

    init(maxEntries: Int = 128, maxBytes: Int = 96 << 20) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
    }

    var count: Int { entries.count }

    mutating func value(for key: MermaidRenderKey) -> MermaidRenderResult? {
        guard let hit = entries[key] else { return nil }
        touch(key)
        return hit
    }

    /// Lookup without touching recency (for `peek`-style checks).
    func contains(_ key: MermaidRenderKey) -> Bool { entries[key] != nil }

    mutating func insert(_ result: MermaidRenderResult, for key: MermaidRenderKey) {
        if let old = entries[key] { totalBytes -= Self.cost(old) }
        entries[key] = result
        totalBytes += Self.cost(result)
        touch(key)
        while (order.count > maxEntries || totalBytes > maxBytes), order.count > 1 {
            let victim = order.removeFirst()
            if let gone = entries.removeValue(forKey: victim) { totalBytes -= Self.cost(gone) }
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalBytes = 0
    }

    private mutating func touch(_ key: MermaidRenderKey) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }

    static func cost(_ result: MermaidRenderResult) -> Int {
        switch result {
        case let .success(d): return d.bitmap.byteCost + d.svg.utf8.count
        case .failure: return 1024
        }
    }
}
