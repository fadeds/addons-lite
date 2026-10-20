import SwiftUI
import AVKit

struct PlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView("加载中…")
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if player == nil {
                let newPlayer = AVPlayer(url: url)
                player = newPlayer
                newPlayer.play()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
