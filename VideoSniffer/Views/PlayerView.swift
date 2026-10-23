import SwiftUI
import UIKit
import AVFoundation
import MobileVLCKit

struct PlayerView: View {
    let url: URL
    var referer: String?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: VLCPlayerModel
    @State private var showControls = true
    @State private var isLandscape = false

    init(url: URL, referer: String? = nil) {
        self.url = url
        self.referer = referer
        _model = StateObject(wrappedValue: VLCPlayerModel(url: url, referer: referer))
    }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                ZStack {
                    Color.black
                    VLCVideoSurface(player: model.player)
                        .allowsHitTesting(false)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .onAppear {
                    isLandscape = geo.size.width > geo.size.height
                    if isLandscape {
                        model.startPlayback()
                    }
                }
                .onChange(of: geo.size) { size in
                    isLandscape = size.width > size.height
                    if isLandscape {
                        model.startPlayback()
                    }
                }
            }
            .ignoresSafeArea()

            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

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
                    .scaleEffect(1.4)
            }

            if showControls {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .background(Color.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    // MARK: - 控件

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.45), in: Circle())
            }

            Text(displayName)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                toggleOrientation()
            } label: {
                Text(isLandscape ? "竖屏" : "横屏")
                    .font(.footnote.weight(.semibold))
                    .frame(minWidth: 44)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(.black.opacity(0.45), in: Capsule())
            }

            speedMenu
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(VLCPlayerModel.rates, id: \.self) { rate in
                Button {
                    model.setRate(rate)
                } label: {
                    if abs(model.rate - rate) < 0.01 {
                        Label(VLCPlayerModel.rateText(rate), systemImage: "checkmark")
                    } else {
                        Text(VLCPlayerModel.rateText(rate))
                    }
                }
            }
        } label: {
            Text(VLCPlayerModel.rateText(model.rate))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 44)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(.black.opacity(0.45), in: Capsule())
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { model.position },
                    set: { model.seek(to: $0) }
                ),
                in: 0...1
            )
            .tint(.white)
            .disabled(model.durationSeconds <= 0)

            HStack(spacing: 14) {
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 40, height: 34)
                }

                Text(model.timeText)
                    .font(.caption.monospacedDigit())

                Spacer()

                Text(model.durationText)
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - 生命周期

    private func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        isLandscape = activeWindowScene?.interfaceOrientation.isLandscape ?? false
        OrientationManager.shared.allowLandscape = true
        OrientationManager.shared.userDidOverrideInitialOrientation = false
        requestOrientation(.landscapeRight)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard OrientationManager.shared.allowLandscape else { return }
            if !OrientationManager.shared.userDidOverrideInitialOrientation {
                requestOrientation(.landscapeRight)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard OrientationManager.shared.allowLandscape else { return }
            model.startPlayback()
        }
    }

    private func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        OrientationManager.shared.allowLandscape = false
        requestOrientation(.portrait)
        model.stop()
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
    }

    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
    }

    private func toggleOrientation() {
        guard let scene = activeWindowScene else { return }
        OrientationManager.shared.userDidOverrideInitialOrientation = true
        let target: UIInterfaceOrientationMask = scene.interfaceOrientation.isLandscape
            ? .portrait
            : .landscapeRight
        requestOrientation(target)
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        activeWindowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }

    private var displayName: String {
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return name.isEmpty ? "播放" : name
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
    static let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    static func rateText(_ rate: Double) -> String {
        var text = String(format: "%.2f", rate)
        while text.contains("."), text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text + "x"
    }

    let player = VLCMediaPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var position: Double = 0
    @Published private(set) var timeText = "00:00"
    @Published private(set) var durationText = "--:--"
    @Published private(set) var durationSeconds: Double = 0
    @Published private(set) var rate: Double = 1.0
    @Published private(set) var errorMessage: String?

    private var isSeeking = false
    private var didConfigureAudio = false
    private var didStartPlayback = false
    private var isStopped = false

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
    }

    func startPlayback() {
        guard !didStartPlayback, !isStopped else { return }
        didStartPlayback = true
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

    func setRate(_ value: Double) {
        rate = value
        player.rate = Float(value)
    }

    func stop() {
        isStopped = true
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
        guard let length = player.media?.length, length.intValue > 0 else { return }
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
            if abs(Double(player.rate) - rate) > 0.01 {
                player.rate = Float(rate)
            }
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
