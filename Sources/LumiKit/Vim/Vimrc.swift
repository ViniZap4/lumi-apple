import Foundation

/// A safe `.vimrc` subset — a line-for-line port of the web client's
/// `vimrc.ts` (same grammar, same diagnostics, same limits).
///
/// The text is PARSED, never evaluated: every line is matched against a
/// small grammar and turned into data (key mappings, a leader, a few `set`
/// options). Anything outside the grammar is reported per line — as an
/// error (malformed), a warning (understood but not supported here) or an
/// info (accepted, nothing to do) — and otherwise ignored. No line can run
/// code, load a file or reach the network.
///
/// Supported:
///   " comments, blank lines, a leading `:` on any line
///   map nmap imap vmap xmap  noremap nnoremap inoremap vnoremap xnoremap
///   unmap nunmap iunmap vunmap xunmap   (removes a mapping defined above)
///   <silent> <nowait> <unique> <buffer> map arguments (ignored)
///   let mapleader = ","   let maplocalleader = " "   ("\<Space>" too)
///   set number relativenumber wrap expandtab (no… forms), tabstop=N,
///       shiftwidth=N, softtabstop=N (accepted), ignorecase smartcase
///       hlsearch incsearch (always on)
///   syntax / filetype / colorscheme / nocompatible lines (ignored)
public enum Vimrc {
    public static let maxBytes = 16 * 1024
    public static let maxMaps = 200
    public static let maxLhsLength = 48
    public static let maxRhsLength = 256
    public static let defaultLeader = "\\"

    public static let example = """
    " lumi vimrc — a safe subset, parsed (never executed)
    let mapleader = " "

    " leave insert mode with jj
    inoremap jj <Esc>

    " move by display lines
    nnoremap j gj
    nnoremap k gk

    " <leader>w saves
    nnoremap <leader>w :w<CR>

    set relativenumber
    set tabstop=2 shiftwidth=2 expandtab

    """

    // MARK: Tables

    private static let mapCommands: [String: (VimrcMap.Mode, Bool)] = [
        "map": (.all, false), "nmap": (.normal, false), "nm": (.normal, false),
        "imap": (.insert, false), "im": (.insert, false), "vmap": (.visual, false), "vm": (.visual, false),
        "xmap": (.visual, false), "xm": (.visual, false),
        "noremap": (.all, true), "no": (.all, true), "nnoremap": (.normal, true), "nn": (.normal, true),
        "inoremap": (.insert, true), "ino": (.insert, true), "vnoremap": (.visual, true), "vn": (.visual, true),
        "xnoremap": (.visual, true), "xn": (.visual, true),
    ]

    private static let unmapCommands: [String: VimrcMap.Mode] = [
        "unmap": .all, "unm": .all, "nunmap": .normal, "nun": .normal, "iunmap": .insert, "iu": .insert,
        "vunmap": .visual, "vu": .visual, "xunmap": .visual, "xu": .visual,
    ]

    private static let ignoredCommands: Set<String> = ["syntax", "syn", "filetype", "filet", "colorscheme", "colo", "set nocompatible"]
    private static let scriptCommands: Set<String> = [
        "source", "so", "runtime", "ru", "function", "fu", "function!", "endfunction", "endf", "call", "cal",
        "execute", "exe", "autocmd", "au", "augroup", "aug", "command", "command!", "com", "if", "endif", "else",
        "for", "endfor", "while", "endwhile", "lua", "python", "py", "python3", "py3", "ruby", "perl", "normal", "norm",
        "normal!", "norm!", "silent", "sil", "silent!", "packadd", "Plug", "plug#begin", "call plug#begin",
    ]
    private static let mapFlags: Set<String> = ["<silent>", "<nowait>", "<unique>", "<buffer>", "<special>", "<script>"]

    private static let keyNames: [String: String] = [
        "cr": "CR", "enter": "CR", "return": "CR",
        "esc": "Esc", "escape": "Esc",
        "space": "Space",
        "tab": "Tab",
        "bs": "BS", "backspace": "BS",
        "del": "Del", "delete": "Del",
        "up": "Up", "down": "Down", "left": "Left", "right": "Right",
        "home": "Home", "end": "End",
        "pageup": "PageUp", "pagedown": "PageDown",
        "ins": "Ins", "insert": "Ins",
        "lt": "lt",
    ]
    private static let literalNames: [String: String] = ["bar": "|", "bslash": "\\"]

    private static let boolOpts: [String: String] = [
        "number": "number", "nu": "number",
        "relativenumber": "relativenumber", "rnu": "relativenumber",
        "wrap": "wrap",
        "expandtab": "expandtab", "et": "expandtab",
        "ignorecase": "ignorecase", "ic": "ignorecase",
        "smartcase": "smartcase", "scs": "smartcase",
        "hlsearch": "hlsearch", "hls": "hlsearch",
        "incsearch": "incsearch", "is": "incsearch",
    ]
    private static let alwaysOn: Set<String> = ["ignorecase", "smartcase", "hlsearch", "incsearch"]
    private static let numOpts: [String: String] = [
        "tabstop": "tabstop", "ts": "tabstop",
        "shiftwidth": "shiftwidth", "sw": "shiftwidth",
        "softtabstop": "softtabstop", "sts": "softtabstop",
    ]
    private static let ignoredOpts: Set<String> = [
        "nocompatible", "compatible", "cp", "nocp", "encoding", "enc", "fileencoding", "fenc", "syntax",
        "background", "bg", "termguicolors", "tgc", "mouse",
    ]

    // MARK: Key notation

    public struct KeyNormResult: Equatable, Sendable {
        public var keys: String
        public var error: String?
    }

    /// Normalise vim key notation (`<cr>` → `<CR>`, `<c-D>` → `<C-d>`),
    /// expanding `<leader>` / `<localleader>`. Unknown `<…>` names are
    /// errors; a lone `<` that does not start a key name stays literal.
    public static func normalizeKeys(_ raw: String, leader: String = defaultLeader, localLeader: String? = nil) -> KeyNormResult {
        let localLeader = localLeader ?? leader
        let chars = Array(raw)
        var out = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "<", let close = chars[(i + 1)...].firstIndex(of: ">") {
                let body = String(chars[(i + 1)..<close])
                if !body.isEmpty, body.count <= 16, body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
                    let lower = body.lowercased()
                    if lower == "leader" {
                        out += leader
                    } else if lower == "localleader" {
                        out += localLeader
                    } else if let lit = literalNames[lower] {
                        out += lit
                    } else if let named = normalizeNamedKey(body) {
                        out += named
                    } else {
                        return KeyNormResult(keys: out, error: "unknown key <\(body)>")
                    }
                    i = close + 1
                    continue
                }
            }
            out.append(ch)
            i += 1
        }
        return KeyNormResult(keys: out, error: nil)
    }

    private static func normalizeNamedKey(_ body: String) -> String? {
        var parts = body.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        var keyPart = parts.popLast() ?? ""
        if keyPart.isEmpty {
            // `<C-->`: the key is '-'.
            guard body.hasSuffix("--") else { return nil }
            _ = parts.popLast()
            keyPart = "-"
        }
        var mods: [String] = []
        for p in parts {
            switch p.lowercased() {
            case "c": mods.append("C")
            case "s": mods.append("S")
            case "a": mods.append("A")
            case "m", "d": mods.append("M")
            default: return nil
            }
        }
        let lower = keyPart.lowercased()
        let key: String
        if let k = keyNames[lower] {
            key = k
        } else if lower.count >= 2, lower.first == "f", let n = Int(lower.dropFirst()), (1...12).contains(n), !lower.dropFirst().hasPrefix("0") {
            key = lower.uppercased()
        } else if keyPart.count == 1 {
            if mods.isEmpty { return nil }
            key = mods.contains("S") ? keyPart : keyPart.lowercased()
        } else {
            return nil
        }
        if key == "lt", !mods.isEmpty { return nil }
        let sorted = ["C", "A", "M", "S"].filter { mods.contains($0) }
        return "<" + sorted.map { $0 + "-" }.joined() + key + ">"
    }

    /// Parse a `let mapleader = …` value into key notation, or nil.
    public static func parseLeaderValue(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespaces)
        var s: String
        if let m = firstMatch(#"^"((?:[^"\\]|\\.)*)"$"#, v), let inner = m[1] {
            s = replace(#"\\<space>"#, in: inner, with: " ", caseInsensitive: true)
            s = replace(#"\\<([^>]+)>"#, in: s, with: "<$1>")
            s = replace(#"\\(.)"#, in: s, with: "$1")
        } else if let m = firstMatch(#"^'((?:[^']|'')*)'$"#, v), let inner = m[1] {
            s = inner.replacingOccurrences(of: "''", with: "'")
        } else {
            return nil
        }
        if s == " " { return "<Space>" }
        if firstMatch(#"^<[^>]+>$"#, s) != nil {
            let n = normalizeKeys(s)
            return n.error == nil ? n.keys : nil
        }
        guard s.unicodeScalars.count == 1, let u = s.unicodeScalars.first, u.value >= 0x20, u.value != 0x7f else { return nil }
        return s
    }

    // MARK: Parse

    public static func parse(_ text: String, leader initialLeader: String = defaultLeader) -> ParsedVimrc {
        var out = ParsedVimrc(maps: [], options: VimrcOptions(), leader: initialLeader, diagnostics: [])
        var localLeader = initialLeader
        func diag(_ line: Int, _ severity: VimrcDiagnostic.Severity, _ message: String) {
            out.diagnostics.append(VimrcDiagnostic(line: line, severity: severity, message: message))
        }

        var src = text
        if src.utf8.count > maxBytes {
            diag(1, .error, "vimrc is larger than \(maxBytes / 1024) KB; only the first \(maxBytes / 1024) KB are read")
            src = String(src.prefix(maxBytes))
        }
        let lines = src.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }

        for (idx, rawLine) in lines.enumerated() {
            let n = idx + 1
            var line = rawLine.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("\"") { continue }
            if line.unicodeScalars.contains(where: { ($0.value <= 0x08) || (0x0b...0x1f).contains($0.value) || $0.value == 0x7f }) {
                diag(n, .error, "control characters are not allowed")
                continue
            }
            line = replace(#"^:+\s*"#, in: line, with: "")
            if line.isEmpty { continue }
            if line.hasPrefix("\\") {
                diag(n, .error, "line continuations (\\) are not supported")
                continue
            }
            guard let m = firstMatch(#"^(\S+)\s*(.*)$"#, line), let cmd = m[1] else { continue }
            let rest = m[2] ?? ""

            if let (mode, noremap) = mapCommands[cmd] {
                if out.maps.count >= maxMaps {
                    diag(n, .error, "more than \(maxMaps) mappings; ignored")
                    continue
                }
                var args = rest
                var bad = false
                while let fm = firstMatch(#"^(<[a-z]+>)\s*"#, args, caseInsensitive: true), let flag = fm[0], let f = fm[1]?.lowercased() {
                    if f == "<expr>" {
                        diag(n, .error, "<expr> mappings evaluate code and are not supported")
                        bad = true
                        break
                    }
                    if !mapFlags.contains(f) { break }
                    args = String(args.dropFirst(flag.count))
                }
                if bad { continue }
                guard let parts = firstMatch(#"^(\S+)\s+(.+)$"#, args), let lhsRaw = parts[1], let rhsRaw = parts[2] else {
                    diag(n, .error, args.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "\(cmd): listing mappings is not supported here"
                         : "\(cmd): missing right-hand side")
                    continue
                }
                let leaderPrefixed = lhsRaw.lowercased().hasPrefix("<leader>") && mode != .insert
                let lhsN = normalizeKeys(leaderPrefixed ? String(lhsRaw.dropFirst(8)) : lhsRaw, leader: out.leader, localLeader: localLeader)
                let rhsN = normalizeKeys(rhsRaw.trimmingCharacters(in: .whitespaces), leader: out.leader, localLeader: localLeader)
                if let e = lhsN.error ?? rhsN.error {
                    diag(n, .error, e)
                    continue
                }
                if (lhsN.keys.isEmpty && !leaderPrefixed) || rhsN.keys.isEmpty {
                    diag(n, .error, "\(cmd): empty key")
                    continue
                }
                if lhsN.keys.utf16.count > maxLhsLength || rhsN.keys.utf16.count > maxRhsLength {
                    diag(n, .error, "mapping too long (max \(maxLhsLength) keys left, \(maxRhsLength) right)")
                    continue
                }
                if lhsN.keys.hasPrefix(":"), lhsN.keys != ":" {
                    if mode != .all {
                        diag(n, .error, "ex-command aliases (:Name) need plain map/noremap, not a mode-specific map")
                        continue
                    }
                    if firstMatch(#"^:[A-Za-z][A-Za-z0-9]*$"#, lhsN.keys) == nil {
                        diag(n, .error, "ex-command alias must be a word, e.g. map :W :write")
                        continue
                    }
                }
                out.maps.removeAll { $0.lhs == lhsN.keys && $0.mode == mode && $0.leader == leaderPrefixed }
                out.maps.append(VimrcMap(mode: mode, lhs: lhsN.keys, rhs: rhsN.keys, noremap: noremap, line: n, leader: leaderPrefixed))
                continue
            }

            if let mode = unmapCommands[cmd] {
                let arg = replace(#"^(<(silent|buffer|nowait)>\s*)+"#, in: rest, with: "", caseInsensitive: true)
                    .trimmingCharacters(in: .whitespaces)
                if arg.isEmpty {
                    diag(n, .error, "\(cmd): missing key")
                    continue
                }
                let leaderPrefixed = arg.lowercased().hasPrefix("<leader>")
                let lhsN = normalizeKeys(leaderPrefixed ? String(arg.dropFirst(8)) : arg, leader: out.leader, localLeader: localLeader)
                if let e = lhsN.error {
                    diag(n, .error, e)
                    continue
                }
                let before = out.maps.count
                out.maps.removeAll {
                    $0.lhs == lhsN.keys && $0.leader == leaderPrefixed && (mode == .all || $0.mode == mode || $0.mode == .all)
                }
                if out.maps.count == before {
                    diag(n, .warning, "no mapping of \(lhsN.keys) above; built-in keys cannot be removed")
                }
                continue
            }

            if cmd == "let" {
                guard let lm = firstMatch(#"^(g:)?(mapleader|maplocalleader)\s*=\s*(.+)$"#, stripTrailingComment(rest).trimmingCharacters(in: .whitespaces)),
                      let which = lm[2], let value = lm[3] else {
                    diag(n, .warning, "only `let mapleader` / `let maplocalleader` are supported (variables are never evaluated)")
                    continue
                }
                guard let v = parseLeaderValue(value) else {
                    diag(n, .error, "\(which) must be one quoted key, e.g. \" \" or \",\"")
                    continue
                }
                if which == "mapleader" { out.leader = v } else { localLeader = v }
                continue
            }

            if ["set", "se", "setlocal", "setl", "setglobal"].contains(cmd) {
                let body = stripTrailingComment(rest).trimmingCharacters(in: .whitespaces)
                if body.isEmpty {
                    diag(n, .error, "set: missing option")
                    continue
                }
                for tok in body.split(whereSeparator: { $0 == " " }).map(String.init) {
                    parseSetToken(tok, line: n, out: &out)
                }
                continue
            }

            if ignoredCommands.contains(cmd) || ignoredCommands.contains(line) {
                diag(n, .info, "ignored: lumi handles syntax and colours itself")
                continue
            }
            if scriptCommands.contains(cmd) || cmd.hasPrefix("call") || (cmd.first?.isUppercase ?? false && cmd.first?.isASCII ?? false) {
                diag(n, .warning, "`\(cmd)` is not supported: this vimrc never runs scripts or plugins")
                continue
            }
            diag(n, .error, "unknown command `\(cmd)`")
        }
        return out
    }

    private static func parseSetToken(_ tok: String, line n: Int, out: inout ParsedVimrc) {
        var found: [VimrcDiagnostic] = []
        func diag(_ line: Int, _ severity: VimrcDiagnostic.Severity, _ message: String) {
            found.append(VimrcDiagnostic(line: line, severity: severity, message: message))
        }
        defer { out.diagnostics += found }
        if let eq = firstMatch(#"^([a-z]+)\s*[=:]\s*(.*)$"#, tok), let name = eq[1] {
            let value = eq[2] ?? ""
            guard let key = numOpts[name] else {
                diag(n, ignoredOpts.contains(name) ? .info : .warning, "option `\(name)` is not supported")
                return
            }
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(value), v >= 1, v <= 16 else {
                diag(n, .error, "\(name) must be a number from 1 to 16")
                return
            }
            switch key {
            case "softtabstop": diag(n, .info, "softtabstop accepted (indent follows shiftwidth)")
            case "tabstop": out.options.tabstop = v
            default: out.options.shiftwidth = v
            }
            return
        }
        if firstMatch(#"[+^-]="#, tok) != nil {
            diag(n, .warning, "`\(tok)`: += / -= / ^= are not supported")
            return
        }
        var name = tok
        var value = true
        if name.hasSuffix("!") || name.hasPrefix("inv") {
            diag(n, .warning, "`\(tok)`: toggling (! / inv) is not supported; use the plain or no… form")
            return
        }
        if name.hasSuffix("?") || name.hasSuffix("&") {
            diag(n, .info, "`\(tok)` ignored")
            return
        }
        var opt = boolOpts[name]
        if opt == nil, name.hasPrefix("no"), let o = boolOpts[String(name.dropFirst(2))] {
            opt = o
            value = false
            name = String(name.dropFirst(2))
        }
        guard let opt else {
            if numOpts[name] != nil { diag(n, .error, "\(name) needs a value, e.g. \(name)=4") }
            else { diag(n, ignoredOpts.contains(tok) ? .info : .warning, "option `\(tok)` is not supported") }
            return
        }
        if alwaysOn.contains(opt) {
            diag(n, value ? .info : .warning, value ? "\(opt) is always on in this editor" : "\(opt) cannot be turned off in this editor")
            return
        }
        switch opt {
        case "number": out.options.number = value
        case "relativenumber": out.options.relativenumber = value
        case "wrap": out.options.wrap = value
        case "expandtab": out.options.expandtab = value
        default: break
        }
    }

    /// Strip a trailing `" comment` (set/let lines only; in maps `"` is a key).
    private static func stripTrailingComment(_ s: String) -> String {
        var inSingle = false
        var inDouble = false
        let chars = Array(s)
        for i in chars.indices {
            let c = chars[i]
            if c == "'", !inDouble {
                inSingle.toggle()
            } else if c == "\"", !inSingle {
                let prev = String(chars[..<i])
                if prev.last?.isWhitespace == true, firstMatch(#"=\s*$"#, prev) == nil, !inDouble {
                    return prev.trimmingCharacters(in: .whitespaces)
                }
                inDouble.toggle()
            }
        }
        return s
    }

    /// Display form of a map's lhs (`<leader>` resolved).
    public static func displayLhs(_ m: VimrcMap, leader: String) -> String {
        m.leader ? leader + m.lhs : m.lhs
    }

    /// Sanitise stored vimrc text: size-capped, no control characters
    /// except tab / newline.
    public static func sanitize(_ v: String) -> String {
        var s = v.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter {
            !(($0.value <= 0x08) || (0x0b...0x1f).contains($0.value) || $0.value == 0x7f)
        }))
        while s.utf8.count > maxBytes { s = String(s.prefix(Int(Double(s.count) * 0.9))) }
        return s
    }

    // MARK: Regex helpers

    private static func firstMatch(_ pattern: String, _ s: String, caseInsensitive: Bool = false) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    private static func replace(_ pattern: String, in s: String, with template: String, caseInsensitive: Bool = false) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}

/// One mapping from a `.vimrc`.
public struct VimrcMap: Sendable, Hashable {
    public enum Mode: String, Sendable, Hashable { case all, normal, insert, visual }
    public var mode: Mode
    public var lhs: String
    public var rhs: String
    public var noremap: Bool
    /// 1-based source line.
    public var line: Int
    /// lhs began with `<leader>`: `lhs` holds the keys AFTER the leader.
    public var leader: Bool

    public init(mode: Mode, lhs: String, rhs: String, noremap: Bool, line: Int, leader: Bool = false) {
        self.mode = mode
        self.lhs = lhs
        self.rhs = rhs
        self.noremap = noremap
        self.line = line
        self.leader = leader
    }
}

public struct VimrcOptions: Sendable, Hashable {
    public var number: Bool?
    public var relativenumber: Bool?
    public var wrap: Bool?
    public var expandtab: Bool?
    public var tabstop: Int?
    public var shiftwidth: Int?

    public init() {}
}

public struct VimrcDiagnostic: Sendable, Hashable {
    public enum Severity: String, Sendable, Hashable { case error, warning, info }
    public var line: Int
    public var severity: Severity
    public var message: String
}

public struct ParsedVimrc: Sendable, Hashable {
    public var maps: [VimrcMap]
    public var options: VimrcOptions
    /// Leader in key notation (`\`, `,`, `<Space>`).
    public var leader: String
    public var diagnostics: [VimrcDiagnostic]

    public var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }

    /// Diagnostics for one (1-based) line.
    public func diagnostics(forLine line: Int) -> [VimrcDiagnostic] {
        diagnostics.filter { $0.line == line }
    }
}

public extension VimState {
    /// Apply a parsed `.vimrc`: mappings, leader and options. Replaces
    /// the mappings a previous vimrc installed.
    mutating func apply(vimrc parsed: ParsedVimrc) {
        leader = parsed.leader
        mappings = parsed.maps.compactMap { VimMapping(vimrc: $0, leader: parsed.leader) }
        mapPending = []
        mapTentative = 0
        let o = parsed.options
        if let v = o.tabstop { options.tabstop = v }
        if let v = o.shiftwidth { options.shiftwidth = v }
        if let v = o.expandtab { options.expandtab = v }
        options.number = o.number
        options.relativenumber = o.relativenumber
        options.wrap = o.wrap
    }
}
