import Foundation

/// Synthetic large note used by the renderer benchmark + identity tests.
/// Mixes every block construct the renderer handles (headings, prose
/// with inline styles and links, task + nested lists, fenced code,
/// quotes, rules, display math) so the numbers reflect a realistic
/// lumi note rather than 5k lines of identical prose.
enum RenderFixtures {
    static func largeNote(lines target: Int = 5_000) -> String {
        var out: [String] = []
        out.reserveCapacity(target + 32)
        var section = 0
        while out.count < target {
            section += 1
            out.append("## Section \(section): notes on *topic* \(section)")
            out.append("")
            out.append("Paragraph \(section) with **bold**, _emphasis_, `inline code`, ~~strike~~ and a [link](https://example.com/\(section)) to elsewhere,")
            out.append("plus a soft-wrapped second line referencing [[note-\(section)]] and more prose to wrap across the reading column.")
            out.append("")
            out.append("- [ ] open task \(section)")
            out.append("- [x] done task with [a link](./other-\(section).md)")
            out.append("- plain bullet")
            out.append("  - nested bullet \(section)")
            out.append("")
            out.append("1. first")
            out.append("2. second")
            out.append("")
            out.append("> quoted wisdom number \(section)")
            out.append("> spanning two lines")
            out.append("")
            out.append("```swift")
            out.append("let value\(section) = compute(\(section))")
            out.append("print(value\(section))")
            out.append("```")
            out.append("")
            if section % 10 == 0 {
                out.append("$$ e^{i\\pi} + \(section) = 0 $$")
                out.append("")
                out.append("---")
                out.append("")
            }
        }
        return out.joined(separator: "\n")
    }
}
