import Testing
import Foundation
@testable import LumiKit

// These tests drive `RemoteEditorState` through `MockURLProtocol`, whose
// handler is a process-wide static. They're declared in an extension of
// the `.serialized` `LumiAPIClientVaultTests` suite so they share its
// ordering domain instead of racing the other mock-using tests.

private func makeEditorClient() async -> LumiAPIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let client = LumiAPIClient(session: URLSession(configuration: config))
    await client.setBaseURL(URL(string: "https://lumi.test")!)
    await client.setToken("tok")
    return client
}

private func readBody(_ request: URLRequest) -> String {
    var data = Data()
    if let stream = request.httpBodyStream {
        stream.open()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        stream.close()
    } else if let body = request.httpBody {
        data = body
    }
    return String(data: data, encoding: .utf8) ?? ""
}

private func snapshotResponse(_ request: URLRequest, text: String, clock: String = "Y2xr") -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    let body = try! JSONSerialization.data(withJSONObject: [
        "id": "note-1", "path": "note-1.md", "text": text, "vector_clock": clock
    ])
    return (response, body)
}

/// Lock-protected box so the URL-loading thread and the test can share
/// small bits of state.
private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

private let editorVaultID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

extension LumiAPIClientVaultTests {
    @Test("save started before reset() still commits the captured vault/note/text")
    @MainActor
    func remoteEditorSaveSurvivesReset() async throws {
        let sentPath = Box<String?>(nil)
        let sentBody = Box<String>("")
        MockURLProtocol.setHandler { request in
            sentPath.value = request.url?.path
            sentBody.value = readBody(request)
            return snapshotResponse(request, text: "edited body")
        }
        let client = await makeEditorClient()
        let editor = RemoteEditorState()
        editor.load(
            RemoteNoteSnapshot(id: "note-1", path: "note-1.md", text: "body", vectorClock: "b2xk"),
            vaultID: editorVaultID
        )
        editor.currentText = "edited body"

        // Close / Esc path: kick off the save, then reset synchronously.
        let save = try #require(editor.beginSave(via: client))
        editor.reset()

        let merged = await save.value
        #expect(merged?.text == "edited body")
        #expect(sentPath.value == "/api/vaults/3f2504e0-4f89-11d3-9a0c-0305e82c3301/notes/note-1/diff")
        #expect(sentBody.value.contains("edited body"))
        #expect(sentBody.value.contains("b2xk"))
        // The completed save must not resurrect state on the reset editor.
        #expect(editor.noteID == nil)
        #expect(editor.currentText == "")
        #expect(editor.status == .idle)
    }

    @Test("an unbound editor produces no save request")
    @MainActor
    func remoteEditorBeginSaveUnbound() {
        let editor = RemoteEditorState()
        #expect(editor.makeSaveRequest() == nil)
    }

    @Test("text typed during the save round-trip is preserved and stays dirty")
    @MainActor
    func remoteEditorKeepsTypingDuringRoundTrip() async throws {
        let entered = Box(false)
        let release = DispatchSemaphore(value: 0)
        MockURLProtocol.setHandler { request in
            entered.value = true
            // Hold the response until the test has typed more text.
            _ = release.wait(timeout: .now() + 5)
            return snapshotResponse(request, text: "hello", clock: "bmV3")
        }
        let client = await makeEditorClient()
        let editor = RemoteEditorState()
        editor.load(
            RemoteNoteSnapshot(id: "note-1", path: "note-1.md", text: "", vectorClock: "b2xk"),
            vaultID: editorVaultID
        )
        editor.currentText = "hello"
        let save = try #require(editor.beginSave(via: client))

        let deadline = Date().addingTimeInterval(5)
        while !entered.value, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(entered.value)
        editor.currentText = "hello world"
        release.signal()

        _ = await save.value
        #expect(editor.originalText == "hello")
        #expect(editor.currentText == "hello world")
        #expect(editor.isDirty)
        #expect(editor.vectorClock == "bmV3")
        if case .saved = editor.status {} else {
            Issue.record("expected .saved, got \(editor.status)")
        }
    }

    @Test("save with no concurrent typing adopts the server's merged text")
    @MainActor
    func remoteEditorAdoptsMergedText() async throws {
        MockURLProtocol.setHandler { request in
            // Server merged a concurrent edit from another client.
            snapshotResponse(request, text: "mine + theirs")
        }
        let client = await makeEditorClient()
        let editor = RemoteEditorState()
        editor.load(
            RemoteNoteSnapshot(id: "note-1", path: "note-1.md", text: "", vectorClock: "b2xk"),
            vaultID: editorVaultID
        )
        editor.currentText = "mine"
        _ = await editor.saveViaDiff(via: client)
        #expect(editor.currentText == "mine + theirs")
        #expect(editor.originalText == "mine + theirs")
        #expect(!editor.isDirty)
    }
}
