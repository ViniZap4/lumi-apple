import Foundation

// Hover link preview (SPEC-PARTE2 §4). Port of the web's
// `hover-preview.ts`: the timing (`HoverIntent`) and the excerpt the card
// renders. The card itself renders the excerpt through the shared prose
// renderer — never raw.

public enum HoverPreview {
    /// A link must be hovered this long before the card shows.
    public static let delay: TimeInterval = 0.35
    /// Leaving the link and the card hides it after this grace (so the
    /// pointer can travel from the link onto the card).
    public static let hideGrace: TimeInterval = 0.22
    public static let excerptLines = 40

    /// Strip a leading YAML frontmatter block.
    public static func stripFrontmatter(_ src: String) -> String {
        guard src.hasPrefix("---\n") || src.hasPrefix("---\r\n") else { return src }
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false)
        var offset = lines[0].count + 1
        for line in lines.dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            offset += line.count + 1
            if t == "---" || t == "..." {
                let idx = src.index(src.startIndex, offsetBy: min(offset, src.count))
                return String(src[idx...])
            }
        }
        return src
    }

    /// The first `lines` lines of a note body (frontmatter dropped,
    /// leading blank lines skipped). A fence left open at the cut is
    /// closed so the rest of the card does not turn into code.
    public static func excerpt(_ body: String, lines: Int = excerptLines) -> (text: String, truncated: Bool) {
        var text = stripFrontmatter(body)
        while let first = text.firstIndex(of: "\n"), text[..<first].allSatisfy({ $0.isWhitespace }) {
            text = String(text[text.index(after: first)...])
        }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        let truncated = all.count > lines
        var cut = all.prefix(lines).map(String.init)
        var fence: String?
        for l in cut {
            let trimmed = l.drop { $0 == " " }
            guard l.count - trimmed.count <= 3 else { continue }
            let marker: String
            if trimmed.hasPrefix("```") {
                marker = String(trimmed.prefix { $0 == "`" })
            } else if trimmed.hasPrefix("~~~") {
                marker = String(trimmed.prefix { $0 == "~" })
            } else { continue }
            if let f = fence {
                if marker.first == f.first, marker.count >= f.count { fence = nil }
            } else {
                fence = marker
            }
        }
        if let fence { cut.append(fence) }
        var out = cut.joined(separator: "\n")
        while out.last?.isWhitespace == true { out.removeLast() }
        return (out, truncated)
    }

    /// Relative "updated" label (`just now`, `5 min ago`, `3 days ago`,
    /// then the date).
    public static func updatedLabel(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = max(0, Int((now.timeIntervalSince(date)).rounded()))
        if s < 45 { return "just now" }
        let m = Int((Double(s) / 60).rounded())
        if m < 60 { return "\(m) min ago" }
        let h = Int((Double(m) / 60).rounded())
        if h < 24 { return "\(h) h ago" }
        let d = Int((Double(h) / 24).rounded())
        if d < 14 { return "\(d) \(d == 1 ? "day" : "days") ago" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

/// Injectable one-shot timers (tests drive them by hand).
@MainActor
public protocol HoverTimers {
    func schedule(_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> AnyObject
    func cancel(_ handle: AnyObject)
}

@MainActor
public final class MainQueueHoverTimers: HoverTimers {
    private final class Handle {
        var cancelled = false
    }

    public init() {}

    public func schedule(_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> AnyObject {
        let h = Handle()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if !h.cancelled { fire() }
        }
        return h
    }

    public func cancel(_ handle: AnyObject) {
        (handle as? Handle)?.cancelled = true
    }
}

/// Hover timing: show after `delay` on one link, keep while the pointer
/// is on the card, hide after `grace` once it left both.
@MainActor
public final class HoverIntent<Target> {
    private var showTimer: AnyObject?
    private var hideTimer: AnyObject?
    private var pendingKey: String?
    /// Key of the target whose card is showing.
    public private(set) var shownKey: String?

    private let onShow: (Target) -> Void
    private let onHide: () -> Void
    private let timers: HoverTimers
    private let delay: TimeInterval
    private let grace: TimeInterval

    public init(timers: HoverTimers = MainQueueHoverTimers(), delay: TimeInterval = HoverPreview.delay,
                grace: TimeInterval = HoverPreview.hideGrace,
                onShow: @escaping (Target) -> Void, onHide: @escaping () -> Void) {
        self.timers = timers
        self.delay = delay
        self.grace = grace
        self.onShow = onShow
        self.onHide = onHide
    }

    /// The pointer entered a link.
    public func enter(_ target: Target, key: String) {
        clearHide()
        if key == shownKey || key == pendingKey { return }
        clearShow()
        pendingKey = key
        showTimer = timers.schedule(delay) { [weak self] in
            guard let self else { return }
            self.showTimer = nil
            self.pendingKey = nil
            self.shownKey = key
            self.onShow(target)
        }
    }

    /// The pointer left the link (or the card).
    public func leave() {
        clearShow()
        pendingKey = nil
        guard shownKey != nil, hideTimer == nil else { return }
        hideTimer = timers.schedule(grace) { [weak self] in
            self?.hideTimer = nil
            self?.hide()
        }
    }

    /// The pointer is over the card: keep it.
    public func hold() { clearHide() }

    /// Shown without hovering (`K`): no delay.
    public func showNow(_ target: Target, key: String) {
        cancel()
        shownKey = key
        onShow(target)
    }

    public func hide() {
        cancel()
        if shownKey != nil {
            shownKey = nil
            onHide()
        }
    }

    /// Drop pending timers; the card state is unchanged.
    public func cancel() {
        clearShow()
        clearHide()
        pendingKey = nil
    }

    private func clearShow() {
        if let t = showTimer { timers.cancel(t) }
        showTimer = nil
    }

    private func clearHide() {
        if let t = hideTimer { timers.cancel(t) }
        hideTimer = nil
    }
}
