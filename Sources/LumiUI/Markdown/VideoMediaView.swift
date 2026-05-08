import SwiftUI
import AVKit

struct VideoMediaView: View {
    let url: URL

    @State private var player: AVPlayer?

    var body: some View {
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
