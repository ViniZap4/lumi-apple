import Foundation

/// Engine-side state that lives across input events. The text buffer is owned
/// by the caller (UI bridge) and threaded through `VimEngine.handle`, which
/// keeps the engine pure and testable.
public struct VimState: Sendable, Hashable {
    public var mode: VimMode

    /// Keys of the normal / visual command being typed (`"a2d3`, `g`,
    /// `ci`). Parsed afresh on every key by `VimEngine` (vim's own model):
    /// incomplete → wait, complete → execute, invalid → drop.
    public var pendingKeys: [VimInput]

    /// The most recent successful find/till. Used by `;` and `,`.
    public var lastFind: FindMemory?
    /// The most recent successful search. Used by `n` / `N`.
    public var lastSearch: SearchMemory?
    /// Cursor when `/` or `?` was typed (incsearch restarts from it and
    /// restores it on Esc; an operator's range is anchored on it).
    public var commandLineEntryCursor: Int?
    /// `:noh` hides search highlights without forgetting `lastSearch`.
    public var hlsearchSuspended: Bool
    /// Ex command history (`:`), oldest → newest.
    public var exHistory: [String]
    /// Search history (`/` and `?` share it).
    public var searchHistory: [String]
    /// Index into the active history while walking it with arrows.
    public var commandLineHistoryIndex: Int?
    /// The typed draft saved when the history walk started.
    public var commandLineHistoryDraft: String?
    /// After a search / ex line started from visual mode: the visual
    /// selection to return to (`v/foo<CR>` extends the selection).
    public var commandLineVisual: VisualSnapshot?

    /// Legacy `jj → <Esc>` toggle (merged into `escapeSequences`).
    public var jjEscapeEnabled: Bool
    /// Insert-mode key sequences that act as `<Esc>` (`jk`, `ff`, …).
    public var escapeSequences: [String]
    /// Seconds allowed between the keys of an escape sequence.
    public var escapeTimeout: TimeInterval
    /// Characters typed in a row that are a prefix of an escape sequence.
    public var insertEscapeRun: String
    /// `inputTime` of the last key in `insertEscapeRun`.
    public var insertEscapeRunAt: TimeInterval?
    /// Monotonic time of the input being handled (nil = no timing).
    public var inputTime: TimeInterval?

    /// The last yank, for the host's yank highlight (purely visual —
    /// nothing here touches the text). `seq` increments per yank.
    public var lastYank: VimYank?

    /// The unnamed register (`""`): the most recent yank/delete.
    public var defaultRegister: Register
    /// `"0`–`"9`, `"a`–`"z`, `"-`. Upper-case names append to lower-case.
    public var registers: [Character: Register]
    /// System clipboard contents, supplied by the host just before a
    /// command that reads `"+` / `"*` (see `VimEngine.wantsClipboard`).
    public var clipboard: String?
    /// Name of the open note, for the read-only `"%` register.
    public var fileName: String?

    /// Mark name → character offset. `a`–`z`, `A`–`Z`, and the automatic
    /// marks `'` (previous context), `[` `]` (last change/yank), `<` `>`
    /// (last visual), `.` (last change), `^` (last insert exit).
    public var marks: [Character: Int]

    /// Macros keyed by register name (typed inputs).
    public var macros: [Character: [VimInput]]
    /// Register being recorded into (after `q<reg>`).
    public var recordingMacro: Character?
    /// Inputs accumulated for the active recording.
    public var recordingMacroInputs: [VimInput]
    /// True while a macro is being played back.
    public var isPlayingMacro: Bool
    /// Depth of nested macro playback.
    public var macroDepth: Int
    /// Last invoked macro name (for `@@`).
    public var lastPlayedMacro: Character?
    /// Pending macro playback steps (stack; next step is the last).
    var macroSteps: [MacroStep] = []

    enum MacroStep: Sendable, Hashable {
        case input(VimInput)
        case end
    }

    public var history: VimHistory

    /// Most recent committed sequence of inputs that changed the buffer.
    /// Replayed by `.`.
    public var lastChange: [VimInput]?
    /// Inputs of the command sequence in flight (dot-repeat recording).
    public var recordingInputs: [VimInput]
    /// Buffer text when the in-flight sequence started.
    public var recordingBaseline: String?
    /// True while a `.` replay is in progress.
    public var isReplaying: Bool

    /// Column `j`/`k` aim for (vim's `curswant`); `Int.max` after `$`.
    public var desiredColumn: Int?
    /// The insert / replace session in progress.
    public var insertSession: InsertSession?
    /// Ctrl-O in insert mode: 1 = waiting for the one command, 2 = it is
    /// being typed. Insert resumes when it completes.
    public var insertOneShot: Int
    /// Insert mode after Ctrl-R / Ctrl-R in the command line: the next
    /// key names the register to insert.
    public var awaitingInsertRegister: Bool
    /// The text typed by the last insert session (`".`, Ctrl-A).
    public var lastInsertedText: String
    /// Last executed ex command line (`":`, `@:`).
    public var lastExCommand: String?
    /// The previous visual selection (`gv`, `'<`, `'>`).
    public var lastVisual: VisualSnapshot?
    /// Block visual with `$`: every line extends to its end.
    public var blockToLineEnd: Bool

    /// Settings (`:set`, `.vimrc`).
    public var options: VimOptions
    /// Key mappings (`:map` family, `.vimrc`).
    public var mappings: [VimMapping]
    /// The mapping leader as key notation (`\`, `,`, `<Space>`).
    public var leader: String
    /// Typed keys that are a prefix of some mapping's left-hand side.
    public var mapPending: [VimInput]
    /// `inputTime` when `mapPending` last grew.
    public var mapPendingAt: TimeInterval?
    /// Insert-mode mapping keys already typed into the buffer while the
    /// mapping could still complete (`jj`): removed when it does.
    public var mapTentative: Int

    /// Last `:s` (for `&`, `:&&`, `:s` with no pattern).
    public var lastSubstitute: SubstituteMemory?
    /// `:s///c` interactive confirmation in progress.
    public var substituteConfirm: SubstituteConfirm?
    /// Visible lines reported by the host (for `H` `M` `L` and page keys).
    public var viewport: VimViewport?
    /// Message for the command-line area; cleared by the next key.
    public var message: VimMessage?
    /// Offsets the engine is tracking through its own edits (`:g`,
    /// `:normal` over a range). nil = the tracked line was deleted.
    var trackedOffsets: [Int?] = []
    /// The operator / count a `/` or `?` search was started with.
    var searchContext: SearchContext?

    public init(
        mode: VimMode = .normal,
        lastFind: FindMemory? = nil,
        lastSearch: SearchMemory? = nil,
        exHistory: [String] = [],
        searchHistory: [String] = [],
        jjEscapeEnabled: Bool = false,
        escapeSequences: [String] = [],
        escapeTimeout: TimeInterval = 0.2,
        defaultRegister: Register = Register(),
        registers: [Character: Register] = [:],
        marks: [Character: Int] = [:],
        macros: [Character: [VimInput]] = [:],
        history: VimHistory = VimHistory(),
        lastChange: [VimInput]? = nil,
        options: VimOptions = VimOptions()
    ) {
        self.mode = mode
        self.pendingKeys = []
        self.lastFind = lastFind
        self.lastSearch = lastSearch
        self.commandLineEntryCursor = nil
        self.hlsearchSuspended = false
        self.exHistory = exHistory
        self.searchHistory = searchHistory
        self.commandLineHistoryIndex = nil
        self.commandLineHistoryDraft = nil
        self.commandLineVisual = nil
        self.jjEscapeEnabled = jjEscapeEnabled
        self.escapeSequences = escapeSequences
        self.escapeTimeout = escapeTimeout
        self.insertEscapeRun = ""
        self.insertEscapeRunAt = nil
        self.inputTime = nil
        self.defaultRegister = defaultRegister
        self.registers = registers
        self.clipboard = nil
        self.fileName = nil
        self.marks = marks
        self.macros = macros
        self.recordingMacro = nil
        self.recordingMacroInputs = []
        self.isPlayingMacro = false
        self.macroDepth = 0
        self.lastPlayedMacro = nil
        self.history = history
        self.lastChange = lastChange
        self.recordingInputs = []
        self.recordingBaseline = nil
        self.isReplaying = false
        self.desiredColumn = nil
        self.insertSession = mode.isTyping ? InsertSession(start: 0, count: 1, kind: .plain) : nil
        self.insertOneShot = 0
        self.awaitingInsertRegister = false
        self.lastInsertedText = ""
        self.lastExCommand = nil
        self.lastVisual = nil
        self.blockToLineEnd = false
        self.options = options
        self.mappings = []
        self.leader = "\\"
        self.mapPending = []
        self.mapPendingAt = nil
        self.mapTentative = 0
        self.lastSubstitute = nil
        self.substituteConfirm = nil
        self.viewport = nil
        self.message = nil
    }

    public static let initial = VimState()

    /// Cap on entries kept per command-line history ring.
    public static let commandLineHistoryLimit = 50

    // MARK: Pending-command views (derived from `pendingKeys`)

    /// What the pending keys are waiting for (operator, register, …).
    public var pending: VimPendingInfo { VimEngine.pendingInfo(self) }

    /// Count typed so far for the pending command.
    public var pendingCount: Int? { pending.count }
    /// Operator waiting for its motion (operator-pending mode).
    public var pendingOperator: PendingOperator? {
        pending.op.map { PendingOperator(op: $0, count: pending.count ?? 1) }
    }
    /// Register named with `"x` for the pending command.
    public var pendingRegister: Character? { pending.register }
    /// True right after `"` (the next key names a register).
    public var awaitingRegisterChar: Bool { pending.awaiting == .register }
    /// True right after `m` (the next key names a mark).
    public var awaitingMarkSet: Bool { pending.awaiting == .markSet }
    /// Effective count for the pending command: `pendingCount ?? 1`.
    public var effectiveCount: Int { pendingCount ?? 1 }
}

/// What a pending `/` / `?` search applies to once confirmed.
struct SearchContext: Sendable, Hashable {
    var op: VimOperator?
    var register: Character?
    var count: Int?
}

/// An operator captured while waiting for its motion.
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

/// A vim register: text plus how it was captured.
public struct Register: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case characterwise
        /// Whole lines; `text` ends with `\n`.
        case linewise
        /// A rectangle; `text` holds its rows separated by `\n`.
        case blockwise
    }

    public var text: String
    public var kind: Kind

    public init(text: String = "", kind: Kind = .characterwise) {
        self.text = text
        self.kind = kind
    }
}

/// A visual selection to restore (`gv`).
public struct VisualSnapshot: Sendable, Hashable {
    public var kind: VimMode.VisualKind
    public var anchor: Int
    public var head: Int
    public var toLineEnd: Bool

    public init(kind: VimMode.VisualKind, anchor: Int, head: Int, toLineEnd: Bool = false) {
        self.kind = kind
        self.anchor = anchor
        self.head = head
        self.toLineEnd = toLineEnd
    }
}

/// An insert (or replace) session: where it began and what to do on Esc.
public struct InsertSession: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case plain
        /// `o` / `O`: a count repeats the typed text on new lines.
        case openLine(below: Bool)
        /// Visual-block `I` / `A` / `c`: on Esc the typed text is copied
        /// to lines `firstLine+1 … lastLine` at `column` (`toLineEnd`:
        /// at each line's end; `pad`: short lines are padded).
        case block(firstLine: Int, lastLine: Int, column: Int, toLineEnd: Bool, pad: Bool)
    }

    public var start: Int
    public var count: Int
    public var kind: Kind
    /// Text typed so far (what `".` will hold).
    public var typed: String = ""
    /// Inputs typed in this session (for the count repeat on Esc).
    public var inputs: [VimInput] = []
    /// Replace mode: the characters overwritten, for backspace.
    public var replaced: [Character?] = []

    public init(start: Int, count: Int, kind: Kind) {
        self.start = start
        self.count = count
        self.kind = kind
    }
}

/// `:set` options (and the `.vimrc` subset).
public struct VimOptions: Sendable, Hashable {
    public var tabstop: Int = 4
    public var shiftwidth: Int = 4
    public var expandtab: Bool = true
    public var ignorecase: Bool = true
    public var smartcase: Bool = true
    public var hlsearch: Bool = true
    public var incsearch: Bool = true
    /// Copy the indent of the current line when starting a new one.
    public var autoindent: Bool = true
    /// View options: nil follows the app preference.
    public var number: Bool?
    public var relativenumber: Bool?
    public var wrap: Bool?
    /// Milliseconds to wait for a mapping to complete.
    public var timeoutlen: Int = 1000

    public init() {}

    /// One indent level as text.
    var indentUnit: String {
        expandtab ? String(repeating: " ", count: max(1, shiftwidth)) : "\t"
    }
}

/// One key mapping. `lhs` / `rhs` are engine inputs.
public struct VimMapping: Sendable, Hashable {
    public enum Mode: Sendable, Hashable { case all, normal, insert, visual, operatorPending }
    public var mode: Mode
    public var lhs: [VimInput]
    public var rhs: [VimInput]
    public var noremap: Bool
    /// Ex alias (`map :W :write`): the command name without `:`.
    public var exAlias: String?

    public init(mode: Mode, lhs: [VimInput], rhs: [VimInput], noremap: Bool, exAlias: String? = nil) {
        self.mode = mode
        self.lhs = lhs
        self.rhs = rhs
        self.noremap = noremap
        self.exAlias = exAlias
    }

    func applies(in mode: Mode) -> Bool {
        self.mode == mode || (self.mode == .all && mode != .insert)
    }
}

/// Visible line range (0-based, inclusive), reported by the host.
public struct VimViewport: Sendable, Hashable {
    public var firstLine: Int
    public var lastLine: Int

    public init(firstLine: Int, lastLine: Int) {
        self.firstLine = firstLine
        self.lastLine = max(firstLine, lastLine)
    }

    public var height: Int { lastLine - firstLine + 1 }
}

public struct SubstituteMemory: Sendable, Hashable {
    public var pattern: String
    public var replacement: String
    public var flags: String
}

/// State of a `:s///c` session.
public struct SubstituteConfirm: Sendable, Hashable {
    public var pattern: String
    public var replacement: String
    public var global: Bool
    public var caseFlag: Character?
    /// Character offset where the next match search starts.
    public var searchFrom: Int
    /// Index into `VimState.trackedOffsets` of the range end (line end).
    public var limitIndex: Int
    /// The match being asked about (character range).
    public var current: Range<Int>?
    public var replacedCount: Int = 0
    public var lastLine: Int = -1
}

/// What the keys typed so far are waiting for — drives the legend's
/// which-key completions and the cursor shape.
public struct VimPendingInfo: Sendable, Hashable {
    public enum Awaiting: Sendable, Hashable {
        case none
        case register
        case markSet
        case markJump
        case findChar
        case replaceChar
        case textObject
        case gPrefix
        case zPrefix
        case bigZPrefix
        case bracket
        case macroRecord
        case macroPlay
        case motion
        case mapping
    }

    public var count: Int?
    public var register: Character?
    public var op: VimOperator?
    public var awaiting: Awaiting
    /// Keys typed, for display (`"a2d`, `g`, `<Space>`).
    public var display: String

    public init(count: Int? = nil, register: Character? = nil, op: VimOperator? = nil, awaiting: Awaiting = .none, display: String = "") {
        self.count = count
        self.register = register
        self.op = op
        self.awaiting = awaiting
        self.display = display
    }

    public var isEmpty: Bool { display.isEmpty }
}

/// One yank, as character-offset spans (one per line for a block yank).
public struct VimYank: Sendable, Hashable {
    public var seq: Int
    public var spans: [Range<Int>]

    public init(seq: Int, spans: [Range<Int>]) {
        self.seq = seq
        self.spans = spans
    }
}
