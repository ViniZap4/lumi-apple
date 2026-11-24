import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Clipboard export for a rendered diagram: bitmap (PNG), sanitised SVG,
/// or the Mermaid source.
@MainActor
enum MermaidExport {
    static let svgType = "public.svg-image"

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func copyPNG(_ diagram: MermaidDiagram) {
        guard let png = pngData(diagram.bitmap.cgImage) else { return }
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        let image = NSImage(cgImage: diagram.bitmap.cgImage, size: diagram.size)
        pb.writeObjects([image])
        pb.setData(png, forType: .png)
        #elseif canImport(UIKit)
        UIPasteboard.general.setItems([[UTType.png.identifier: png]])
        #endif
    }

    static func copySVG(_ diagram: MermaidDiagram) {
        // Already scrubbed by the renderer; scrub again in case a caller
        // built a diagram by hand.
        let svg = MermaidSVGSanitizer.sanitize(diagram.svg)
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(svg, forType: .string)
        pb.setData(Data(svg.utf8), forType: NSPasteboard.PasteboardType(svgType))
        #elseif canImport(UIKit)
        UIPasteboard.general.setItems([[svgType: Data(svg.utf8), UTType.utf8PlainText.identifier: svg]])
        #endif
    }

    static func copySource(_ source: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = source
        #endif
    }
}
