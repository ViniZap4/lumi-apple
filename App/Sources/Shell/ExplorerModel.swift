import Foundation
import Observation
import LumiKit

/// Explorer state for the open book: the note tree, the miller-column
/// navigation and the transient prompts (filter, create, rename,
/// delete). One code path for both book kinds — a local book feeds the
/// tree from a recursive scan of its folder, a server book from the
/// note list the store already keeps current (feed catch-up included).
@Observable
@MainActor
final class ExplorerModel {
    enum Source: Equatable {
        case none
        case local(root: URL)
        case remote(vaultID: UUID)
    }

    /// Text prompt shown at the bottom of the explorer (yazi style).
    struct Prompt: Equatable {
        enum Kind: Equatable { case create, rename(ExplorerEntry), filter }
        var kind: Kind
        var text: String

        var label: String {
            switch kind {
            case .create: return "new"
            case .rename: return "rename"
            case .filter: return "filter"
            }
        }

        var hint: String {
            switch kind {
            case .create: return "name · a/b/name makes folders · trailing / makes a folder"
            case .rename: return "new name"
            case .filter: return "type to narrow · ⏎ keep · ⎋ clear"
            }
        }
    }

    private(set) var source: Source = .none
    var nav = MillerNav()
    private(set) var isLoading = false
    var prompt: Prompt?
    var pendingDelete: ExplorerEntry?
    /// `y` register: the note to duplicate on `p`.
    var yanked: ExplorerEntry?
    /// Rows that fit in the current column (Ctrl-d / Ctrl-u / page keys).
    var pageRows: Int = 20

    private var scanToken = UUID()

    var tree: NoteTree { nav.tree }

    // MARK: Sources

    func reset() {
        source = .none
        nav = MillerNav()
        prompt = nil
        pendingDelete = nil
        isLoading = false
    }

    func setShowHidden(_ show: Bool) {
        nav.showHidden = show
    }

    /// Open a local folder book: scan off-main, then show.
    func openLocal(root: URL, showHidden: Bool) {
        source = .local(root: root)
        nav = MillerNav()
        nav.showHidden = showHidden
        prompt = nil
        rescanLocal()
    }

    func rescanLocal(reveal path: String? = nil) {
        guard case let .local(root) = source else { return }
        let token = UUID()
        scanToken = token
        isLoading = nav.tree.noteCount == 0
        Task.detached(priority: .userInitiated) {
            let scan = LocalScan.run(root: root)
            await MainActor.run {
                guard self.scanToken == token else { return }
                self.nav.tree = NoteTree.build(scan.notes, extraFolders: scan.folders)
                self.isLoading = false
                if let path { self.revealPath(path) }
            }
        }
    }

    /// Server book: the store's note list is the source of truth.
    func openRemote(vaultID: UUID) {
        if source != .remote(vaultID: vaultID) {
            source = .remote(vaultID: vaultID)
            nav = MillerNav()
            prompt = nil
        }
        isLoading = true
    }

    func updateRemote(notes: [RemoteNote], loading: Bool) {
        guard case let .remote(vaultID) = source else { return }
        let rows = notes.filter { $0.vaultID == vaultID }
        nav.tree = NoteTree.build(rows.map {
            ExplorerNote(id: $0.id, path: $0.path, title: $0.title, updatedAt: $0.updatedAt)
        })
        isLoading = loading && rows.isEmpty
    }

    // MARK: Helpers

    /// Reveal a note by book-relative path (local) or id (remote).
    func revealPath(_ pathOrID: String) {
        if nav.reveal(noteID: pathOrID) { return }
        let dir = NoteTree.dirOf(NoteTree.normalizePath(pathOrID))
        nav.goTo(dir, select: NoteTree.folderKey(NoteTree.normalizePath(pathOrID)))
    }

    /// File URL for a local entry.
    func localURL(for entry: ExplorerEntry) -> URL? {
        guard case let .local(root) = source else { return nil }
        return entry.path.isEmpty ? root : root.appendingPathComponent(entry.path)
    }

    func localDirURL(_ dir: String) -> URL? {
        guard case let .local(root) = source else { return nil }
        return dir.isEmpty ? root : root.appendingPathComponent(dir)
    }

    var isLocal: Bool {
        if case .local = source { return true }
        return false
    }
}

/// Recursive scan of a local book: every `*.md` file plus every folder
/// (empty ones included). Skips hidden entries' contents only when they
/// are packages; dot-folders are listed and hidden by the explorer.
enum LocalScan {
    struct Result: Sendable {
        var notes: [ExplorerNote]
        var folders: [String]
    }

    /// Hard cap so a mis-linked home folder cannot stall the app.
    static let maxEntries = 50_000

    static func run(root: URL) -> Result {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .isPackageKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else {
            return Result(notes: [], folders: [])
        }
        let base = root.standardizedFileURL.path
        var notes: [ExplorerNote] = []
        var folders: [String] = []
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > maxEntries { break }
            let name = url.lastPathComponent
            // Never descend into VCS / metadata internals.
            if name == ".git" || name == ".lumi" || name == "node_modules" {
                walker.skipDescendants()
                if name != ".git" && name != ".lumi" { continue }
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            var rel = String(path.dropFirst(base.count))
            while rel.hasPrefix("/") { rel.removeFirst() }
            if rel.isEmpty { continue }
            if values?.isDirectory == true {
                folders.append(rel)
            } else if ["md", "canvas"].contains(url.pathExtension.lowercased()) {
                notes.append(ExplorerNote(id: rel, path: rel, title: "", updatedAt: values?.contentModificationDate))
            }
        }
        return Result(notes: notes, folders: folders)
    }
}
