import Testing
import Foundation
@testable import LumiKit

@Suite("Canvas files and DTOs (CRDT-CLIENT-PROTOCOL §13)")
struct CanvasFilesTests {
    @Test("a name.canvas creates the server's empty canvas; rename keeps the kind")
    func localCanvas() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try FileOperations.createCanvas(in: dir, name: "Launch plan.canvas")
        #expect(url.lastPathComponent == "Launch plan.canvas")
        #expect(try String(contentsOf: url, encoding: .utf8) == "{\"nodes\":[],\"edges\":[]}\n")
        let again = try FileOperations.createCanvas(in: dir, name: "Launch plan")
        #expect(again.lastPathComponent == "Launch plan-2.canvas")
        let renamed = try FileOperations.rename(at: url, to: "Roadmap")
        #expect(renamed.lastPathComponent == "Roadmap.canvas")
        let renamed2 = try FileOperations.rename(at: renamed, to: "Map.canvas")
        #expect(renamed2.lastPathComponent == "Map.canvas")
        #expect(try String(contentsOf: renamed2, encoding: .utf8) == "{\"nodes\":[],\"edges\":[]}\n")
        #expect(FileOperations.canvasFileName("x.CANVAS") == "x.canvas")
    }

    @Test("note DTOs carry kind; create sends kind:\"canvas\"")
    func dtos() throws {
        let json = #"{"id":"map.canvas","vault_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","path":"maps/map.canvas","title":"map","kind":"canvas"}"#
        let n = try JSONDecoder().decode(RemoteNote.self, from: Data(json.utf8))
        #expect(n.kind == "canvas")
        #expect(NoteKind.resolve(path: n.path, kind: n.kind) == .canvas)
        let old = #"{"id":"a","vault_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","path":"a.md","title":"a"}"#
        #expect(try JSONDecoder().decode(RemoteNote.self, from: Data(old.utf8)).kind == nil)
        let body = try JSONEncoder().encode(CreateNoteRequest(title: "map", body: "", tags: [], kind: "canvas"))
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(obj?["kind"] as? String == "canvas")
        let md = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CreateNoteRequest(title: "n", body: "", tags: []))) as? [String: Any]
        #expect(md?["kind"] == nil)
    }
}
