import Foundation
import Observation
import LumiKit
import LumiUI

/// Root app state. Sub-stores will be split out as features land (VaultStore,
/// EditorStore, SyncStore). For Phase A this is the single source.
@Observable
@MainActor
final class AppState {
    var theme: LumiTheme = .defaultDark
    var vaults: [Vault] = []
    var selectedVaultID: UUID?
}
