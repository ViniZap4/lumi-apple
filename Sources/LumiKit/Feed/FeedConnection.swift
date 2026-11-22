import Foundation

/// Account-feed connection state (SPEC-LIVROS §4.2 `accountFeed`).
public enum AccountFeedState: Sendable, Equatable {
    case connecting
    /// Connected and `hello` received.
    case open
    /// Waiting before the next attempt.
    case backoff(attempt: Int, retryInSeconds: Double)
    /// 401 or `session.ended`: stopped until the user signs in again.
    case authDead
    /// Server has no `/api/events` (pre-feed server). Re-probed slowly;
    /// books show Offline (shared case table) with an explanation.
    case disabled

    public var isConnected: Bool { self == .open }
}

/// Backoff policy: 1 s base, ×2, capped at 30 s, jittered, never below a
/// server `Retry-After`.
public enum FeedBackoff {
    public static let base: Double = 1
    public static let cap: Double = 30

    /// `attempt` is 1-based. `jitter` maps the nominal delay to the actual
    /// one (default ±20 %).
    public static func delay(attempt: Int, retryAfter: Double? = nil,
                             jitter: (Double) -> Double = FeedBackoff.defaultJitter) -> Double {
        let exp = min(cap, base * pow(2, Double(max(0, attempt - 1))))
        let jittered = min(cap, max(0, jitter(exp)))
        if let retryAfter { return max(jittered, retryAfter) }
        return jittered
    }

    public static let defaultJitter: @Sendable (Double) -> Double = { $0 * Double.random(in: 0.8...1.2) }
}

/// One SSE stream per account: `GET /api/events` with the token in the
/// `Authorization` header (never in the URL), read with
/// `URLSession.bytes(for:)`. Reconnects with backoff, treats 60 s without
/// bytes as a dead connection, honours `reconnect` and `Retry-After`, and
/// stops for good on 401 / `session.ended`.
public actor FeedConnection {
    public enum Output: Sendable, Equatable {
        case state(AccountFeedState)
        case event(FeedEvent)
        /// Malformed payload or protocol oddity, for the details popover.
        case problem(String)
    }

    public struct Config: Sendable {
        public var pingTimeout: Duration = .seconds(60)
        public var watchdogInterval: Duration = .seconds(5)
        /// How often to re-probe a server without the feed endpoint.
        public var disabledRetry: Duration = .seconds(600)
        public var jitter: @Sendable (Double) -> Double = FeedBackoff.defaultJitter
        /// Extra random delay added to a server `reconnect.after_ms`.
        public var reconnectJitterMs: @Sendable () -> Int = { Int.random(in: 0...1000) }
        public var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

        public init() {}
    }

    public nonisolated let outputs: AsyncStream<Output>
    private let continuation: AsyncStream<Output>.Continuation
    private let baseURL: URL
    private let tokenProvider: @Sendable () async -> String?
    private let session: URLSession
    private let config: Config
    private var loop: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var wakeGeneration = 0

    public init(baseURL: URL, session: URLSession = .shared, config: Config = Config(),
                tokenProvider: @escaping @Sendable () async -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.config = config
        self.tokenProvider = tokenProvider
        (outputs, continuation) = AsyncStream<Output>.makeStream(bufferingPolicy: .unbounded)
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    /// Stop and finish `outputs`. Idempotent.
    public func stop() {
        loop?.cancel()
        loop = nil
        wake?.resume()
        wake = nil
        continuation.finish()
    }

    /// "Tentar agora": cut the current backoff short.
    public func retryNow() {
        wake?.resume()
        wake = nil
    }

    static func eventsRequest(baseURL: URL, token: String, timeout: TimeInterval) -> URLRequest? {
        guard let url = LumiAPIClient.endpoint(baseURL, "/api/events") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return req
    }

    // MARK: Loop

    enum AttemptOutcome: Sendable, Equatable {
        case authDead
        case disabled
        case reconnect(afterMs: Int)
        case failed(retryAfter: Double?, gotHello: Bool)
        case cancelled
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            emit(.state(.connecting))
            let outcome = await runOnce()
            switch outcome {
            case .cancelled:
                return
            case .authDead:
                emit(.state(.authDead))
                return
            case .disabled:
                emit(.state(.disabled))
                attempt = 0
                await pause(config.disabledRetry)
            case .reconnect(let afterMs):
                // Planned server restart / max lifetime: "connecting", not a failure.
                attempt = 0
                emit(.state(.connecting))
                await pause(.milliseconds(afterMs + config.reconnectJitterMs()))
            case .failed(let retryAfter, let gotHello):
                if gotHello { attempt = 0 }
                attempt += 1
                let delay = FeedBackoff.delay(attempt: attempt, retryAfter: retryAfter, jitter: config.jitter)
                emit(.state(.backoff(attempt: attempt, retryInSeconds: delay)))
                await pause(.milliseconds(Int(delay * 1000)))
            }
        }
    }

    /// Interruptible sleep (`retryNow` / `stop` wake it).
    private func pause(_ d: Duration) async {
        let sleeper = config.sleep
        if Task.isCancelled { return }
        wakeGeneration += 1
        let generation = wakeGeneration
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            wake = cont
            Task {
                try? await sleeper(d)
                self.resumeWake(generation)
            }
        }
    }

    private func resumeWake(_ generation: Int) {
        // Only resume the pause this sleeper belongs to, and only once.
        guard generation == wakeGeneration, let cont = wake else { return }
        wake = nil
        cont.resume()
    }

    private func emit(_ o: Output) {
        continuation.yield(o)
    }

    private func runOnce() async -> AttemptOutcome {
        guard let token = await tokenProvider(), !token.isEmpty else { return .authDead }
        let timeoutSeconds = Double(config.pingTimeout.components.seconds) + 30
        guard let req = Self.eventsRequest(baseURL: baseURL, token: token, timeout: timeoutSeconds) else {
            return .disabled
        }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch {
            return Task.isCancelled ? .cancelled : .failed(retryAfter: nil, gotHello: false)
        }
        guard let http = response as? HTTPURLResponse else { return .failed(retryAfter: nil, gotHello: false) }
        switch http.statusCode {
        case 200:
            let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            // An SPA fallback answering HTML for unknown routes means "no feed".
            guard type.contains("text/event-stream") else { return .disabled }
        case 401:
            return .authDead
        case 404, 405, 501:
            return .disabled
        case 429, 503:
            return .failed(retryAfter: Self.retryAfter(http), gotHello: false)
        default:
            return .failed(retryAfter: Self.retryAfter(http), gotHello: false)
        }
        return await read(bytes)
    }

    static func retryAfter(_ http: HTTPURLResponse) -> Double? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let s = Double(raw.trimmingCharacters(in: .whitespaces)) { return s }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: raw).map { max(0, $0.timeIntervalSinceNow) }
    }

    /// Read the stream until it ends, a terminal event arrives, or the
    /// ping watchdog fires.
    private func read(_ bytes: URLSession.AsyncBytes) async -> AttemptOutcome {
        let clock = ActivityClock()
        let cont = continuation
        let pingTimeout = config.pingTimeout
        let interval = config.watchdogInterval
        let sleeper = config.sleep
        return await withTaskGroup(of: AttemptOutcome?.self) { group in
            group.addTask {
                var parser = SSEParser()
                var gotHello = false
                var chunk: [UInt8] = []
                chunk.reserveCapacity(1024)
                do {
                    for try await byte in bytes {
                        chunk.append(byte)
                        guard byte == 0x0A || byte == 0x0D || chunk.count >= 4096 else { continue }
                        clock.touch()
                        let items = parser.feed(chunk)
                        chunk.removeAll(keepingCapacity: true)
                        for item in items {
                            guard case let .event(sse) = item else { continue }
                            guard let event = FeedEvent.decode(sse) else {
                                cont.yield(.problem("malformed \(sse.event) payload"))
                                continue
                            }
                            switch event {
                            case .hello:
                                if !gotHello { cont.yield(.state(.open)) }
                                clock.markHello()
                                gotHello = true
                                cont.yield(.event(event))
                            case .sessionEnded:
                                cont.yield(.event(event))
                                return .authDead
                            case .reconnect(let ms):
                                return .reconnect(afterMs: ms)
                            default:
                                cont.yield(.event(event))
                            }
                        }
                    }
                } catch {
                    if Task.isCancelled { return nil }
                }
                return .failed(retryAfter: nil, gotHello: gotHello)
            }
            group.addTask {
                // Ping watchdog: no bytes for `pingTimeout` → dead.
                while !Task.isCancelled {
                    try? await sleeper(interval)
                    if Task.isCancelled { return nil }
                    if clock.idle(longerThan: pingTimeout) {
                        cont.yield(.problem("no bytes for \(pingTimeout); reconnecting"))
                        return .failed(retryAfter: nil, gotHello: clock.helloSeen)
                    }
                }
                return nil
            }
            var result: AttemptOutcome = .cancelled
            for await r in group {
                if let r { result = r; break }
                if Task.isCancelled { break }
            }
            group.cancelAll()
            if Task.isCancelled { return .cancelled }
            return result
        }
    }
}

/// Monotonic last-activity stamp shared by the reader and the watchdog.
final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now
    private var hello = false

    func touch() {
        lock.lock(); last = .now; lock.unlock()
    }

    func idle(longerThan d: Duration) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ContinuousClock.now - last > d
    }

    func markHello() {
        lock.lock(); hello = true; lock.unlock()
    }

    var helloSeen: Bool {
        lock.lock(); defer { lock.unlock() }
        return hello
    }
}
