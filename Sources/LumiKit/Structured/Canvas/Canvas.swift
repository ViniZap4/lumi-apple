import Foundation
import CoreGraphics

// JSON Canvas 1.0 (jsoncanvas.org): types, tolerant parser, validator,
// style-preserving serializer and pure edit ops (SPEC-PARTE2 §6).
// Port of web-client `lib/canvas/canvas.ts`.
//
// Persistence model: the canvas file is a Y.Text holding the JSON. A
// change = parse the CURRENT text → apply an op → serialize in the
// file's own style (Obsidian's one-object-per-line with tabs, or pretty
// JSON with its indent) → minimal prefix/suffix diff → one ranged edit
// (`Canvas.commit`). Unknown keys on nodes, edges and the top level are
// kept, in their original order.

public enum CanvasSide: String, Sendable, CaseIterable { case top, right, bottom, left }
public enum CanvasNodeType: String, Sendable { case text, file, link, group }

/// A renderable node (defaults filled). `raw` is the validated object
/// (unknown keys included).
public struct CanvasNode: Sendable, Equatable, Identifiable {
    public var id: String
    public var type: CanvasNodeType
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var raw: JSONObject

    public var color: String? { raw["color"]?.stringValue }
    public var text: String { raw["text"]?.stringValue ?? "" }
    public var file: String { raw["file"]?.stringValue ?? "" }
    public var subpath: String? { raw["subpath"]?.stringValue }
    public var url: String { raw["url"]?.stringValue ?? "" }
    public var label: String? { raw["label"]?.stringValue }

    public var rect: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.minX; y = newValue.minY; width = newValue.width; height = newValue.height }
    }
}

public struct CanvasEdge: Sendable, Equatable, Identifiable {
    public var id: String
    public var fromNode: String
    public var toNode: String
    public var fromSide: CanvasSide?
    public var toSide: CanvasSide?
    public var raw: JSONObject

    public var fromEnd: String? { raw["fromEnd"]?.stringValue }
    /// Default: an arrow at the target end (JSON Canvas spec).
    public var toEnd: String? { raw["toEnd"]?.stringValue }
    public var color: String? { raw["color"]?.stringValue }
    public var label: String? { raw["label"]?.stringValue }
    public var arrowAtEnd: Bool { toEnd != "none" }
    public var arrowAtStart: Bool { fromEnd == "arrow" }
}

/// A vault note offered by the file-node picker.
public struct CanvasNoteRef: Sendable, Equatable, Hashable {
    public var path: String
    public var title: String?
    public init(path: String, title: String? = nil) { self.path = path; self.title = title }
}

/// The file as parsed: raw entries kept as-is (unknown keys included).
public struct CanvasData: Sendable, Equatable {
    /// Top-level object (its `nodes` / `edges` are replaced on serialize).
    public var top: JSONObject
    /// Raw node entries in file order (= z order, first is bottom).
    public var nodes: [JSONValue]
    public var edges: [JSONValue]
    public init(top: JSONObject, nodes: [JSONValue], edges: [JSONValue]) {
        self.top = top; self.nodes = nodes; self.edges = edges
    }
}

public struct CanvasStyle: Sendable, Equatable {
    public enum Layout: String, Sendable { case compact, pretty }
    /// `compact`: Obsidian (one object per line); `pretty`: JSON.stringify(indent).
    public var layout: Layout
    public var indent: String
    public var trailingNewline: Bool
    public init(layout: Layout, indent: String, trailingNewline: Bool) {
        self.layout = layout; self.indent = indent; self.trailingNewline = trailingNewline
    }
    public static let `default` = CanvasStyle(layout: .compact, indent: "\t", trailingNewline: false)
}

public struct CanvasParsed: Sendable, Equatable {
    public var data: CanvasData
    public var nodes: [CanvasNode]
    public var edges: [CanvasEdge]
    public var issues: [String]
    public var style: CanvasStyle
}

public enum CanvasParse: Sendable, Equatable {
    case ok(CanvasParsed)
    case failure(String)

    public var parsed: CanvasParsed? { if case let .ok(p) = self { return p } else { return nil } }
    public var error: String? { if case let .failure(e) = self { return e } else { return nil } }
}

public enum CanvasColor: Sendable, Equatable {
    case preset(Int)
    case hex(String)
}

/// One ordered patch: `nil` deletes the key.
public typealias CanvasPatch = [(key: String, value: JSONValue?)]

public typealias CanvasOp = @Sendable (CanvasData) -> CanvasData

public enum Canvas {
    static let geometryKeys: Set<String> = ["x", "y", "width", "height"]
    public static let maxBytes = 4 * 1024 * 1024

    /// Color usable for drawing (preset or hex), else nil. Never passes
    /// arbitrary strings through.
    public static func color(_ c: JSONValue?) -> CanvasColor? { color(c?.stringValue) }

    public static func color(_ c: String?) -> CanvasColor? {
        guard let c else { return nil }
        if c.count == 1, let n = Int(c), (1...6).contains(n) { return .preset(n) }
        let hex = Rx("^#(?:[0-9a-f]{3}|[0-9a-f]{6})$", [.caseInsensitive])
        if hex.test(c) { return .hex(c) }
        return nil
    }

    /// JS `Number(v)` for the values a canvas file can hold.
    static func num(_ v: JSONValue?, _ d: Double) -> Double {
        switch v {
        case let .number(n)?: return n.isFinite ? n : d
        case let .string(s)?:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return 0 }
            let n: Double?
            if t.hasPrefix("0x") || t.hasPrefix("0X") { n = UInt64(t.dropFirst(2), radix: 16).map(Double.init) }
            else if t.lowercased().contains("inf") || t.lowercased().contains("nan") || t.contains("p") { n = nil }
            else { n = Double(t) }
            guard let n, n.isFinite else { return d }
            return n
        default: return d
        }
    }

    static func isNumber(_ v: JSONValue?) -> Bool { if case .number? = v { return true } else { return false } }

    /// A renderable node from a raw entry (defaults filled), or an issue.
    public static func validateNode(_ raw: JSONValue) -> (node: CanvasNode?, issue: String?) {
        guard case var .object(o) = raw else { return (nil, "node is not an object") }
        guard let id = o["id"]?.stringValue, !id.isEmpty else { return (nil, "node without id") }
        guard let typeName = o["type"]?.stringValue, let type = CanvasNodeType(rawValue: typeName) else {
            return (nil, "node \(id): unknown type \(jsString(o["type"]))")
        }
        let x = num(o["x"], 0), y = num(o["y"], 0)
        let w = max(1, num(o["width"], 250)), h = max(1, num(o["height"], 60))
        var issue: String?
        if ["x", "y", "width", "height"].contains(where: { !isNumber(o[$0]) }) { issue = "node \(id): missing/invalid geometry" }
        o["x"] = .number(x); o["y"] = .number(y); o["width"] = .number(w); o["height"] = .number(h)
        if type == .text, o["text"]?.stringValue == nil { o["text"] = .string("") }
        if type == .file, o["file"]?.stringValue == nil {
            o["file"] = .string("")
            issue = "node \(id): file node without file"
        }
        if type == .link, o["url"]?.stringValue == nil {
            o["url"] = .string("")
            issue = "node \(id): link node without url"
        }
        return (CanvasNode(id: id, type: type, x: x, y: y, width: w, height: h, raw: o), issue)
    }

    /// `String(v)` for an issue message.
    static func jsString(_ v: JSONValue?) -> String {
        switch v {
        case nil: return "undefined"
        case .null?: return "null"
        case let .bool(b)?: return b ? "true" : "false"
        case let .number(n)?: return JSNumber.format(n)
        case let .string(s)?: return s
        case .array?: return "[array]"
        case .object?: return "[object Object]"
        }
    }

    public static func validateEdge(_ raw: JSONValue, ids: Set<String>) -> (edge: CanvasEdge?, issue: String?) {
        guard case let .object(o) = raw else { return (nil, "edge is not an object") }
        guard let id = o["id"]?.stringValue, !id.isEmpty else { return (nil, "edge without id") }
        guard let from = o["fromNode"]?.stringValue, let to = o["toNode"]?.stringValue else {
            return (nil, "edge \(id): missing endpoints")
        }
        guard ids.contains(from), ids.contains(to) else { return (nil, "edge \(id): dangling endpoint") }
        let fs = o["fromSide"]?.stringValue.flatMap(CanvasSide.init(rawValue:))
        let ts = o["toSide"]?.stringValue.flatMap(CanvasSide.init(rawValue:))
        return (CanvasEdge(id: id, fromNode: from, toNode: to, fromSide: fs, toSide: ts, raw: o), nil)
    }

    // MARK: - Serializer

    static func compactJSON(_ top: JSONObject, _ s: CanvasStyle) -> String {
        let keys = top.keys
        if keys.isEmpty { return "{}" }
        let lines = keys.map { k -> String in
            let v = top[k]!
            let head = s.indent + JSONValue.quote(k) + ":"
            if case let .array(a) = v {
                if a.isEmpty { return head + "[]" }
                return head + "[\n" + a.map { s.indent + s.indent + $0.stringify() }.joined(separator: ",\n") + "\n" + s.indent + "]"
            }
            return head + v.stringify()
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n}"
    }

    static func topWith(_ data: CanvasData) -> JSONObject {
        var top = JSONObject()
        for k in data.top.keys {
            top[k] = k == "nodes" ? .array(data.nodes) : k == "edges" ? .array(data.edges) : data.top[k]
        }
        if !top.has("nodes") { top["nodes"] = .array(data.nodes) }
        if !top.has("edges") { top["edges"] = .array(data.edges) }
        return top
    }

    public static func serialize(_ data: CanvasData, style: CanvasStyle = .default) -> String {
        let top = topWith(data)
        let body = style.layout == .pretty ? JSONValue.object(top).stringify(indent: style.indent) : compactJSON(top, style)
        return body + (style.trailingNewline ? "\n" : "")
    }

    static let indentRx = Rx("\\n([ \\t]+)\\S")
    static let compactGuess = Rx("\\[\\s*\\n[ \\t]*\\{\"")

    /// The style that reproduces `text` exactly, or the closest guess.
    public static func detectStyle(_ text: String, top: JSONObject? = nil) -> CanvasStyle {
        let trailingNewline = text.hasSuffix("\n")
        var indent = "\t"
        if let m = indentRx.match(text), let g = m.group(1, in: text) {
            indent = g.hasPrefix("\t") ? "\t" : g.replacingOccurrences(of: "\t", with: "")
        }
        if let top {
            for layout in [CanvasStyle.Layout.compact, .pretty] {
                let s = CanvasStyle(layout: layout, indent: indent, trailingNewline: trailingNewline)
                if let n = top["nodes"]?.arrayValue, let e = top["edges"]?.arrayValue,
                   serialize(CanvasData(top: top, nodes: n, edges: e), style: s) == text { return s }
                let plain = layout == .pretty ? JSONValue.object(top).stringify(indent: indent) : compactJSON(top, s)
                if plain + (trailingNewline ? "\n" : "") == text { return s }
            }
        }
        // Guess: an object opening and holding a key on the same line → compact.
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = t.isEmpty || !t.contains("\n") || compactGuess.test(text)
        return CanvasStyle(layout: compact ? .compact : .pretty, indent: indent, trailingNewline: trailingNewline)
    }

    // MARK: - Parser

    public static func parse(_ text: String) -> CanvasParse {
        var top: JSONObject
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            top = JSONObject()
        } else {
            let v: JSONValue
            do {
                v = try JSONValue.parse(text)
            } catch {
                return .failure("Invalid JSON: \(error.description)")
            }
            guard case let .object(o) = v else { return .failure("A canvas file must hold a JSON object.") }
            top = o
        }
        var issues: [String] = []
        let rawNodes = top["nodes"]?.arrayValue ?? []
        let rawEdges = top["edges"]?.arrayValue ?? []
        if let n = top["nodes"], n.arrayValue == nil { issues.append("\"nodes\" is not an array") }
        if let e = top["edges"], e.arrayValue == nil { issues.append("\"edges\" is not an array") }
        var nodes: [CanvasNode] = []
        var ids = Set<String>()
        for r in rawNodes {
            let (node, issue) = validateNode(r)
            if let issue { issues.append(issue) }
            if let node {
                if ids.insert(node.id).inserted { nodes.append(node) } else { issues.append("duplicate node id \(node.id)") }
            }
        }
        var edges: [CanvasEdge] = []
        for r in rawEdges {
            let (edge, issue) = validateEdge(r, ids: ids)
            if let issue { issues.append(issue) }
            if let edge { edges.append(edge) }
        }
        return .ok(CanvasParsed(data: CanvasData(top: top, nodes: rawNodes, edges: rawEdges), nodes: nodes, edges: edges,
                                issues: issues, style: detectStyle(text, top: top)))
    }

    // MARK: - Ops

    /// 16 hex chars, as Obsidian generates.
    public static func newID<G: RandomNumberGenerator>(using rng: inout G) -> String {
        String((0..<16).map { _ in "0123456789abcdef".randomElement(using: &rng)! })
    }

    public static func newID() -> String {
        var g = SystemRandomNumberGenerator()
        return newID(using: &g)
    }

    static func idOf(_ v: JSONValue) -> String? { v.objectValue?["id"]?.stringValue }

    /// Patch nodes by id (keys keep their position; new keys append; nil deletes).
    public static func patchNodes(_ patches: [String: CanvasPatch]) -> CanvasOp {
        return { d in
            var out = d
            out.nodes = d.nodes.map { n in
                guard let id = idOf(n), let p = patches[id], case var .object(o) = n else { return n }
                for (k, v) in p {
                    if let v, case let .number(x) = v, geometryKeys.contains(k) {
                        o[k] = .number(JSNumber.round(x))
                    } else {
                        o[k] = v
                    }
                }
                return .object(o)
            }
            return out
        }
    }

    public static func patchEdge(_ id: String, _ patch: CanvasPatch) -> CanvasOp {
        return { d in
            var out = d
            out.edges = d.edges.map { e in
                guard idOf(e) == id, case var .object(o) = e else { return e }
                for (k, v) in patch { o[k] = v }
                return .object(o)
            }
            return out
        }
    }

    /// Append a node (top of z order); groups go to the bottom so they stay behind.
    public static func addNode(_ node: JSONObject) -> CanvasOp {
        var n = node
        for k in ["x", "y", "width", "height"] {
            if case let .number(v)? = n[k] { n[k] = .number(JSNumber.round(v)) }
        }
        let isGroup = n["type"]?.stringValue == "group"
        let value = JSONValue.object(n)
        return { d in
            var out = d
            out.nodes = isGroup ? [value] + d.nodes : d.nodes + [value]
            return out
        }
    }

    public static func addEdge(_ edge: JSONObject) -> CanvasOp {
        let value = JSONValue.object(edge)
        return { d in
            var out = d
            out.edges = d.edges + [value]
            return out
        }
    }

    /// Remove nodes and every edge touching them, plus the given edges.
    public static func removeItems(_ nodeIDs: [String], edges edgeIDs: [String] = []) -> CanvasOp {
        let ns = Set(nodeIDs)
        let es = Set(edgeIDs)
        return { d in
            var out = d
            out.nodes = d.nodes.filter { !ns.contains(idOf($0) ?? "") }
            out.edges = d.edges.filter { e in
                if es.contains(idOf(e) ?? "") { return false }
                guard let o = e.objectValue else { return true }
                return !ns.contains(o["fromNode"]?.stringValue ?? "\u{0}") && !ns.contains(o["toNode"]?.stringValue ?? "\u{0}")
            }
            return out
        }
    }

    /// Apply `op` to the CURRENT text and return the minimal edit (or []
    /// when nothing changes / the text does not parse). The file keeps
    /// its style.
    public static func commit(_ current: String, _ op: CanvasOp) -> [TextEdit] {
        guard let p = parse(current).parsed else { return [] }
        let empty = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let next = serialize(op(p.data), style: empty ? .default : p.style)
        guard let e = RangedEdits.diff(current, next) else { return [] }
        return [e]
    }

    // MARK: - Node builders (key order matches the web client's literals)

    public static func textNode(id: String, text: String, x: Double, y: Double, width: Double = 250, height: Double = 60) -> JSONObject {
        JSONObject([("id", .string(id)), ("type", "text"), ("text", .string(text)),
                    ("x", .number(x)), ("y", .number(y)), ("width", .number(width)), ("height", .number(height))])
    }

    public static func fileNode(id: String, file: String, x: Double, y: Double, width: Double = 400, height: Double = 300) -> JSONObject {
        JSONObject([("id", .string(id)), ("type", "file"), ("file", .string(file)),
                    ("x", .number(x)), ("y", .number(y)), ("width", .number(width)), ("height", .number(height))])
    }

    public static func groupNode(id: String, x: Double, y: Double, width: Double, height: Double, label: String? = nil) -> JSONObject {
        var o = JSONObject([("id", .string(id)), ("type", "group"),
                            ("x", .number(x)), ("y", .number(y)), ("width", .number(width)), ("height", .number(height))])
        if let label { o["label"] = .string(label) }
        return o
    }

    public static func edge(id: String, from: String, fromSide: CanvasSide?, to: String, toSide: CanvasSide?) -> JSONObject {
        var o = JSONObject([("id", .string(id)), ("fromNode", .string(from))])
        if let fromSide { o["fromSide"] = .string(fromSide.rawValue) }
        o["toNode"] = .string(to)
        if let toSide { o["toSide"] = .string(toSide.rawValue) }
        return o
    }

    /// UTF-8 size guard for a commit (server limit: 4 MiB per note).
    public static func fitsLimit(_ current: String, _ edits: [TextEdit]) -> Bool {
        guard let e = edits.first else { return true }
        let cur = current.utf16.count
        if cur + e.insert.utf16.count <= 1_000_000 { return true }
        return RangedEdits.apply(edits, to: current).utf8.count <= maxBytes
    }
}
