import Foundation

/// What kind of media a markdown image-syntax `![alt](src)` reference points
/// to. Detection is by URL host (YouTube/Vimeo) or file extension. The
/// renderer dispatches to a different SwiftUI view per case.
public enum MediaKind: Sendable, Hashable {
    case image
    case video
    case pdf
    case youtube(videoID: String)
    case vimeo(videoID: String)
    /// Local markdown note embed (`![alt](./other.md)` form). The renderer
    /// loads the target file, parses it as markdown, and renders it inline
    /// in a styled container — Obsidian-style note inclusion.
    case markdown
    case unknown
}

public extension MediaKind {
    static func detect(url: URL) -> MediaKind {
        let host = url.host()?.lowercased() ?? ""

        if host.contains("youtube.com") || host.contains("youtu.be") || host.contains("youtube-nocookie.com") {
            if let id = extractYouTubeID(url: url) { return .youtube(videoID: id) }
        }

        if host.contains("vimeo.com") || host.contains("player.vimeo.com") {
            if let id = extractVimeoID(url: url) { return .vimeo(videoID: id) }
        }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "svg", "tiff":
            return .image
        case "mp4", "mov", "m4v", "webm", "mkv":
            return .video
        case "pdf":
            return .pdf
        case "md", "markdown":
            return .markdown
        default:
            return .unknown
        }
    }

    private static func extractYouTubeID(url: URL) -> String? {
        if (url.host()?.contains("youtu.be")) == true {
            let id = url.lastPathComponent
            return id.isEmpty ? nil : id
        }
        let path = url.path
        if path == "/watch" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "v" })?
                .value
        }
        if path.hasPrefix("/embed/") || path.hasPrefix("/shorts/") {
            return url.lastPathComponent.isEmpty ? nil : url.lastPathComponent
        }
        return nil
    }

    private static func extractVimeoID(url: URL) -> String? {
        let id = url.lastPathComponent
        return id.allSatisfy(\.isNumber) && !id.isEmpty ? id : nil
    }
}
