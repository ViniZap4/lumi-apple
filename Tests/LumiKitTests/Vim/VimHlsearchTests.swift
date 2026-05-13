import Testing
import Foundation
@testable import LumiKit

@Suite("Vim — hlsearch (all-matches enumeration)")
struct VimHlsearchTests {
    @Test("empty pattern returns no matches")
    func emptyPattern() {
        #expect(allMatches(in: "foo bar baz", pattern: "").isEmpty)
    }

    @Test("invalid regex returns no matches")
    func invalidRegex() {
        // Unbalanced bracket — NSRegularExpression compile fails.
        #expect(allMatches(in: "foo", pattern: "[").isEmpty)
    }

    @Test("single match returns one range")
    func singleMatch() {
        let m = allMatches(in: "foo bar baz", pattern: "bar")
        #expect(m == [4..<7])
    }

    @Test("multiple matches return ranges in document order")
    func multipleMatches() {
        let m = allMatches(in: "bar foo bar baz bar", pattern: "bar")
        #expect(m == [0..<3, 8..<11, 16..<19])
    }

    @Test("smartcase: lowercase pattern matches both cases")
    func smartcaseInsensitive() {
        let m = allMatches(in: "Foo foo FOO", pattern: "foo")
        #expect(m == [0..<3, 4..<7, 8..<11])
    }

    @Test("smartcase: uppercase letter forces case-sensitive")
    func smartcaseSensitive() {
        let m = allMatches(in: "Foo foo FOO", pattern: "Foo")
        #expect(m == [0..<3])
    }

    @Test("\\C overrides smartcase to case-sensitive")
    func explicitCaseSensitive() {
        let m = allMatches(in: "Foo foo", pattern: "foo\\C")
        #expect(m == [4..<7])
    }

    @Test("regex special chars work (e.g. word-class)")
    func regexClasses() {
        // \\w+ in a string with regex-style escape passed through analyzeCaseFlags.
        let m = allMatches(in: "ab cd ef", pattern: "\\w+")
        #expect(m == [0..<2, 3..<5, 6..<8])
    }

    @Test("no matches for absent pattern returns []")
    func noMatches() {
        #expect(allMatches(in: "foo bar", pattern: "qux").isEmpty)
    }
}
