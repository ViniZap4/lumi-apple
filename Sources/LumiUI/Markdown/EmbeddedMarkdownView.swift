import SwiftUI
import LumiKit

/// Renders a markdown file referenced via `![alt](./other.md)` syntax as a
/// nested, styled block inside the host note. Obsidian's transclude feature
/// in spirit — the embedded note's content appears live, so changes to the
/// source file show up on next open.
///
/// Recursion guard: each render reads the current embed depth from
/// `Environment(\.markdownEmbedDepth)` and propagates `depth + 1`. At
/// depth >= `EmbedDepth.cap` the view shows a "depth limit reached"
/// placeholder instead of loading content. Without this, a note that
/// embeds itself (`![self](./self.md)`) would parse-render forever.
///
/// File I/O happens on a detached task so a 1 MB linked note doesn't stall
/// the main actor while the embed mounts. The view shows a "loading…"
/// placeholder until the parsed document arrives.
public struct EmbeddedMarkdownView: View {
    public let url: URL
    public let alt: String
    @Environment(\.theme) private var theme
    @Environment(\.markdownEmbedDepth) private var depth
    @State private var parsed: MarkdownDocument?
    @State private var loadError: String?

    public init(url: URL, alt: String) {
        self.url = url
        self.alt = alt
    }

    public var body: some View {
        Group {
            if depth >= EmbedDepth.cap {
                placeholder(message: "embed depth limit (\(EmbedDepth.cap)) reached", url: url)
            } else if let parsed {
                renderedContainer {
                    MarkdownView(parsed)
                        .environment(\.markdownEmbedDepth, depth + 1)
                        // Embedded content stays static — no per-block
                        // stagger animation. The host note's mount
                        // animation has already finished by the time
                        // this loads asynchronously.
                        .environment(\.markdownStagger, false)
                }
            } else if let loadError {
                placeholder(message: loadError, url: url)
            } else {
                placeholder(message: "loading embed…", url: url)
            }
        }
        .task(id: url) { await load() }
    }

    /// The styled outer container — separates the embed visually from the
    /// host note so the reader can tell what came from where. Left accent
    /// rail + lighter background + a header strip with the relative path
    /// of the source.
    @ViewBuilder
    private func renderedContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textDim)
                Text(headerLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            content()
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.primary.opacity(0.45))
                .frame(width: 3)
        }
        .background(
            theme.overlayBackground.opacity(0.45)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        )
    }

    private var headerLabel: String {
        let path = url.path
        // Trim the user's home dir so the header doesn't shout
        // `/Users/…/.config/Whatever`. We use the standardized path
        // because the URL came from MarkdownParser.resolve, which
        // already absolutized it.
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") {
            return "~/" + String(path.dropFirst(home.count + 1))
        }
        return url.lastPathComponent
    }

    @ViewBuilder
    private func placeholder(message: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(alt.isEmpty ? message : alt)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(theme.text)
            Text("\(message) · \(url.lastPathComponent)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.overlayBackground.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func load() async {
        let target = url
        do {
            let data = try Data(contentsOf: target)
            guard let text = String(data: data, encoding: .utf8) else {
                throw EmbedLoadError.notUtf8
            }
            // Parse off-main if the file is non-trivial; small files
            // can land synchronously to avoid an extra hop's
            // "loading…" flash.
            if text.count < 16_000 {
                let doc = MarkdownParser.parse(text, baseURL: target)
                await MainActor.run { self.parsed = doc }
            } else {
                let doc = await Task.detached(priority: .userInitiated) {
                    MarkdownParser.parse(text, baseURL: target)
                }.value
                await MainActor.run { self.parsed = doc }
            }
        } catch {
            let msg: String
            if (error as NSError).code == NSFileReadNoSuchFileError {
                msg = "file not found"
            } else {
                msg = "load failed"
            }
            await MainActor.run { self.loadError = msg }
        }
    }
}

private enum EmbedLoadError: Error { case notUtf8 }

/// Maximum nested-embed depth. A → B → C is allowed; A → B → C → D shows
/// a "depth limit reached" placeholder. The cap prevents both runaway
/// recursion on self-embedded notes and pathological "load 200 files"
/// scenarios that would freeze the main actor.
public enum EmbedDepth {
    public static let cap = 3
}

public struct MarkdownEmbedDepthKey: EnvironmentKey {
    public static let defaultValue: Int = 0
}

public extension EnvironmentValues {
    /// Current markdown-embed nesting depth. Read by `EmbeddedMarkdownView`
    /// to enforce the cap; propagated as `depth + 1` to its nested
    /// MarkdownView so further embeds inside the embed know where they sit.
    var markdownEmbedDepth: Int {
        get { self[MarkdownEmbedDepthKey.self] }
        set { self[MarkdownEmbedDepthKey.self] = newValue }
    }
}
