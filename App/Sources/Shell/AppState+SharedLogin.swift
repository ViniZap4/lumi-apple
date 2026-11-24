import Foundation
import LumiKit
#if canImport(AppKit)
import AppKit
#endif

/// Shared login with the TUI on the Mac (SPEC-LIVROS §8): one account
/// registry (`~/.config/lumi/accounts.yaml`), one session per client,
/// device links between them.
extension AppState {
    /// Watch the registry and the link drop box (macOS only: on iOS and
    /// visionOS the config dir is the app container and there is no TUI).
    func startSharedLogin() {
        #if os(macOS)
        accounts.startWatching()
        linkBroker.start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.linkBroker.stop()
                self?.accounts.stopWatching()
            }
        }
        #endif
    }

    /// The registry changed (this app or the TUI): restart feeds and let
    /// the broker ask for sessions we lack.
    func sharedAccountsChanged() async {
        await accountsChanged()
        #if os(macOS)
        await linkBroker.scan()
        #endif
    }

    /// Bounce the Dock icon for a pending Terminal request. Never
    /// activates the app or steals focus.
    func requestAttentionForLink() {
        #if os(macOS)
        NSApp.requestUserAttention(.informationalRequest)
        #endif
    }

    /// "Sair neste Mac": this session and every session linked to it end;
    /// the TUI drops its own token too.
    func requestSignOutEverywhere(_ key: AccountKey) {
        Task {
            if remoteVaultsStore.replicaAccount == key { remoteVaultsStore.destroyOpenSession() }
            await accounts.signOutEverywhereOnThisMac(key)
            await accountsChanged()
            showToast("signed out of \(key.description) on this Mac", tone: .info)
        }
    }

    /// "Ligar do Terminal": clear the opt-out and ask the TUI for a link;
    /// it answers the next time `lumi` runs.
    func linkFromTerminal(_ key: AccountKey) {
        accounts.setLinkOptOut(key, false)
        Task {
            await linkBroker.scan()
            showToast("open lumi in the Terminal to finish signing in as \(key.description)", tone: .info)
        }
    }
}
