import Testing
import Foundation
import CoreGraphics
@testable import LumiKit

/// Port of web-client `lib/canvas/canvas.test.ts` over the same fixtures.
private let obsidian = (try? Fixtures.text("canvas/obsidian.canvas")) ?? ""
private let pretty = (try? Fixtures.text("canvas/pretty.canvas")) ?? ""

private func ok(_ text: String) throws -> CanvasParsed {
    switch Canvas.parse(text) {
    case let .ok(p): return p
    case let .failure(e): throw CanvasTestError(message: e)
    }
}

private struct CanvasTestError: Error { let message: String }

@Suite("Canvas parse / serialize")
struct CanvasParseTests {
    @Test("round-trips Obsidian files byte for byte")
    func obsidianRoundTrip() throws {
        let p = try ok(obsidian)
        #expect(p.style == CanvasStyle(layout: .compact, indent: "\t", trailingNewline: false))
        #expect(Canvas.serialize(p.data, style: p.style) == obsidian)
        #expect(p.nodes.map(\.type) == [.group, .text, .file, .link, .text])
        #expect(p.edges.count == 3)
        #expect(p.issues.isEmpty)
    }

    @Test("round-trips pretty JSON (2 spaces, key order, extra keys, trailing newline)")
    func prettyRoundTrip() throws {
        let p = try ok(pretty)
        #expect(p.style == CanvasStyle(layout: .pretty, indent: "  ", trailingNewline: true))
        #expect(Canvas.serialize(p.data, style: p.style) == pretty)
        #expect(p.data.top.keys == ["edges", "nodes", "metadata"])
        #expect(p.edges.map(\.id) == ["f5a6b7c8d9e0f1a2"])
        #expect(p.issues.filter { $0.contains("dangling") }.count == 2)
    }

    @Test("is tolerant: empty, {}, missing keys, bad nodes, invalid JSON")
    func tolerant() throws {
        #expect(try ok("").nodes.isEmpty)
        #expect(try ok("{}").nodes.isEmpty)
        let p = try ok(#"{"nodes":[{"id":"a","type":"text","text":"x"},{"type":"text"},{"id":"b","type":"weird"},{"id":"a","type":"text","x":0,"y":0,"width":1,"height":1}],"edges":"nope"}"#)
        #expect(p.nodes.map { [$0.id, "\($0.x)", "\($0.width)", "\($0.height)"] } == [["a", "0.0", "250.0", "60.0"]])
        let joined = p.issues.joined(separator: "|")
        #expect(joined.range(of: "not an array.*geometry.*without id.*unknown type.*duplicate", options: .regularExpression) != nil)
        #expect(Canvas.parse(#"{"nodes": ["#).parsed == nil)
        #expect(Canvas.parse("[]").parsed == nil)
    }

    @Test("keeps unknown node keys and colors through edits")
    func unknownKeys() {
        let edits = Canvas.commit(obsidian, Canvas.patchNodes(["e4f5a6b7c8d9e0f1": [("x", 100)]]))
        let next = RangedEdits.apply(edits, to: obsidian)
        #expect(next.contains(#"{"id":"e4f5a6b7c8d9e0f1","type":"text","text":"Unknown keys survive","x":100,"y":80,"width":250,"height":60,"styleAttributes":{"shape":"pill"}}"#))
    }

    @Test("validates colors without passing CSS through")
    func colors() {
        #expect(Canvas.color("3") == .preset(3))
        #expect(Canvas.color("#a1B2c3") == .hex("#a1B2c3"))
        #expect(Canvas.color("red; background:url(x)") == nil)
        #expect(Canvas.color("7") == nil)
    }

    @Test("generates 16-hex ids")
    func ids() {
        let id = Canvas.newID()
        #expect(id.count == 16 && id.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test("guesses a style for unknown layouts")
    func guesses() {
        #expect(Canvas.detectStyle(#"{"nodes":[],"edges":[]}"#).layout == .compact)
        #expect(Canvas.detectStyle("{\n    \"nodes\": [\n      {\n").indent == "    ")
    }
}

@Suite("Canvas commit = one minimal ranged edit")
@MainActor
struct CanvasCommitTests {
    @Test("moving a node only touches its numbers")
    func move() throws {
        let edits = Canvas.commit(obsidian, Canvas.patchNodes(["b1c2d3e4f5a6b7c8": [("x", -370), ("y", -190)]]))
        #expect(edits.count == 1)
        #expect(edits[0].insert == #"70,"y":-19"#)
        #expect(RangedEdits.cost(edits) == 20)
        let p = try ok(RangedEdits.apply(edits, to: obsidian))
        #expect(p.nodes[1].x == -370 && p.nodes[1].y == -190)
    }

    @Test("pretty files stay pretty")
    func prettyStays() {
        let edits = Canvas.commit(pretty, Canvas.patchNodes(["b1c2d3e4f5a6b7c8": [("width", 320)]]))
        #expect(edits == [RangedEdits.diff(pretty, pretty.replacingOccurrences(of: "\"width\": 300", with: "\"width\": 320"))!])
    }

    @Test("adds, connects, recolors and removes")
    func lifecycle() throws {
        let lt = MemoryLiveText(obsidian)
        func commit(_ op: @escaping CanvasOp) { lt.apply(Canvas.commit(lt.read(), op)) }
        commit(Canvas.addNode(Canvas.textNode(id: "n1", text: "New", x: 500.4, y: 10)))
        commit(Canvas.addEdge(Canvas.edge(id: "e1", from: "n1", fromSide: .left, to: "c2d3e4f5a6b7c8d9", toSide: .right)))
        commit(Canvas.patchNodes(["n1": [("color", "2")]]))
        commit(Canvas.patchEdge("e1", [("label", "link")]))
        var p = try ok(lt.read())
        #expect(p.nodes.last?.id == "n1" && p.nodes.last?.x == 500 && p.nodes.last?.color == "2")
        #expect(p.edges.last?.id == "e1" && p.edges.last?.label == "link")
        #expect(Canvas.serialize(p.data, style: p.style) == lt.read())
        commit(Canvas.removeItems(["c2d3e4f5a6b7c8d9"]))
        p = try ok(lt.read())
        #expect(!p.nodes.contains { $0.id == "c2d3e4f5a6b7c8d9" })
        #expect(p.edges.map(\.id) == ["a6b7c8d9e0f1a2b3"])
        // Groups are inserted at the bottom of the z order.
        commit(Canvas.addNode(Canvas.groupNode(id: "g", x: 0, y: 0, width: 10, height: 10)))
        #expect(try ok(lt.read()).nodes.first?.id == "g")
    }

    @Test("an empty file becomes an Obsidian-style canvas")
    func emptyFile() {
        let edits = Canvas.commit("", Canvas.addNode(Canvas.textNode(id: "a", text: "hi", x: 0, y: 0)))
        #expect(RangedEdits.apply(edits, to: "") == "{\n\t\"nodes\":[\n\t\t{\"id\":\"a\",\"type\":\"text\",\"text\":\"hi\",\"x\":0,\"y\":0,\"width\":250,\"height\":60}\n\t],\n\t\"edges\":[]\n}")
    }

    @Test("invalid JSON is never overwritten; no-op returns no edit")
    func invalidAndNoop() {
        #expect(Canvas.commit(#"{"nodes": ["#, Canvas.patchNodes([:])).isEmpty)
        #expect(Canvas.commit(obsidian, Canvas.patchNodes(["b1c2d3e4f5a6b7c8": [("x", -380)]])).isEmpty)
    }

    @Test("the server's empty canvas parses and takes a first edit")
    func serverContract() throws {
        let empty = "{\"nodes\":[],\"edges\":[]}\n"
        let p = try ok(empty)
        #expect(p.nodes.isEmpty)
        #expect(p.style.layout == .compact && p.style.trailingNewline)
        let next = RangedEdits.apply(Canvas.commit(empty, Canvas.addNode(Canvas.textNode(id: "a", text: "x", x: 0, y: 0))), to: empty)
        #expect(try ok(next).nodes.map(\.id) == ["a"])
        #expect(next.hasSuffix("}\n"))
    }

    @Test("size guard: refuses commits over 4 MiB of UTF-8")
    func sizeGuard() {
        let big = String(repeating: "é", count: 1_100_000) // 2.2 MB UTF-8, 1.1M UTF-16
        #expect(Canvas.fitsLimit("", [TextEdit(from: 0, to: 0, insert: big)]))
        #expect(!Canvas.fitsLimit(big, [TextEdit(from: 0, to: 0, insert: big)]))
    }
}

@Suite("Ordered JSON (JSON.parse / JSON.stringify parity)")
struct OrderedJSONTests {
    @Test("numbers format like JavaScript")
    func numbers() {
        let cases: [(Double, String)] = [
            (0, "0"), (-0.0, "0"), (1, "1"), (-380, "-380"), (0.5, "0.5"), (1e21, "1e+21"), (1e20, "100000000000000000000"),
            (123.456, "123.456"), (1e-7, "1e-7"), (0.000001, "0.000001"), (1.5e-10, "1.5e-10"), (2.5e25, "2.5e+25"), (0.1 + 0.2, "0.30000000000000004"),
        ]
        for (v, s) in cases { #expect(JSNumber.format(v) == s, "\(v)") }
        #expect(JSNumber.round(-2.5) == -2 && JSNumber.round(2.5) == 3)
    }

    @Test("strings escape like JSON.stringify; key order follows JS")
    func strings() throws {
        #expect(JSONValue.string("a\"b\\c\n\t\u{1}é/😀").stringify() == #""a\"b\\c\n\t\u0001é/😀""#)
        let v = try JSONValue.parse(#"{"b":1,"2":true,"a":[null,"x"],"1":{},"b":2}"#)
        #expect(v.stringify() == #"{"1":{},"2":true,"b":2,"a":[null,"x"]}"#)
        #expect(throws: JSONParseError.self) { try JSONValue.parse("{'a':1}") }
        #expect(throws: JSONParseError.self) { try JSONValue.parse("01") }
        #expect(try JSONValue.parse(" [1.5e2] ") == [150.0])
        #expect(JSONValue.object(JSONObject([("a", [1, 2])])).stringify(indent: "  ") == "{\n  \"a\": [\n    1,\n    2\n  ]\n}")
    }
}

@Suite("Ranged text diff")
struct RangedEditsTests {
    @Test("prefix/suffix with surrogate safety")
    func diff() {
        #expect(RangedEdits.diff("abc", "abc") == nil)
        #expect(RangedEdits.diff("hello world", "hello brave world") == TextEdit(from: 6, to: 6, insert: "brave "))
        #expect(RangedEdits.diff("aaa", "aa") == TextEdit(from: 2, to: 3, insert: ""))
        #expect(RangedEdits.diff("x😀y", "x😁y") == TextEdit(from: 1, to: 3, insert: "😁"))
        #expect(RangedEdits.diff("ab", "b", offset: 10) == TextEdit(from: 10, to: 11, insert: ""))
    }

    @Test("disjoint edits apply right to left; overlaps are refused")
    func apply() {
        let e = [TextEdit(from: 0, to: 1, insert: "X"), TextEdit(from: 4, to: 5, insert: "YY")]
        #expect(RangedEdits.apply(e, to: "abcdef") == "XbcdYYf")
        #expect(RangedEdits.sortedDescending(e).map(\.from) == [4, 0])
        #expect(!RangedEdits.isDisjoint([TextEdit(from: 0, to: 3, insert: ""), TextEdit(from: 2, to: 4, insert: "")]))
        #expect(RangedEdits.apply([TextEdit(from: 0, to: 3, insert: ""), TextEdit(from: 2, to: 4, insert: "")], to: "abcdef") == "abcdef")
    }
}

@Suite("Canvas pan / zoom math")
struct CanvasGeometryTests {
    let v = CanvasViewport(x: 100, y: 50, zoom: 1)

    @Test("world <-> screen are inverse")
    func inverse() {
        let z = CanvasViewport(x: -3, y: 9, zoom: 1.7)
        let back = CanvasGeometry.toWorld(z, CanvasGeometry.toScreen(z, CGPoint(x: 37, y: -12)))
        #expect(abs(back.x - 37) < 1e-9 && abs(back.y + 12) < 1e-9)
    }

    @Test("zoomAt keeps the point under the cursor fixed and clamps")
    func zoomAt() {
        let at = CGPoint(x: 300, y: 200)
        let before = CanvasGeometry.toWorld(v, at)
        let z = CanvasGeometry.zoomAt(v, at.x, at.y, 2)
        #expect(z.zoom == 2)
        let after = CanvasGeometry.toWorld(z, at)
        #expect(abs(after.x - before.x) < 1e-9 && abs(after.y - before.y) < 1e-9)
        #expect(CanvasGeometry.zoomAt(v, 0, 0, 1000).zoom == CanvasGeometry.maxZoom)
        #expect(CanvasGeometry.zoomAt(v, 0, 0, 0.0001).zoom == CanvasGeometry.minZoom)
        #expect(CanvasGeometry.clampZoom(1) == 1)
    }

    @Test("wheel pans, ctrl/cmd+wheel zooms")
    func wheel() {
        #expect(CanvasGeometry.wheel(v, .init(deltaX: 10, deltaY: 20), at: .zero) == CanvasViewport(x: 90, y: 30, zoom: 1))
        #expect(CanvasGeometry.wheel(v, .init(deltaX: 0, deltaY: -100, ctrl: true), at: .zero).zoom > 1)
        #expect(CanvasGeometry.wheel(v, .init(deltaX: 0, deltaY: 100, meta: true), at: .zero).zoom < 1)
        #expect(CanvasGeometry.wheel(v, .init(deltaX: 0, deltaY: 3, deltaMode: 1), at: .zero).y == 50 - 48)
    }

    @Test("fit centers the bounds and caps zoom at 1")
    func fit() {
        let b = CanvasGeometry.bounds([CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 300, y: 100, width: 100, height: 100)])!
        #expect(b == CGRect(x: 0, y: 0, width: 400, height: 200))
        let f = CanvasGeometry.fit(b, 1000, 600)
        #expect(f.zoom == 1)
        #expect(CanvasGeometry.toScreen(f, CGPoint(x: 200, y: 100)) == CGPoint(x: 500, y: 300))
        let g = CanvasGeometry.fit(b, 300, 300, pad: 50)
        #expect(abs(g.zoom - 0.5) < 1e-9)
        #expect(CanvasGeometry.fit(nil, 800, 600) == CanvasViewport(x: 400, y: 300, zoom: 1))
    }

    @Test("edge geometry: sides, curve and midpoint")
    func edges() throws {
        let a = CGRect(x: 0, y: 0, width: 100, height: 50)
        let b = CGRect(x: 300, y: 0, width: 100, height: 50)
        #expect(CanvasGeometry.autoSides(a, b) == (.right, .left))
        #expect(CanvasGeometry.autoSides(a, CGRect(x: 0, y: 300, width: 100, height: 50)) == (.bottom, .top))
        #expect(CanvasGeometry.nearestSide(b, CGPoint(x: 290, y: 30)) == .left)
        let e = try #require(Canvas.validateEdge(["id": "e", "fromNode": "a", "toNode": "b"], ids: ["a", "b"]).edge)
        let g = CanvasGeometry.edgeGeometry(e, a, b)
        #expect(g.from == CGPoint(x: 100, y: 25))
        #expect(g.to == CGPoint(x: 300, y: 25))
        #expect(abs(g.mid.x - 200) < 1e-9 && abs(g.mid.y - 25) < 1e-9)
        #expect(abs(g.endAngle) < 1e-9)
        #expect(g.d.hasPrefix("M 100 25 C"))
        #expect(CanvasGeometry.cubicAt(g.from, g.c1, g.c2, g.to, 1) == g.to)
        let head = CanvasGeometry.arrowHead(g.to, g.endAngle)
        #expect(head.count == 3 && head[1].x < g.to.x)
        #expect(CanvasGeometry.distance(CGPoint(x: 200, y: 27), to: g) < 3)
    }

    @Test("hit testing prefers nodes over groups; reading order")
    func hitAndOrder() throws {
        let p = try ok(obsidian)
        #expect(CanvasGeometry.hitNode(p.nodes, CGPoint(x: -300, y: -150))?.id == "b1c2d3e4f5a6b7c8")
        #expect(CanvasGeometry.hitNode(p.nodes, CGPoint(x: 420, y: 240))?.id == "8a7c1f0e2b3d4c5a")
        #expect(CanvasGeometry.hitNode(p.nodes, CGPoint(x: 9999, y: 0)) == nil)
        #expect(CanvasGeometry.readingOrder(p.nodes).map(\.id) == [
            "b1c2d3e4f5a6b7c8", "c2d3e4f5a6b7c8d9", "d3e4f5a6b7c8d9e0", "e4f5a6b7c8d9e0f1", "8a7c1f0e2b3d4c5a",
        ])
    }
}

@Suite("Canvas keys")
struct CanvasKeysTests {
    func k(_ s: String, shift: Bool = false, ctrl: Bool = false, meta: Bool = false) -> StructuredKey {
        StructuredKey(s, shift: shift, ctrl: ctrl, meta: meta)
    }

    @Test("cycles, activates, opens")
    func cycle() {
        var keys = CanvasKeys()
        #expect(keys.feed(k("Tab"), hasSelection: false) == .cycle(dir: 1))
        #expect(keys.feed(k("Tab", shift: true), hasSelection: true) == .cycle(dir: -1))
        #expect(keys.feed(k("Enter"), hasSelection: true) == .activate)
        #expect(keys.feed(k("Enter"), hasSelection: false) == nil)
        #expect(keys.feed(k("g"), hasSelection: true) == nil)
        #expect(keys.feed(k("f"), hasSelection: true) == .openFile(split: false))
        #expect(keys.feed(k("w", ctrl: true), hasSelection: true) == nil)
        #expect(keys.feed(k("f"), hasSelection: true) == .openFile(split: true))
    }

    @Test("pans without selection, nudges with it; zoom and fit")
    func pan() {
        var keys = CanvasKeys()
        #expect(keys.feed(k("l"), hasSelection: false) == .pan(dx: -80, dy: 0))
        #expect(keys.feed(k("l"), hasSelection: true) == .pan(dx: -80, dy: 0))
        #expect(keys.feed(k("L"), hasSelection: true) == .nudge(dx: 20, dy: 0))
        #expect(keys.feed(k("ArrowUp", shift: true), hasSelection: true) == .nudge(dx: 0, dy: -20))
        #expect(keys.feed(k("+"), hasSelection: false) == .zoom(factor: 1.2))
        #expect(keys.feed(k("-"), hasSelection: false) == nil, "- is the explorer (SPEC-PARTE2 §5b)")
        #expect(keys.feed(k("0"), hasSelection: false) == .fit)
    }

    @Test("§5b: zoom on + = zi ⌘+ / _ zo ⌘- / 0 zf; - is never taken")
    func zoomKeys() {
        var keys = CanvasKeys()
        let zin = CanvasKeyAction.zoom(factor: CanvasKeys.zoomStep)
        let zout = CanvasKeyAction.zoom(factor: 1 / CanvasKeys.zoomStep)
        #expect(keys.feed(k("+"), hasSelection: false) == zin)
        #expect(keys.feed(k("="), hasSelection: true) == zin)
        #expect(keys.feed(k("_"), hasSelection: false) == zout)
        #expect(keys.feed(k("z"), hasSelection: false) == nil)
        #expect(keys.pending == "z")
        #expect(keys.feed(k("i"), hasSelection: false) == zin)
        _ = keys.feed(k("z"), hasSelection: false)
        #expect(keys.feed(k("o"), hasSelection: false) == zout)
        _ = keys.feed(k("z"), hasSelection: false)
        #expect(keys.feed(k("f"), hasSelection: false) == .fit)
        #expect(keys.feed(k("0"), hasSelection: false) == .fit)
        #expect(keys.feed(k("+", meta: true), hasSelection: false) == zin)
        #expect(keys.feed(k("=", meta: true), hasSelection: false) == zin)
        #expect(keys.feed(k("-", meta: true), hasSelection: false) == zout)
        // Plain `-`, with or without a selection, after any prefix: never.
        for prefix in [nil, "g", "z", "c"] as [String?] {
            for sel in [false, true] {
                var ks = CanvasKeys()
                if let prefix { _ = ks.feed(k(prefix), hasSelection: sel) }
                #expect(ks.feed(k("-"), hasSelection: sel) == nil)
            }
        }
    }

    @Test("creates, deletes, colors")
    func create() {
        var keys = CanvasKeys()
        #expect(keys.feed(k("a"), hasSelection: false) == .addText)
        #expect(keys.feed(k("f"), hasSelection: false) == .addFile)
        #expect(keys.feed(k("Backspace"), hasSelection: true) == .delete)
        #expect(keys.feed(k("d"), hasSelection: false) == nil)
        #expect(keys.feed(k("c"), hasSelection: true) == nil)
        #expect(keys.feed(k("4"), hasSelection: true) == .color("4"))
        _ = keys.feed(k("c"), hasSelection: true)
        #expect(keys.feed(k("0"), hasSelection: true) == .color(nil))
        #expect(keys.feed(k("k", meta: true), hasSelection: true) == nil)
    }
}
