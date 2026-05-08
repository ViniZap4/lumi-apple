import Foundation
import Observation
import LumiKit
import LumiUI

@Observable
@MainActor
final class AppState {
    var theme: LumiTheme = .defaultDark
    var selectedVaultID: UUID?
    var selectedNoteID: String?

    /// Notes scanned from the currently selected vault. Cached here so the
    /// detail view can resolve a selection by id without re-walking the disk.
    var notes: [Note] = []

    /// File:// URL of the currently active vault root. Used as the `baseURL`
    /// when resolving relative media references.
    var activeVaultURL: URL?
}
