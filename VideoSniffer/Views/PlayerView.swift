import SwiftUI
import AVFoundation
import MobileVLCKit

struct PlayerView: View {
    let url: URL
    var referer: String?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: VLCPlayerModel

    init(url: URL, referer: String? = nil) {
        self.url = url
        self.referer = referer
        _model = StateObject(wrappedValue: VLCPlayerModel(url: url, referer: referer))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VLCVideoSurface(player: model.player)
                    .ignoresSafeArea()

                if let error = model.errorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text(error)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                    .padding(24)
                } else if model.isBuffering {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.3)
                }

                VStack {
                    Spacer()
                    controlBar
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.black.opacity(0.7), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onDisappear {
            model.stop()
        }
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { model.position },
                    set: { model.seek(to: $0) }
                ),
                in: 0...1
            )
            .tint(.white)
            .disabled(model.durationSeconds <= 0)

            HStack {
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 32)
                }

                Spacer()

                Text("\(model.timeText) / \(model.durationText)")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.55))
    }
}

private struct VLCVideoSurface: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        player.drawable = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if (player.drawable as? UIView) !== uiView {
            player.drawable = uiView
        }
    }
}

final class VLCPlayerModel: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var position: Double = 0
    @Published private(set) var timeText = "00:00"
    @Published private(set) var durationText = "--:--"
    @Published private(set) var durationSeconds: Double = 0
    @Published private(set) var errorMessage: String?

    private var isSeeking = false
    private var didConfigureAudio = false

    init(url: URL, referer: String?) {
        super.init()

        player.delegate = self

        let media = VLCMedia(url: url)
        var options: [AnyHashable: Any] = [
            ":network-caching": 1500
        ]
        if let referer, !referer.isEmpty {
            options[":http-referrer"] = referer
        }
        media.addOptions(options)
        player.media = media
        player.play()
    }

    func togglePlay() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    func seek(to value: Double) {
        guard durationSeconds > 0 else { return }
        isSeeking = true
        player.position = Float(min(max(value, 0), 1))
        isSeeking = false
    }

    func stop() {
        player.stop()
        player.drawable = nil
        player.delegate = nil
    }

    private func configureAudioIfNeeded() {
        guard !didConfigureAudio else { return }
        didConfigureAudio = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    private func updateDurations() {
        let length = player.media.length
        guard length.intValue > 0 else { return }
        durationText = length.stringValue
        durationSeconds = Double(length.intValue)
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        switch player.state {
        case .opening, .buffering:
            isBuffering = true
        case .playing:
            configureAudioIfNeeded()
            isBuffering = false
            isPlaying = true
            errorMessage = nil
            updateDurations()
        case .paused:
            isBuffering = false
            isPlaying = false
            updateDurations()
        case .ended:
            isBuffering = false
            isPlaying = false
        case .error:
            isBuffering = false
            isPlaying = false
            errorMessage = "播放失败：格式不支持或网络不可达"
        default:
            break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard !isSeeking else { return }
        timeText = player.time.stringValue
        updateDurations()
        if durationSeconds > 0 {
            position = Double(player.position)
        }
    }
}
