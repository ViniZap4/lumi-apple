import SwiftUI
import LumiKit

/// Asks the user before the TUI gets a session from this app's account
/// (SPEC-LIVROS §8.2: never auto-approved).
struct DeviceLinkPrompts: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        let broker = appState.linkBroker
        content
            .alert(
                "Entrar no Terminal?",
                isPresented: Binding(get: { broker.pendingApprovals.first != nil },
                                     set: { _ in }),
                presenting: broker.pendingApprovals.first
            ) { approval in
                Button("Permitir") { Task { await broker.approve(approval.id) } }
                Button("Não permitir", role: .cancel) { broker.deny(approval.id) }
            } message: { approval in
                Text(approval.message + " O Terminal recebe uma sessão própria, que você pode encerrar a qualquer momento.")
            }
            .onChange(of: broker.pendingApprovals.count) { old, new in
                if new > old { appState.requestAttentionForLink() }
            }
    }
}
