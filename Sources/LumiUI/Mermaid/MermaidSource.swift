import Foundation

/// Fence detection + diagram classification for Mermaid sources. Pure
/// string work (no WebKit), shared by the reader, the SwiftUI
/// `MarkdownView` path and the accessibility labels.
public enum MermaidSource {
    /// Largest source we hand to the renderer. Mirrors the `maxTextSize`
    /// we configure in mermaid; anything bigger becomes an error card
    /// instead of a multi-second layout on a hidden web view.
    public static let maxSourceLength = 50_000

    /// Is a fenced code block's info string a Mermaid fence? Accepts
    /// `mermaid`, `Mermaid`, `mermaid title="x"` (first word decides),
    /// and the `{mermaid}` / `.mermaid` attribute spellings some editors
    /// emit. Everything else stays a code block.
    public static func isMermaidFence(_ info: String?) -> Bool {
        guard let info else { return false }
        let first = info.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        var word = first.lowercased()
        if word.hasPrefix("{"), word.hasSuffix("}") { word = String(word.dropFirst().dropLast()) }
        if word.hasPrefix(".") { word = String(word.dropFirst()) }
        return word == "mermaid"
    }

    /// The diagram family a source declares, for labels and VoiceOver.
    public enum DiagramKind: String, Sendable, CaseIterable {
        case flowchart, sequence, classDiagram, state, entityRelationship, gantt, pie
        case journey, gitGraph, mindmap, timeline, quadrant, requirement, c4, sankey
        case xyChart, block, packet, architecture, kanban, radar, treemap, unknown

        /// Human name used in accessibility labels and the zoom sheet.
        public var displayName: String {
            switch self {
            case .flowchart: return "Flowchart"
            case .sequence: return "Sequence diagram"
            case .classDiagram: return "Class diagram"
            case .state: return "State diagram"
            case .entityRelationship: return "Entity relationship diagram"
            case .gantt: return "Gantt chart"
            case .pie: return "Pie chart"
            case .journey: return "User journey"
            case .gitGraph: return "Git graph"
            case .mindmap: return "Mind map"
            case .timeline: return "Timeline"
            case .quadrant: return "Quadrant chart"
            case .requirement: return "Requirement diagram"
            case .c4: return "C4 diagram"
            case .sankey: return "Sankey diagram"
            case .xyChart: return "XY chart"
            case .block: return "Block diagram"
            case .packet: return "Packet diagram"
            case .architecture: return "Architecture diagram"
            case .kanban: return "Kanban diagram"
            case .radar: return "Radar chart"
            case .treemap: return "Treemap"
            case .unknown: return "Diagram"
            }
        }
    }

    /// Classify a source by its first meaningful line, skipping blank
    /// lines, `%%` comments / `%%{init}%%` directives and a leading
    /// `---` YAML front-matter block (mermaid's config header).
    public static func diagramKind(of source: String) -> DiagramKind {
        guard let line = headerLine(of: source) else { return .unknown }
        let keyword = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ":" || $0 == "{" })
            .first.map { $0.lowercased() } ?? ""
        switch keyword {
        case "graph", "flowchart", "flowchart-elk": return .flowchart
        case "sequencediagram": return .sequence
        case "classdiagram", "classdiagram-v2": return .classDiagram
        case "statediagram", "statediagram-v2": return .state
        case "erdiagram": return .entityRelationship
        case "gantt": return .gantt
        case "pie": return .pie
        case "journey": return .journey
        case "gitgraph": return .gitGraph
        case "mindmap": return .mindmap
        case "timeline": return .timeline
        case "quadrantchart": return .quadrant
        case "requirementdiagram", "requirement": return .requirement
        case "c4context", "c4container", "c4component", "c4dynamic", "c4deployment": return .c4
        case "sankey", "sankey-beta": return .sankey
        case "xychart", "xychart-beta": return .xyChart
        case "block", "block-beta": return .block
        case "packet", "packet-beta": return .packet
        case "architecture", "architecture-beta": return .architecture
        case "kanban": return .kanban
        case "radar", "radar-beta": return .radar
        case "treemap", "treemap-beta": return .treemap
        default: return .unknown
        }
    }

    /// First line that carries the diagram declaration.
    static func headerLine(of source: String) -> String? {
        var inFrontMatter = false
        var sawContent = false
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---", !sawContent || inFrontMatter {
                inFrontMatter.toggle()
                sawContent = true
                continue
            }
            if inFrontMatter || line.isEmpty || line.hasPrefix("%%") { continue }
            return line
        }
        return nil
    }

    /// One-line, length-capped spoken summary: kind plus the header so
    /// VoiceOver users hear what the diagram is without the whole source.
    public static func accessibilityLabel(for source: String) -> String {
        let kind = diagramKind(of: source)
        let lines = source.split(separator: "\n").filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("%%")
        }
        return "\(kind.displayName), Mermaid, \(lines.count) line\(lines.count == 1 ? "" : "s")"
    }
}
