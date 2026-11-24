import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// File IO for the shared account registry (SPEC-LIVROS §8.3).
///
/// Reads never lock (writers replace the file with an atomic `rename`).
/// Every write is read-modify-write under `flock(LOCK_EX)` on the sibling
/// `accounts.yaml.lock`, the same lock the TUI takes, so concurrent writers
/// in either process never lose each other's rows.
public struct AccountsRegistryFile: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The file declares a newer format: never rewrite it.
        case readOnly(String)
        case lockTimeout
        case io(String)
    }

    /// Result of a read: `document` is nil when the file is missing.
    public struct Snapshot: Sendable, Equatable {
        public var document: AccountsDocument?
        public var readOnlyReason: String?
        public var fingerprint: FileFingerprint?
    }

    public let fileURL: URL

    public init(fileURL: URL = ConfigPaths.accounts) {
        self.fileURL = fileURL
    }

    public var directory: URL { fileURL.deletingLastPathComponent() }
    public var lockURL: URL { URL(fileURLWithPath: fileURL.path + ".lock") }
    /// Where a TUI v1/v2 file (which may carry TUI tokens) is set aside
    /// before the first v3 write. The app never reads its tokens; the TUI
    /// imports them into its own `tokens.yaml` and deletes the file.
    public var legacyAsideURL: URL { directory.appendingPathComponent("accounts.v2.yaml") }

    // MARK: Read

    public func read() -> Snapshot {
        let fp = FileFingerprint(path: fileURL.path)
        guard let data = try? Data(contentsOf: fileURL) else {
            return Snapshot(document: nil, readOnlyReason: nil, fingerprint: fp)
        }
        let text = String(decoding: data, as: UTF8.self)
        do {
            return Snapshot(document: try AccountsFile.decode(text), readOnlyReason: nil, fingerprint: fp)
        } catch .unsupportedVersion(let v) {
            // Show the rows, refuse to write.
            let lenient = text.replacingOccurrences(of: "version: \(v)", with: "version: \(AccountsFile.currentVersion)")
            return Snapshot(document: try? AccountsFile.decode(lenient),
                            readOnlyReason: "accounts.yaml uses format version \(v); update Lumi to edit accounts",
                            fingerprint: fp)
        } catch {
            return Snapshot(document: nil,
                            readOnlyReason: "accounts.yaml could not be read (\(error)); fix or remove it",
                            fingerprint: fp)
        }
    }

    // MARK: Write

    /// Lock, re-read from disk, apply `body`, write atomically (0600),
    /// unlock. Returns the accounts as written.
    @discardableResult
    public func mutate(_ body: (inout [Account]) throws -> Void) throws -> [Account] {
        try ensureDirectory()
        return try withLock {
            let snap = read()
            if let reason = snap.readOnlyReason { throw Failure.readOnly(reason) }
            var accounts = snap.document?.accounts ?? []
            try body(&accounts)
            let text = AccountsFile.encode(accounts)
            if let doc = snap.document, doc.sourceVersion < AccountsFile.currentVersion {
                // TUI v1/v2 file: move it aside untouched (tokens included)
                // for the TUI to import, then write v3.
                if rename(fileURL.path, legacyAsideURL.path) != 0 {
                    throw Failure.io("could not set aside the v\(doc.sourceVersion) accounts file (errno \(errno))")
                }
                chmod(legacyAsideURL.path, 0o600)
            } else if let current = try? Data(contentsOf: fileURL), current == Data(text.utf8) {
                return AccountsFile.canonicalOrder(accounts)
            }
            try writeAtomically(Data(text.utf8))
            return AccountsFile.canonicalOrder(accounts)
        }
    }

    func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            } catch {
                throw Failure.io("mkdir \(directory.path): \(error.localizedDescription)")
            }
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io("open lock (errno \(errno))") }
        defer { close(fd) }
        // Bounded wait: a stuck peer must not hang the main thread forever.
        let deadline = Date().addingTimeInterval(5)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { throw Failure.lockTimeout }
            usleep(2_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func writeAtomically(_ data: Data) throws {
        let tmp = directory.appendingPathComponent(".accounts-\(UUID().uuidString).yaml.tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io("create temp (errno \(errno))") }
        var ok = false
        defer {
            if !ok { unlink(tmp.path) }
        }
        let written = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            var off = 0
            while off < buf.count {
                let n = write(fd, base + off, buf.count - off)
                if n <= 0 { if errno == EINTR { continue }; return -1 }
                off += n
            }
            return off
        }
        fchmod(fd, 0o600)
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced else { throw Failure.io("write temp failed") }
        guard rename(tmp.path, fileURL.path) == 0 else { throw Failure.io("rename (errno \(errno))") }
        ok = true
        chmod(fileURL.path, 0o600)
    }
}

/// Identity of a file version: inode + mtime + size. A change in any of
/// them means another process rewrote the file.
public struct FileFingerprint: Sendable, Equatable {
    public let inode: UInt64
    public let mtimeNanos: Int64
    public let size: Int64

    public init?(path: String) {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        inode = UInt64(st.st_ino)
        mtimeNanos = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        size = Int64(st.st_size)
    }
}

/// Watches a directory with a DispatchSource (vnode events on the
/// directory fd), so atomic renames of files inside it — which replace the
/// inode and would orphan a per-file watch — are seen. `onChange` runs on
/// the given queue; callers re-stat the files they care about.
public final class DirectoryWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private let url: URL
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void

    public init(url: URL, queue: DispatchQueue = .main, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
    }

    /// Returns false when the directory can't be opened (missing).
    @discardableResult
    public func start() -> Bool {
        stop()
        let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link, .extend, .attrib], queue: queue)
        let handler = onChange
        src.setEventHandler { handler() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        return true
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }
}
