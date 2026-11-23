import Foundation

/// Lightweight, dependency-free syntax highlighter for fenced code in
/// the reader. Not a parser: one left-to-right scan that recognises
/// comments, strings, numbers, keywords, types and calls for the
/// common language families. Token classes match the web's
/// `classHighlighter` palette (keyword → secondary, string → accent,
/// number → warning, comment → dim italic, function → info, type →
/// primary, punctuation → dim).
public enum CodeHighlighter {
    public enum Kind: Sendable, Hashable {
        case keyword, string, number, comment, function, type, property, tag, punctuation, heading, inserted, deleted
    }

    public struct Token: Sendable, Hashable {
        /// UTF-16 range in the code.
        public var range: NSRange
        public var kind: Kind
    }

    struct Grammar {
        var keywords: Set<String>
        var lineComments: [String] = ["//"]
        var blockComment: (String, String)? = ("/*", "*/")
        var quotes: Set<Character> = ["\"", "'"]
        var capitalizedTypes = true
    }

    private static let cFamily: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto",
        "struct", "enum", "union", "typedef", "const", "static", "extern", "void", "int", "char", "float", "double",
        "long", "short", "unsigned", "signed", "sizeof", "true", "false", "null", "nullptr", "class", "public",
        "private", "protected", "new", "delete", "this", "try", "catch", "throw", "namespace", "using", "template",
        "virtual", "override", "final", "import", "package", "extends", "implements", "interface", "abstract",
        "boolean", "instanceof", "synchronized", "volatile", "auto", "bool", "inline",
    ]

    static func grammar(for language: String?) -> Grammar? {
        let lang = (language ?? "").lowercased()
        switch lang {
        case "swift":
            return Grammar(keywords: ["let", "var", "func", "if", "else", "guard", "return", "for", "in", "while", "repeat",
                                      "switch", "case", "default", "break", "continue", "struct", "class", "enum",
                                      "protocol", "extension", "import", "public", "private", "fileprivate", "internal",
                                      "open", "static", "final", "init", "deinit", "self", "Self", "super", "true", "false",
                                      "nil", "throws", "throw", "try", "catch", "async", "await", "actor", "some", "any",
                                      "where", "defer", "do", "is", "as", "inout", "mutating", "override", "typealias",
                                      "associatedtype", "lazy", "weak", "unowned", "subscript", "operator", "nonisolated"])
        case "js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs", "svelte":
            return Grammar(keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do",
                                      "switch", "case", "default", "break", "continue", "class", "extends", "new", "this",
                                      "super", "import", "export", "from", "as", "async", "await", "try", "catch",
                                      "finally", "throw", "typeof", "instanceof", "in", "of", "true", "false", "null",
                                      "undefined", "void", "yield", "interface", "type", "enum", "implements", "public",
                                      "private", "protected", "readonly", "static", "declare", "namespace", "keyof",
                                      "satisfies", "delete"],
                           quotes: ["\"", "'", "`"])
        case "go", "golang":
            return Grammar(keywords: ["package", "import", "func", "return", "if", "else", "for", "range", "switch",
                                      "case", "default", "break", "continue", "go", "defer", "select", "chan", "map",
                                      "struct", "interface", "type", "var", "const", "true", "false", "nil", "fallthrough",
                                      "goto", "make", "new", "len", "cap", "append", "error", "string", "int", "bool",
                                      "byte", "rune", "float64", "int64", "uint", "any"],
                           quotes: ["\"", "'", "`"])
        case "rust", "rs":
            return Grammar(keywords: ["fn", "let", "mut", "const", "static", "if", "else", "match", "for", "in", "while",
                                      "loop", "break", "continue", "return", "struct", "enum", "impl", "trait", "pub",
                                      "use", "mod", "crate", "self", "Self", "super", "where", "as", "ref", "move",
                                      "async", "await", "dyn", "unsafe", "true", "false", "type", "extern"],
                           quotes: ["\""])
        case "py", "python":
            return Grammar(keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and",
                                      "or", "is", "import", "from", "as", "with", "try", "except", "finally", "raise",
                                      "pass", "break", "continue", "lambda", "yield", "global", "nonlocal", "True",
                                      "False", "None", "async", "await", "assert", "del", "self", "match", "case"],
                           lineComments: ["#"], blockComment: nil)
        case "rb", "ruby":
            return Grammar(keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until",
                                      "for", "in", "do", "return", "yield", "begin", "rescue", "ensure", "raise", "nil",
                                      "true", "false", "self", "require", "attr_accessor", "case", "when", "then"],
                           lineComments: ["#"], blockComment: nil)
        case "sh", "bash", "zsh", "shell", "console", "fish":
            return Grammar(keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until",
                                      "case", "esac", "function", "return", "export", "local", "echo", "cd", "set",
                                      "unset", "source", "exit", "read", "sudo", "true", "false"],
                           lineComments: ["#"], blockComment: nil, capitalizedTypes: false)
        case "c", "h", "cpp", "c++", "cc", "hpp", "java", "kotlin", "kt", "cs", "csharp", "dart", "scala", "m", "objc":
            var kw = cFamily
            kw.formUnion(["fun", "val", "var", "when", "object", "data", "sealed", "companion", "is", "as", "let", "override",
                          "suspend", "async", "await", "string", "var", "foreach", "get", "set", "required", "late"])
            return Grammar(keywords: kw)
        case "json", "jsonc", "json5":
            return Grammar(keywords: ["true", "false", "null"], lineComments: lang == "json" ? [] : ["//"],
                           blockComment: lang == "json" ? nil : ("/*", "*/"), quotes: ["\""], capitalizedTypes: false)
        case "yaml", "yml", "toml", "ini", "conf":
            return Grammar(keywords: ["true", "false", "null", "yes", "no", "on", "off"], lineComments: ["#"],
                           blockComment: nil, capitalizedTypes: false)
        case "sql", "psql", "postgres", "mysql", "sqlite":
            let words = "select from where insert into values update set delete create table alter drop index on join left right inner outer full cross group by order having limit offset as and or not null is in exists between like distinct union all primary key references foreign default unique returning with case when then else end begin commit rollback transaction view trigger function returns language if constraint check cascade serial text integer bigint boolean timestamp timestamptz varchar uuid jsonb"
            let kw = Set(words.split(separator: " ").flatMap { [String($0), String($0).uppercased()] })
            return Grammar(keywords: kw, lineComments: ["--"], capitalizedTypes: false)
        case "css", "scss", "less":
            return Grammar(keywords: ["important", "media", "import", "keyframes", "from", "to", "root", "hover", "focus"],
                           lineComments: lang == "css" ? [] : ["//"], capitalizedTypes: false)
        case "html", "xml", "svg", "plist", "vue":
            return Grammar(keywords: [], lineComments: [], blockComment: ("<!--", "-->"), quotes: ["\"", "'"],
                           capitalizedTypes: false)
        case "diff", "patch":
            return Grammar(keywords: [], lineComments: [], blockComment: nil, quotes: [], capitalizedTypes: false)
        case "md", "markdown":
            return Grammar(keywords: [], lineComments: [], blockComment: ("<!--", "-->"), quotes: [], capitalizedTypes: false)
        case "":
            return nil
        default:
            // Unknown language: a generic C-like pass still reads well.
            return Grammar(keywords: cFamily, lineComments: ["//", "#"])
        }
    }

    /// Tokens for `code` in `language` (nil / empty language → none).
    public static func tokens(_ code: String, language: String?) -> [Token] {
        let lang = (language ?? "").lowercased()
        guard let g = grammar(for: lang) else { return [] }
        if lang == "diff" || lang == "patch" { return diffTokens(code) }
        if lang == "md" || lang == "markdown" { return markdownTokens(code) }
        let isMarkup = ["html", "xml", "svg", "plist", "vue"].contains(lang)
        let s = Array(code.utf16)
        var out: [Token] = []
        var i = 0
        func starts(_ p: String, at j: Int) -> Bool {
            let u = Array(p.utf16)
            guard j + u.count <= s.count else { return false }
            for k in 0..<u.count where s[j + k] != u[k] { return false }
            return true
        }
        func isIdentStart(_ c: UInt16) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127
        }
        func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        let quoteUnits = Set(g.quotes.compactMap { $0.utf16.first })
        var lastSignificant: UInt16 = 0

        while i < s.count {
            let c = s[i]
            // Comments.
            if let lc = g.lineComments.first(where: { starts($0, at: i) }) {
                // `#` in shell-ish languages only when it begins a word.
                if lc == "#", i > 0, s[i - 1] != 10, s[i - 1] != 32, s[i - 1] != 9 { i += 1; continue }
                var j = i
                while j < s.count, s[j] != 10 { j += 1 }
                out.append(Token(range: NSRange(location: i, length: j - i), kind: .comment))
                i = j
                continue
            }
            if let (open, close) = g.blockComment, starts(open, at: i) {
                var j = i + open.utf16.count
                while j < s.count, !starts(close, at: j) { j += 1 }
                j = min(s.count, j + close.utf16.count)
                out.append(Token(range: NSRange(location: i, length: j - i), kind: .comment))
                i = j
                continue
            }
            // Strings.
            if quoteUnits.contains(c) {
                var j = i + 1
                while j < s.count, s[j] != c {
                    if s[j] == 92 { j += 1 } // backslash
                    if s[j < s.count ? j : s.count - 1] == 10, c != 96 { break }
                    j += 1
                }
                j = min(s.count, j + 1)
                // A JSON / YAML key ("name": …) reads as a property.
                var k = j
                while k < s.count, s[k] == 32 { k += 1 }
                let isKey = (lang.hasPrefix("json") || lang == "yaml" || lang == "yml") && k < s.count && s[k] == 58
                out.append(Token(range: NSRange(location: i, length: j - i), kind: isKey ? .property : .string))
                i = j
                lastSignificant = c
                continue
            }
            // Markup tags.
            if isMarkup, c == 60 { // <
                var j = i + 1
                if j < s.count, s[j] == 47 || s[j] == 33 || s[j] == 63 { j += 1 }
                let nameStart = j
                while j < s.count, isIdent(s[j]) || s[j] == 45 || s[j] == 58 { j += 1 }
                if j > nameStart {
                    out.append(Token(range: NSRange(location: i, length: nameStart - i), kind: .punctuation))
                    out.append(Token(range: NSRange(location: nameStart, length: j - nameStart), kind: .tag))
                    i = j
                    // Attributes until `>`.
                    while i < s.count, s[i] != 62 {
                        if quoteUnits.contains(s[i]) { break }
                        if isIdentStart(s[i]) {
                            var k = i
                            while k < s.count, isIdent(s[k]) || s[k] == 45 || s[k] == 58 { k += 1 }
                            out.append(Token(range: NSRange(location: i, length: k - i), kind: .property))
                            i = k
                        } else {
                            i += 1
                        }
                    }
                    continue
                }
            }
            // Numbers.
            if isDigit(c) || (c == 46 && i + 1 < s.count && isDigit(s[i + 1])), i == 0 || !isIdent(s[i - 1]) {
                var j = i + 1
                while j < s.count, isIdent(s[j]) || s[j] == 46 { j += 1 }
                out.append(Token(range: NSRange(location: i, length: j - i), kind: .number))
                i = j
                lastSignificant = 48
                continue
            }
            // Identifiers.
            if isIdentStart(c), !isMarkup {
                var j = i + 1
                while j < s.count, isIdent(s[j]) { j += 1 }
                let word = String(utf16CodeUnits: Array(s[i..<j]), count: j - i)
                var k = j
                while k < s.count, s[k] == 32 { k += 1 }
                let next: UInt16 = k < s.count ? s[k] : 0
                let kind: Kind?
                if g.keywords.contains(word) {
                    kind = .keyword
                } else if (lang == "yaml" || lang == "yml" || lang == "toml" || lang == "ini") && next == 58 || (next == 61 && lang == "toml") {
                    kind = .property
                } else if next == 40 { // (
                    kind = lastSignificant == 46 ? .function : .function
                } else if g.capitalizedTypes, let f = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(f) {
                    kind = .type
                } else if lastSignificant == 46 { // .member
                    kind = .property
                } else {
                    kind = nil
                }
                if let kind { out.append(Token(range: NSRange(location: i, length: j - i), kind: kind)) }
                i = j
                lastSignificant = 97
                continue
            }
            if c != 32, c != 9, c != 10 { lastSignificant = c }
            i += 1
        }
        return out
    }

    private static func diffTokens(_ code: String) -> [Token] {
        var out: [Token] = []
        var offset = 0
        for line in code.components(separatedBy: "\n") {
            let len = (line as NSString).length
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
                out.append(Token(range: NSRange(location: offset, length: len), kind: .heading))
            } else if line.hasPrefix("+") {
                out.append(Token(range: NSRange(location: offset, length: len), kind: .inserted))
            } else if line.hasPrefix("-") {
                out.append(Token(range: NSRange(location: offset, length: len), kind: .deleted))
            }
            offset += len + 1
        }
        return out
    }

    private static func markdownTokens(_ code: String) -> [Token] {
        var out: [Token] = []
        var offset = 0
        for line in code.components(separatedBy: "\n") {
            let len = (line as NSString).length
            if line.hasPrefix("#") {
                out.append(Token(range: NSRange(location: offset, length: len), kind: .heading))
            } else if line.hasPrefix(">") {
                out.append(Token(range: NSRange(location: offset, length: min(1, len)), kind: .punctuation))
            }
            offset += len + 1
        }
        return out
    }
}
