import SwiftUI
import AVKit

struct VideoMediaView: View {
    let url: URL

    @State private var player: AVPlayer?
    @Environment(\.theme) private var theme
    @Environment(\.markdownLite) private var lite

    var body: some View {
        if lite {
            // Preview fallback — no AVPlayer instantiation. Loading a
            // ~50 MB video file off disk per cursor flip wrecks the
            // navigation feel; the user can open the note to watch.
            HStack(spacing: 6) {
                Image(systemName: "film")
                    .font(.caption)
                    .foregroundStyle(theme.accent)
                Text("video · \(url.lastPathComponent)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(theme.overlayBackground.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            VideoPlayer(player: player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .onAppear {
                    if player == nil { player = AVPlayer(url: url) }
                }
                .onDisappear {
                    player?.pause()
                }
        }
    }
}
