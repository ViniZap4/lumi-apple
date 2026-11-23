import Testing
import Foundation
@testable import LumiKit

/// Mirrors the web client's `vimrc.test.ts` case by case.
@Suite("Vimrc — normalizeKeys")
struct VimrcNormalizeTests {
    @Test("canonicalises key notation case")
    func canonical() {
        #expect(Vimrc.normalizeKeys("<cr>").keys == "<CR>")
        #expect(Vimrc.normalizeKeys("<ESC>").keys == "<Esc>")
        #expect(Vimrc.normalizeKeys("<c-D>").keys == "<C-d>")
        #expect(Vimrc.normalizeKeys("<S-Tab>").keys == "<S-Tab>")
        #expect(Vimrc.normalizeKeys("<space>x").keys == "<Space>x")
        #expect(Vimrc.normalizeKeys("<a-c-x>").keys == "<C-A-x>")
        #expect(Vimrc.normalizeKeys("<f5>").keys == "<F5>")
        #expect(Vimrc.normalizeKeys("a<bar>b").keys == "a|b")
    }

    @Test("expands <leader> with the given leader")
    func leader() {
        #expect(Vimrc.normalizeKeys("<leader>w", leader: ",").keys == ",w")
        #expect(Vimrc.normalizeKeys("<Leader>w", leader: "<Space>").keys == "<Space>w")
    }

    @Test("rejects unknown names but keeps a literal <")
    func unknown() {
        #expect(Vimrc.normalizeKeys("<foo>").error?.contains("unknown key") == true)
        #expect(Vimrc.normalizeKeys("<x>").error?.contains("unknown key") == true)
        #expect(Vimrc.normalizeKeys("a < b").keys == "a < b")
    }
}

@Suite("Vimrc — parseLeaderValue")
struct VimrcLeaderTests {
    @Test("accepts quoted single keys and \\<Space>")
    func accepts() {
        #expect(Vimrc.parseLeaderValue("\" \"") == "<Space>")
        #expect(Vimrc.parseLeaderValue("\"\\<Space>\"") == "<Space>")
        #expect(Vimrc.parseLeaderValue("','") == ",")
        #expect(Vimrc.parseLeaderValue("\"\\\\\"") == "\\")
    }

    @Test("rejects expressions and multi-key values")
    func rejects() {
        #expect(Vimrc.parseLeaderValue("g:foo") == nil)
        #expect(Vimrc.parseLeaderValue("\"ab\"") == nil)
        #expect(Vimrc.parseLeaderValue("system(\"x\")") == nil)
    }
}

@Suite("Vimrc — parse")
struct VimrcParseTests {
    func sev(_ src: String) -> [String] {
        Vimrc.parse(src).diagnostics.map { "\($0.line):\($0.severity.rawValue)" }
    }

    @Test("parses maps by mode, with noremap and flags")
    func maps() {
        let p = Vimrc.parse("""

        " comment
        nnoremap <silent> H ^
        inoremap jj <Esc>
        vmap < <gv
        xnoremap > >gv
        map Y y$
        :nmap <C-j> 5j

        """)
        #expect(p.maps.map { "\($0.mode.rawValue)|\($0.noremap)|\($0.lhs)|\($0.rhs)" } == [
            "normal|true|H|^",
            "insert|true|jj|<Esc>",
            "visual|false|<|<gv",
            "visual|true|>|>gv",
            "all|false|Y|y$",
            "normal|false|<C-j>|5j",
        ])
        #expect(p.diagnostics.isEmpty)
    }

    @Test("records leader maps behind the leader and expands leader in rhs")
    func leaderMaps() {
        let p = Vimrc.parse("let mapleader = \" \"\nnnoremap <leader>w :w<CR>\ninoremap <leader>x X")
        #expect(p.leader == "<Space>")
        #expect(p.maps[0].lhs == "w")
        #expect(p.maps[0].leader)
        #expect(p.maps[0].rhs == ":w<CR>")
        #expect(Vimrc.displayLhs(p.maps[0], leader: p.leader) == "<Space>w")
        #expect(p.maps[1].lhs == "<Space>x")
        #expect(p.maps[1].mode == .insert)
        #expect(!p.maps[1].leader)
    }

    @Test("leader changes apply to later lines only (vim semantics)")
    func leaderOrder() {
        let p = Vimrc.parse("nnoremap <leader>a A\nlet mapleader=\",\"\nnnoremap x <leader>b")
        #expect(p.maps[0].lhs == "a")
        #expect(p.maps[0].leader)
        #expect(p.maps[1].rhs == ",b")
        #expect(p.leader == ",")
    }

    @Test("a later map of the same lhs replaces the earlier one")
    func replaces() {
        let p = Vimrc.parse("nnoremap H ^\nnnoremap H 0")
        #expect(p.maps.count == 1)
        #expect(p.maps[0].rhs == "0")
    }

    @Test("unmap removes a mapping defined above; warns otherwise")
    func unmap() {
        #expect(Vimrc.parse("nnoremap H ^\nnunmap H\nunmap Q").maps.isEmpty)
        #expect(sev("nnoremap H ^\nnunmap H\nunmap Q") == ["3:warning"])
        #expect(Vimrc.parse("let mapleader=\",\"\nnnoremap <leader>q :q<CR>\nnunmap <leader>q").maps.isEmpty)
    }

    @Test("set options: booleans, no-forms, numbers, comments")
    func setOptions() {
        let p = Vimrc.parse("set number norelativenumber nowrap \" comment\nset ts=2 sw=4 et\nset expandtab")
        #expect(p.options.number == true)
        #expect(p.options.relativenumber == false)
        #expect(p.options.wrap == false)
        #expect(p.options.tabstop == 2)
        #expect(p.options.shiftwidth == 4)
        #expect(p.options.expandtab == true)
        #expect(p.diagnostics.isEmpty)
    }

    @Test("set: always-on search options are infos; unknown options warn; bad numbers error")
    func setDiagnostics() {
        #expect(sev("set ignorecase smartcase hlsearch incsearch") == ["1:info", "1:info", "1:info", "1:info"])
        #expect(sev("set noincsearch") == ["1:warning"])
        #expect(sev("set foldmethod=marker") == ["1:warning"])
        #expect(sev("set ts=99") == ["1:error"])
        #expect(sev("set number!") == ["1:warning"])
        #expect(sev("set tabstop") == ["1:error"])
    }

    @Test("never evaluates: let / call / autocmd / function are reported, not run")
    func neverEvaluates() {
        let d = Vimrc.parse("let g:x = system(\"rm -rf /\")\ncall Foo()\nautocmd BufRead * echo 1\nfunction! F()\nnnoremap <expr> x \"y\"\nPlug 'tpope/vim-surround'").diagnostics
        #expect(d.map(\.severity) == [.warning, .warning, .warning, .warning, .error, .warning])
        #expect(Vimrc.parse("nnoremap <expr> x \"y\"").maps.isEmpty)
    }

    @Test("reports malformed lines with their line number")
    func malformed() {
        let d = Vimrc.parse("\nnnoremap\nnnoremap x\nnmap <bogus> x\nfrobnicate\n  \\ continuation").diagnostics
        #expect(d.map { "\($0.line):\($0.severity.rawValue)" } == ["2:error", "3:error", "4:error", "5:error", "6:error"])
    }

    @Test("ex aliases need plain map/noremap")
    func exAliases() {
        let m = Vimrc.parse("map :W :write").maps[0]
        #expect(m.mode == .all)
        #expect(m.lhs == ":W")
        #expect(m.rhs == ":write")
        #expect(sev("nmap :W :write") == ["1:error"])
    }

    @Test("ignores syntax/filetype/colorscheme with an info")
    func ignored() {
        #expect(sev("syntax on\nfiletype plugin indent on\ncolorscheme gruvbox\nset nocompatible") == ["1:info", "2:info", "3:info", "4:info"])
    }

    @Test("caps size and mapping count")
    func caps() {
        let many = (0..<(Vimrc.maxMaps + 5)).map { "nnoremap <F\(($0 % 12) + 1)>\($0) x" }.joined(separator: "\n")
        let p = Vimrc.parse(many)
        #expect(p.maps.count == Vimrc.maxMaps)
        #expect(p.errorCount == 5)
        let huge = Vimrc.parse(String(repeating: "\" x\n", count: Vimrc.maxBytes))
        #expect(huge.diagnostics.first?.severity == .error)
    }

    @Test("the bundled example parses cleanly")
    func example() {
        let p = Vimrc.parse(Vimrc.example)
        #expect(p.errorCount == 0)
        #expect(p.diagnostics.isEmpty)
    }

    @Test("per-line diagnostics lookup")
    func perLine() {
        let p = Vimrc.parse("set nu\nfrob\nset ts=99")
        #expect(p.diagnostics(forLine: 1).isEmpty)
        #expect(p.diagnostics(forLine: 2).first?.severity == .error)
        #expect(p.diagnostics(forLine: 3).first?.message == "ts must be a number from 1 to 16")
    }
}

@Suite("Vimrc — storage + engine")
struct VimrcStorageTests {
    @Test("sanitize strips control chars and caps size")
    func sanitize() {
        #expect(Vimrc.sanitize("a\u{0}b\r\nc\td") == "ab\nc\td")
        #expect(Vimrc.sanitize(String(repeating: "x", count: Vimrc.maxBytes * 2)).utf8.count <= Vimrc.maxBytes)
    }

    @Test("applying a vimrc installs mappings, leader and options")
    func apply() {
        var st = VimState()
        st.apply(vimrc: Vimrc.parse("let mapleader=\",\"\nnnoremap <leader>w :w<CR>\nset ts=2 sw=2 noet nu\nmap Y y$"))
        #expect(st.leader == ",")
        #expect(st.options.tabstop == 2)
        #expect(st.options.shiftwidth == 2)
        #expect(st.options.expandtab == false)
        #expect(st.options.number == true)
        #expect(st.mappings.contains { $0.lhs == [.character(","), .character("w")] && $0.rhs == [.character(":"), .character("w"), .return] })
        #expect(st.mappings.contains { $0.mode == .all && $0.lhs == [.character("Y")] })
    }

    @Test("<Space> leader maps fire on the space bar")
    func spaceLeader() {
        var st = VimState()
        st.apply(vimrc: Vimrc.parse("let mapleader = \" \"\nnnoremap <leader>d dd"))
        let (_, b) = vimRun(" d", "|a\nb", state: st)
        #expect(b.text == "b")
    }
}
