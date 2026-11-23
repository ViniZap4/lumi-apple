import SwiftUI
import LumiKit
import LumiUI

/// Slim bar above an open note (web `.note-bar`): sync dot, folder,
/// the title (click → rename in place), Reading | Source, the split
/// preview toggle, settings and Done.
struct NoteBar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var draft = ""
    @FocusState private var titleFocused: Bool
    @State private var hoverTitle = false

    private var editing: Bool { appState.isEditing }

    private var canWrite: Bool {
        appState.selectedEntry != nil || appState.can("note.write")
    }

    var body: some View {
        HStack(spacing: 10) {
            lead
            Spacer(minLength: 8)
            actions
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: ShellMetrics.noteBarHeight)
        .background(theme.background)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var lead: some View {
        HStack(spacing: 8) {
            ShellSyncDot()
            let folder = appState.openFolderPath
            if !folder.isEmpty {
                HStack(spacing: 6) {
                    Text(folder.split(separator: "/").joined(separator: " / "))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text("/").opacity(0.45)
                }
                .font(ShellFont.chrome)
                .foregroundStyle(theme.textDim)
                // The title wins the space; a long folder path truncates.
                .layoutPriority(-1)
            }
            if appState.renamingTitle {
                TextField("title", text: $draft)
                    .textFieldStyle(.plain)
                    .font(ShellFont.chromeBold)
                    .foregroundStyle(theme.text)
                    .focused($titleFocused)
                    .onSubmit { appState.renameOpenNote(to: draft) }
                    .onKeyPress(.escape) {
                        appState.renamingTitle = false
                        return .handled
                    }
                    .onAppear {
                        draft = appState.openNoteTitle ?? ""
                        titleFocused = true
                    }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused, appState.renamingTitle { appState.renameOpenNote(to: draft) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.text.opacity(0.06)))
                    .frame(maxWidth: 360)
            } else {
                Button {
                    beginRename()
                } label: {
                    Text(appState.openNoteTitle ?? "")
                        .font(ShellFont.chromeBold)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(hoverTitle && canWrite ? theme.text.opacity(0.06) : .clear))
                }
                .buttonStyle(.plain)
                .onHover { hoverTitle = $0 }
                .help(canWrite ? "Rename" : "")
                .hintTarget("notebar:title") { beginRename() }
                .padding(.horizontal, -6)
            }
            presence
        }
    }

    @ViewBuilder
    private var presence: some View {
        let peers = appState.selectedRemoteNoteID != nil ? appState.remoteVaultsStore.openNotePresence : []
        if !peers.isEmpty {
            HStack(spacing: -4) {
                ForEach(peers.prefix(4)) { peer in
                    Text(String(peer.name.prefix(1)).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.background)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color(hex: peer.color)))
                        .overlay(Circle().stroke(theme.background, lineWidth: 1.5))
                        .help(peer.name)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Picker("View", selection: Binding(
                get: { editing },
                set: { appState.setEditing($0) }
            )) {
                Text("Reading").tag(false)
                Text("Source").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!canWrite && !editing)
            .help("Reading ⇄ Source (⌘E)")
            .hintTarget("notebar:mode") { appState.setEditing(!editing) }

            iconButton(appState.preferences.splitPreview ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                       active: appState.preferences.splitPreview && editing,
                       help: "Preview beside source (\\p · ⌥⌘P · :preview split)", id: "notebar:split") {
                appState.toggleSplitPreview()
            }
            .disabled(!canWrite)
            iconButton("slider.horizontal.3", active: false, help: "Settings (⌘, · :settings)", id: "notebar:settings") {
                appState.showSettings = true
            }
            if editing {
                Rectangle().fill(theme.border.opacity(0.6)).frame(width: 1, height: 16).padding(.horizontal, 4)
                Button("Done") { appState.setEditing(false) }
                    .controlSize(.small)
                    .help("Done (:q · ⌘E)")
                    .hintTarget("notebar:done") { appState.setEditing(false) }
            }
        }
    }

    private func iconButton(_ symbol: String, active: Bool, help: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(active ? theme.primary : theme.textDim)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(active ? theme.primary.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
        .hintTarget(id, action: action)
    }

    private func beginRename() {
        guard canWrite else { return }
        appState.renamingTitle = true
    }
}
