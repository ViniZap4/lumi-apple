import SwiftUI
import LumiUI

// ShellFont, ShellMetrics, ElevatedSurface, Hairline and KeyCap live in
// LumiUI (Shell/ShellChromeKit.swift) so the pane, floating explorer and
// hover-card components there share them.

extension View {
    /// Editor column capped to a readable measure, centred (web
    /// `readableWidth`).
    func readableEditorWidth(_ capped: Bool = true) -> some View {
        frame(maxWidth: capped ? 880 : .infinity).frame(maxWidth: .infinity)
    }
}
