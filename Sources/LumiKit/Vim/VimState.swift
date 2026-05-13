import Foundation

/// Engine-side state that lives across input events. The text buffer is owned
/// by the caller (UI bridge) and threaded through `VimEngine.handle`, which
/// keeps the engine pure and testable.
public struct VimState: Sendable, Hashable {
    public var mode: VimMode
    public var pendingCount: Int?
    public var pendingOperator: PendingOperator?
    /// After `i` or `a` in operator-pending or visual mode: which kind of text
    /// object the user is about to specify. Cleared once the object selector
    /// (`w`, `"`, `(`, …) arrives.
    public var pendingTextObjectKind: TextObjectKind?
    /// After `f F t T` (in any mode): which find variant we're awaiting a
    /// target character for.
    public var pendingFindKind: FindKind?
    /// The most recent successful find/till. Used by `;` (repeat) and `,`
    /// (reverse-repeat).
    public var lastFind: FindMemory?
    /// The most recent successful search. Used by `n` (repeat) and `N`
    /// (reverse-repeat), and by `/<CR>` / `?<CR>` empty-pattern reuse.
    public var lastSearch: SearchMemory?
    /// Snapshot of `buffer.cursor` taken when entering command-line mode via
    /// `/` or `?` (search). Used by incsearch to (a) restart each preview
    /// search from the original position, (b) restore the cursor on ESC, and
    /// (c) anchor the operator range on `<CR>` when an operator is pending —
    /// otherwise the live-preview cursor movement would collapse the range.
    /// Not set for `:` ex commands (they don't preview).
    public var commandLineEntryCursor: Int?
    /// Toggled true by `:noh` (no-highlight). When set, hlsearch hides all
    /// match decorations without forgetting `lastSearch` — so `n`/`N` keep
    /// working. Any successful search clears the flag back to false.
    public var hlsearchSuspended: Bool
    /// Ex command history (`:` only). Oldest→newest; bounded by
    /// `VimState.commandLineHistoryLimit`. Appended on `<CR>`; skips empty
    /// and duplicates of the most-recent entry.
    public var exHistory: [String]
    /// Search history (`/` and `?` share). Same shape as `exHistory`.
    public var searchHistory: [String]
    /// While the user is walking command-line history with arrow keys, the
    /// index into the active history (`exHistory` for `:`, `searchHistory`
    /// for `/` `?`). `nil` means not walking — typing or `<CR>` clears it.
    public var commandLineHistoryIndex: Int?
    /// Saved buffer at the moment the user first pressed up-arrow during a
    /// command-line session. Restored when arrow-down walks past the newest
    /// entry. `nil` once navigation ends.
    public var commandLineHistoryDraft: String?
    /// Default ("unnamed") register — receives the most recent yank/delete.
    public var defaultRegister: Register
    /// Named registers (`"a` … `"z`, `"A` … `"Z`). Yank/delete writes here in
    /// addition to the default register; paste reads from here when prefixed.
    public var registers: [Character: Register]
    /// Set after `"<letter>`. Consumed by the next register-using operator.
    public var pendingRegister: Character?
    /// Set after `"` itself. The next character is interpreted as the
    /// register name.
    public var awaitingRegisterChar: Bool

    /// Mark name → cursor offset. Mirrors vim's per-file marks (a-z, A-Z).
    public var marks: [Character: Int]
    /// Set after `m`. Next character names the mark to set.
    public var awaitingMarkSet: Bool
    /// Set after `'`. Next character names the mark to jump to (line).
    public var awaitingMarkJumpLine: Bool
    /// Set after `` ` ``. Next character names the mark to jump to (exact).
    public var awaitingMarkJumpExact: Bool
    /// Set after first `g`. The next `g` resolves to fileStart motion (`gg`).
    public var awaitingGG: Bool

    /// Macros keyed by register name. Distinct from text registers because
    /// they hold a typed sequence of `VimInput`, not a string.
    public var macros: [Character: [VimInput]]
    /// Register being recorded into (set after `q<letter>`). Nil when not
    /// recording. While set, the engine wrapper appends every input.
    public var recordingMacro: Character?
    /// Inputs accumulated for the active macro recording.
    public var recordingMacroInputs: [VimInput]
    /// Set after a bare `q` press (no active recording). The next letter
    /// becomes the register name and recording starts.
    public var awaitingMacroRegister: Bool
    /// Set after `@`. The next char is the register to play (or `@` for
    /// repeat-last-played).
    public var awaitingMacroPlay: Bool
    /// True while a macro is being played back. Suppresses re-recording into
    /// any active outer macro and skips re-capturing as the played inputs.
    public var isPlayingMacro: Bool
    /// Depth of nested macro playback. Guards against runaway recursion.
    public var macroDepth: Int
    /// Last successfully invoked macro name. Used by `@@`.
    public var lastPlayedMacro: Character?

    public var history: VimHistory

    /// Most recent committed sequence of inputs that produced a buffer
    /// modification. Replayed by `.` (dot-repeat).
    public var lastChange: [VimInput]?
    /// Inputs accumulated for the current command sequence. The recording
    /// wrapper inside `VimEngine.handle` manages this — engine handlers
    /// usually don't touch it. Meta-commands (undo, redo, dot itself) clear
    /// it so they're not captured as changes.
    public var recordingInputs: [VimInput]
    /// `buffer.text` snapshot taken when recording started. Used to decide
    /// whether the sequence actually modified anything.
    public var recordingBaseline: String?
    /// Set to `true` while a `.` replay is in progress. The wrapper bypasses
    /// recording while this is on, so the replay doesn't clobber `lastChange`.
    public var isReplaying: Bool

    public init(
        mode: VimMode = .normal,
        pendingCount: Int? = nil,
        pendingOperator: PendingOperator? = nil,
        pendingTextObjectKind: TextObjectKind? = nil,
        pendingFindKind: FindKind? = nil,
        lastFind: FindMemory? = nil,
        lastSearch: SearchMemory? = nil,
        commandLineEntryCursor: Int? = nil,
        hlsearchSuspended: Bool = false,
        exHistory: [String] = [],
        searchHistory: [String] = [],
        commandLineHistoryIndex: Int? = nil,
        commandLineHistoryDraft: String? = nil,
        defaultRegister: Register = Register(),
        registers: [Character: Register] = [:],
        pendingRegister: Character? = nil,
        awaitingRegisterChar: Bool = false,
        marks: [Character: Int] = [:],
        awaitingMarkSet: Bool = false,
        awaitingMarkJumpLine: Bool = false,
        awaitingMarkJumpExact: Bool = false,
        awaitingGG: Bool = false,
        macros: [Character: [VimInput]] = [:],
        recordingMacro: Character? = nil,
        recordingMacroInputs: [VimInput] = [],
        awaitingMacroRegister: Bool = false,
        awaitingMacroPlay: Bool = false,
        isPlayingMacro: Bool = false,
        macroDepth: Int = 0,
        lastPlayedMacro: Character? = nil,
        history: VimHistory = VimHistory(),
        lastChange: [VimInput]? = nil,
        recordingInputs: [VimInput] = [],
        recordingBaseline: String? = nil,
        isReplaying: Bool = false
    ) {
        self.mode = mode
        self.pendingCount = pendingCount
        self.pendingOperator = pendingOperator
        self.pendingTextObjectKind = pendingTextObjectKind
        self.pendingFindKind = pendingFindKind
        self.lastFind = lastFind
        self.lastSearch = lastSearch
        self.commandLineEntryCursor = commandLineEntryCursor
        self.hlsearchSuspended = hlsearchSuspended
        self.exHistory = exHistory
        self.searchHistory = searchHistory
        self.commandLineHistoryIndex = commandLineHistoryIndex
        self.commandLineHistoryDraft = commandLineHistoryDraft
        self.defaultRegister = defaultRegister
        self.registers = registers
        self.pendingRegister = pendingRegister
        self.awaitingRegisterChar = awaitingRegisterChar
        self.marks = marks
        self.awaitingMarkSet = awaitingMarkSet
        self.awaitingMarkJumpLine = awaitingMarkJumpLine
        self.awaitingMarkJumpExact = awaitingMarkJumpExact
        self.awaitingGG = awaitingGG
        self.macros = macros
        self.recordingMacro = recordingMacro
        self.recordingMacroInputs = recordingMacroInputs
        self.awaitingMacroRegister = awaitingMacroRegister
        self.awaitingMacroPlay = awaitingMacroPlay
        self.isPlayingMacro = isPlayingMacro
        self.macroDepth = macroDepth
        self.lastPlayedMacro = lastPlayedMacro
        self.history = history
        self.lastChange = lastChange
        self.recordingInputs = recordingInputs
        self.recordingBaseline = recordingBaseline
        self.isReplaying = isReplaying
    }

    public static let initial = VimState()

    /// Cap on entries kept per command-line history ring. Old entries are
    /// dropped from the front when this is exceeded.
    public static let commandLineHistoryLimit = 50

    /// Effective count for the next motion/operator: `pendingCount ?? 1`.
    public var effectiveCount: Int { pendingCount ?? 1 }
}

/// An operator captured while waiting for its motion (or its repeat key like
/// `dd`).
public struct PendingOperator: Sendable, Hashable {
    public let op: VimOperator
    public let count: Int

    public init(op: VimOperator, count: Int = 1) {
        self.op = op
        self.count = count
    }
}

/// Memory of the most recent f/F/t/T target. Used by `;` and `,`.
public struct FindMemory: Sendable, Hashable {
    public let kind: FindKind
    public let target: Character

    public init(kind: FindKind, target: Character) {
        self.kind = kind
        self.target = target
    }
}

/// A vim register holds yanked / deleted text plus a hint about its kind.
public struct Register: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case characterwise
        case linewise
    }

    public var text: String
    public var kind: Kind

    public init(text: String = "", kind: Kind = .characterwise) {
        self.text = text
        self.kind = kind
    }
}
