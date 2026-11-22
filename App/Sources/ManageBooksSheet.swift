import SwiftUI
import LumiKit
import LumiUI

/// "Gerenciar livros" (SPEC-LIVROS §5): reorder by dragging, rename
/// (bound books need `vault.manage` — renames for everyone), unlink,
/// remove from list, switch server, relink an incomplete binding.
struct ManageBooksSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var order: [Book] = []
    @State private var editing: String?
    @State private var draftName = ""
    @State private var canManage: [String: Bool] = [:]
    @State private var relinkChoices: [String: [(AccountKey, RemoteVault)]] = [:]
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("manage books").font(.headline).foregroundStyle(theme.text)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderless)
            }
            if let reason = appState.books.readOnlyReason {
                Text(reason).font(.caption).foregroundStyle(theme.warning)
            }
            List {
                ForEach(order) { book in
                    row(book)
                }
                .onMove { from, to in
                    order.move(fromOffsets: from, toOffset: to)
                    appState.books.reorder(order.map(\.id))
                }
            }
            .frame(minHeight: 280)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(theme.error)
            }
            Text("drag to reorder — ⌃⌘1–9 follow the switcher order. unlinking never deletes anything on the server.")
                .font(.caption)
                .foregroundStyle(theme.textDim)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
        .background(theme.background)
        .task { await load() }
    }

    @ViewBuilder
    private func row(_ book: Book) -> some View {
        HStack(spacing: 10) {
            BookStatusDot(status: appState.sync.status(for: book))
            if editing == book.id {
                TextField("Name", text: $draftName, onCommit: { Task { await commitRename(book) } })
                    .textFieldStyle(.roundedBorder)
                Button("Save") { Task { await commitRename(book) } }
                Button("Cancel") { editing = nil }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.name).font(.system(.body, design: .monospaced))
                    Text(subtitle(book))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }
                Spacer()
                actions(book)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func actions(_ book: Book) -> some View {
        let renameAllowed = book.kind == .local || canManage[book.id] == true
        Menu {
            Button("Rename…") {
                draftName = book.name
                editing = book.id
            }
            .disabled(!renameAllowed)
            if book.kind == .bound && !renameAllowed {
                Text("renaming a linked book renames it for everyone and needs vault.manage")
            }
            if book.kind == .bound {
                if let alts = appState.sync.alternates[book.id], !alts.isEmpty {
                    Menu("Switch server…") {
                        ForEach(alts, id: \.self) { alt in
                            Button(alt.description) { Task { await appState.sync.switchServer(book.id, to: alt) } }
                        }
                    }
                }
                if book.vaultID == nil, let choices = relinkChoices[book.id], !choices.isEmpty {
                    Menu("Relink to…") {
                        ForEach(choices, id: \.1.id) { key, vault in
                            Button("\(vault.name) — \(key.description)") {
                                appState.books.relink(book.id, to: key, vaultID: vault.id)
                                Task { await appState.sync.refreshListings() }
                                refresh()
                            }
                        }
                    }
                }
                if let key = book.accountKey, !appState.accounts.state(key).isSignedIn {
                    Button("Sign in…") {
                        appState.signInPrefill = key
                        dismiss()
                        appState.showAddServer = true
                    }
                }
                Divider()
                Button(book.path != nil || appState.books.bookmarks.bookmark(for: book.id) != nil
                       ? "Unlink (keep folder as local book)" : "Remove from list") {
                    appState.books.unlink(book.id)
                    appState.sync.forgetBook(book.id)
                    refresh()
                }
            } else {
                Divider()
                Button("Remove from list (folder stays on disk)") {
                    appState.books.remove(book.id)
                    refresh()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func subtitle(_ book: Book) -> String {
        switch book.kind {
        case .local: return book.path ?? "this device"
        case .bound:
            let who = book.accountKey?.description ?? "?"
            return book.vaultID == nil ? "\(who) · incomplete link" : who
        }
    }

    private func refresh() {
        order = appState.books.books.sorted(by: Book.registryOrder)
    }

    private func load() async {
        appState.books.reload()
        refresh()
        for book in order where book.kind == .bound {
            guard let key = book.accountKey, appState.accounts.state(key).isSignedIn,
                  let client = appState.accounts.client(for: key) else { continue }
            if let vault = book.vaultUUID {
                if let members = try? await client.listMembers(vaultID: vault),
                   let me = members.first(where: { $0.username == key.username }) {
                    canManage[book.id] = me.capabilities.contains { $0 == "*" || $0 == "vault.*" || $0 == "vault.manage" }
                }
            } else if let server = book.serverURL {
                var choices: [(AccountKey, RemoteVault)] = []
                for acc in appState.accounts.accounts(on: server) where appState.accounts.state(acc.key).isSignedIn {
                    if let vaults = try? await appState.accounts.client(for: acc.key)?.listVaults() {
                        for v in vaults where appState.books.book(vaultID: v.id.uuidString.lowercased()) == nil {
                            choices.append((acc.key, v))
                        }
                    }
                }
                relinkChoices[book.id] = choices
            }
        }
    }

    private func commitRename(_ book: Book) async {
        errorMessage = nil
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { editing = nil; return }
        switch book.kind {
        case .local:
            appState.books.rename(book.id, to: name)
        case .bound:
            guard let key = book.accountKey, let vault = book.vaultUUID,
                  let client = appState.accounts.client(for: key) else { return }
            do {
                let updated = try await client.renameVault(vaultID: vault, name: name)
                appState.books.updateCachedName(book.id, to: updated.name)
            } catch {
                errorMessage = "rename failed: \(error)"
                return
            }
        }
        editing = nil
        refresh()
    }
}
