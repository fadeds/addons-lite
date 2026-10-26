import SwiftUI
import UIKit
import AVFoundation
import KSPlayer

struct PlayerView: View {
    let url: URL
    var referer: String?

    @Binding private var windowOffset: CGSize
    @EnvironmentObject private var appState: AppState
    @StateObject private var model: KSPlayerModel

    @State private var showControls = true
    @State private var scrubPosition: Double?

    @State private var hud: PlayerHUD?
    @State private var hudToken = 0

    @State private var dragMode: DragMode = .none
    @State private var seekStartPosition: Double = 0
    @State private var seekTarget: Double = 0
    @State private var brightnessStart: CGFloat = 0
    @State private var volumeStart: Float = 0

    @State private var isDraggingWindow = false
    @State private var windowDragStart: CGSize = .zero

    private enum DragMode {
        case none, seek, brightness, volume
    }

    private struct PlayerHUD: Equatable {
        let icon: String
        let text: String
        let progress: Double?
    }

    init(
        url: URL,
        referer: String? = nil,
        windowOffset: Binding<CGSize> = .constant(.zero)
    ) {
        self.url = url
        self.referer = referer
        _windowOffset = windowOffset
        _model = StateObject(wrappedValue: KSPlayerModel(url: url, referer: referer))
    }

    var body: some View {
        GeometryReader { geo in
            let expanded = appState.playerExpanded
            let barHeight: CGFloat = expanded ? 0 : 38
            let videoHeight = expanded ? geo.size.height : max(geo.size.height - barHeight, 1)
            let isLandscape = geo.size.width > geo.size.height
            let horizontalPadding: CGFloat = expanded ? (isLandscape ? 48 : 20) : 10

            ZStack(alignment: .top) {
                Color.black

                KSVideoSurface(player: model.playerLayer)
                    .allowsHitTesting(false)
                    .frame(width: geo.size.width, height: videoHeight)
                    .frame(maxHeight: .infinity, alignment: .bottom)

                gestureLayer(size: CGSize(width: geo.size.width, height: videoHeight))
                    .frame(width: geo.size.width, height: videoHeight)
                    .frame(maxHeight: .infinity, alignment: .bottom)

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
                    .position(x: geo.size.width / 2, y: barHeight + videoHeight / 2)
                } else if model.isBuffering {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.3)
                        .position(x: geo.size.width / 2, y: barHeight + videoHeight / 2)
                }

                if let hud {
                    hudView(hud)
                        .position(x: geo.size.width / 2, y: barHeight + videoHeight / 2)
                        .transition(.opacity)
                }

                VStack(spacing: 0) {
                    if expanded {
                        if showControls {
                            fullTopBar(horizontalPadding: horizontalPadding)
                        }
                    } else {
                        miniTopBar
                    }

                    Spacer(minLength: 0)

                    if showControls {
                        if expanded {
                            fullBottomBar(horizontalPadding: horizontalPadding)
                        } else {
                            miniBottomBar
                        }
                    }
                }
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: expanded ? 0 : 14,
                    style: .continuous
                )
            )
            .overlay {
                if !expanded {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showControls)
        }
        .background(Color.black)
        .statusBarHidden(appState.playerExpanded)
        .persistentSystemOverlays(appState.playerExpanded ? .hidden : .automatic)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: appState.playerExpanded) { expanded in
            if expanded {
                OrientationManager.shared.allowLandscape = true
                requestOrientation(.landscapeRight)
            } else {
                OrientationManager.shared.allowLandscape = false
                requestOrientation(.portrait)
            }
        }
    }

    // MARK: - 顶部栏

    private var miniTopBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.55))

            Text(displayName)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                windowOffset = .zero
                showControls = true
                appState.playerExpanded = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }

            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(.black.opacity(0.6))
        .contentShape(Rectangle())
        .gesture(windowDragGesture)
    }

    private func fullTopBar(horizontalPadding: CGFloat) -> some View {
        HStack(spacing: 12) {
            Button {
                close()
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
                showControls = true
                appState.playerExpanded = false
            } label: {
                Text("小窗")
                    .font(.footnote.weight(.semibold))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(.black.opacity(0.45), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.65), .black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - 底部栏

    private var miniBottomBar: some View {
        HStack(spacing: 8) {
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.footnote.weight(.bold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }

            Text(displayTime)
                .font(.caption2.monospacedDigit())

            Spacer(minLength: 4)

            Text(model.durationText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func fullBottomBar(horizontalPadding: CGFloat) -> some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { scrubPosition ?? model.position },
                    set: { scrubPosition = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    guard !editing, let target = scrubPosition else { return }
                    model.seek(to: target)
                    scrubPosition = nil
                }
            )
            .tint(.white)
            .disabled(model.durationSeconds <= 0)

            HStack(spacing: 16) {
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 34, height: 30)
                        .contentShape(Rectangle())
                }

                Text(displayTime)
                    .font(.caption.monospacedDigit())

                Spacer()

                Text(model.durationText)
                    .font(.caption.monospacedDigit())

                speedMenu
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var speedMenu: some View {
        Menu {
            ForEach(KSPlayerModel.rates, id: \.self) { rate in
                Button {
                    model.setRate(rate)
                } label: {
                    if abs(model.rate - rate) < 0.01 {
                        Label(KSPlayerModel.rateText(rate), systemImage: "checkmark")
                    } else {
                        Text(KSPlayerModel.rateText(rate))
                    }
                }
            }
        } label: {
            Text(KSPlayerModel.rateText(model.rate))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 44)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(.black.opacity(0.45), in: Capsule())
        }
    }

    // MARK: - 手势

    private func gestureLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(videoDragGesture(size: size))
            .onTapGesture {
                toggleControls()
            }
    }

    private func videoDragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { gesture in
                if dragMode == .none {
                    let dx = gesture.translation.width
                    let dy = gesture.translation.height
                    if abs(dx) > abs(dy) * 1.2 {
                        dragMode = .seek
                        seekStartPosition = model.position
                        seekTarget = model.position
                    } else if gesture.startLocation.x < size.width / 2 {
                        dragMode = .brightness
                        brightnessStart = currentBrightness
                    } else {
                        dragMode = .volume
                        volumeStart = SystemVolume.shared.value
                    }
                }

                switch dragMode {
                case .seek:
                    guard model.durationSeconds > 0 else { return }
                    let delta = Double(gesture.translation.width / max(size.width, 1))
                    let target = min(max(seekStartPosition + delta, 0), 1)
                    seekTarget = target
                    let seconds = target * model.durationSeconds
                    showHUD(
                        PlayerHUD(
                            icon: delta >= 0 ? "goforward" : "gobackward",
                            text: "\(KSPlayerModel.formatTime(seconds)) / \(KSPlayerModel.formatTime(model.durationSeconds))",
                            progress: target
                        )
                    )

                case .brightness:
                    let delta = -Double(gesture.translation.height / max(size.height, 1))
                    let value = min(max(Double(brightnessStart) + delta, 0), 1)
                    setBrightness(CGFloat(value))
                    showHUD(
                        PlayerHUD(
                            icon: "sun.max.fill",
                            text: "亮度 \(Int(value * 100))%",
                            progress: value
                        )
                    )

                case .volume:
                    let delta = -Double(gesture.translation.height / max(size.height, 1))
                    let value = min(max(Double(volumeStart) + delta, 0), 1)
                    SystemVolume.shared.set(Float(value))
                    showHUD(
                        PlayerHUD(
                            icon: value <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            text: "音量 \(Int(value * 100))%",
                            progress: value
                        )
                    )

                case .none:
                    break
                }
            }
            .onEnded { _ in
                if dragMode == .seek {
                    model.seek(to: seekTarget)
                }
                dragMode = .none
                scheduleHUDHide(after: 0.8)
            }
    }

    private var windowDragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { gesture in
                if !isDraggingWindow {
                    isDraggingWindow = true
                    windowDragStart = windowOffset
                }
                windowOffset = CGSize(
                    width: windowDragStart.width + gesture.translation.width,
                    height: windowDragStart.height + gesture.translation.height
                )
            }
            .onEnded { _ in
                isDraggingWindow = false
            }
    }

    private var currentBrightness: CGFloat {
        activeWindowScene?.screen.brightness ?? 0.5
    }

    private func setBrightness(_ value: CGFloat) {
        activeWindowScene?.screen.brightness = min(max(value, 0), 1)
    }

    // MARK: - HUD

    private func hudView(_ hud: PlayerHUD) -> some View {
        VStack(spacing: 8) {
            Image(systemName: hud.icon)
                .font(.title3)

            Text(hud.text)
                .font(.caption.monospacedDigit())

            if let progress = hud.progress {
                ProgressView(value: progress)
                    .tint(.white)
                    .frame(width: 110)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func showHUD(_ newHUD: PlayerHUD) {
        hudToken += 1
        withAnimation(.easeOut(duration: 0.12)) {
            hud = newHUD
        }
    }

    private func scheduleHUDHide(after delay: Double) {
        hudToken += 1
        let token = hudToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard hudToken == token else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                hud = nil
            }
        }
    }

    // MARK: - 生命周期

    private func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        OrientationManager.shared.allowLandscape = false
        model.startPlayback()
    }

    private func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        OrientationManager.shared.allowLandscape = false
        requestOrientation(.portrait)
        model.stop()
    }

    private func close() {
        appState.closePlayer()
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        activeWindowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }

    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
    }

    // MARK: - 展示

    private var displayName: String {
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return name.isEmpty ? "播放" : name
    }

    private var displayTime: String {
        if let scrubPosition, model.durationSeconds > 0 {
            return KSPlayerModel.formatTime(scrubPosition * model.durationSeconds)
        }
        return model.timeText
    }
}

private struct KSVideoSurface: UIViewRepresentable {
    let player: KSPlayerLayer

    func makeUIView(context: Context) -> UIView {
        let container = KSPlayerContainerView()
        container.backgroundColor = .black
        container.isUserInteractionEnabled = false
        attachSurface(container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        attachSurface(uiView)
    }

    private func attachSurface(_ container: UIView) {
        guard let surface = player.player.view else { return }
        if surface.superview !== container {
            surface.backgroundColor = .black
            surface.isUserInteractionEnabled = false
            surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(surface)
        }
        surface.frame = container.bounds
    }
}

private final class KSPlayerContainerView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.first?.frame = bounds
    }
}

final class KSPlayerModel: NSObject, ObservableObject, KSPlayerLayerDelegate {
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

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    let playerLayer: KSPlayerLayer

    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var position: Double = 0
    @Published private(set) var timeText = "00:00"
    @Published private(set) var durationText = "--:--"
    @Published private(set) var durationSeconds: Double = 0
    @Published private(set) var rate: Double = 1.0
    @Published private(set) var errorMessage: String?

    private var didStartPlayback = false
    private var didConfigureAudio = false
    private var isStopped = false
    private var isSeeking = false

    init(url: URL, referer: String?) {
        let options = KSOptions()
        options.isAccurateSeek = true
        options.registerRemoteControll = false
        options.referer = referer

        playerLayer = KSPlayerLayer(url: url, isAutoPlay: false, options: options)
        super.init()

        playerLayer.delegate = self
        playerLayer.player.contentMode = .scaleAspectFit
        playerLayer.player.view?.backgroundColor = .black
    }

    func startPlayback() {
        guard !didStartPlayback, !isStopped else { return }
        didStartPlayback = true
        isBuffering = true
        play()
    }

    func togglePlay() {
        if playerLayer.state.isPlaying {
            playerLayer.pause()
        } else {
            play()
        }
    }

    func play() {
        guard !isStopped else { return }
        configureAudioIfNeeded()
        playerLayer.play()
    }

    func seek(to value: Double) {
        guard durationSeconds > 0, !isStopped else { return }
        let clamped = min(max(value, 0), 1)
        let target = clamped * durationSeconds
        isSeeking = true
        position = clamped
        timeText = Self.formatTime(target)
        if isPlaying {
            isBuffering = true
        }
        playerLayer.seek(time: target, autoPlay: playerLayer.state.isPlaying) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self?.isSeeking = false
            }
        }
    }

    func setRate(_ value: Double) {
        rate = value
        playerLayer.player.playbackRate = Float(value)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        playerLayer.delegate = nil
        playerLayer.stop()
        isPlaying = false
        isBuffering = false
    }

    deinit {
        playerLayer.delegate = nil
        if !isStopped {
            playerLayer.stop()
        }
    }

    private func configureAudioIfNeeded() {
        guard !didConfigureAudio else { return }
        didConfigureAudio = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    // MARK: - KSPlayerLayerDelegate

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard !isStopped else { return }
        switch state {
        case .initialized:
            isPlaying = false
            isBuffering = false
        case .preparing, .readyToPlay:
            isPlaying = false
            isBuffering = true
        case .buffering:
            isPlaying = true
            isBuffering = true
        case .bufferFinished:
            isPlaying = true
            isBuffering = false
            errorMessage = nil
            updateDuration()
            if abs(Double(layer.player.playbackRate) - rate) > 0.01 {
                layer.player.playbackRate = Float(rate)
            }
        case .paused:
            isPlaying = false
            isBuffering = false
        case .playedToTheEnd:
            isPlaying = false
            isBuffering = false
            updateDuration()
            position = 1
            timeText = durationText
        case .error:
            isPlaying = false
            isBuffering = false
            errorMessage = "播放失败：格式不支持或文件损坏"
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        guard !isStopped else { return }
        if totalTime.isFinite, totalTime > 0, totalTime != durationSeconds {
            durationSeconds = totalTime
            durationText = Self.formatTime(totalTime)
        }
        guard !isSeeking, currentTime.isFinite else { return }
        let clamped = max(0, currentTime)
        timeText = Self.formatTime(clamped)
        if durationSeconds > 0 {
            position = min(max(clamped / durationSeconds, 0), 1)
        }
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard !isStopped else { return }
        isPlaying = false
        isBuffering = false
        if error != nil {
            errorMessage = "播放失败：格式不支持或文件损坏"
        } else {
            updateDuration()
            position = 1
            timeText = durationText
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        _ = layer
        _ = bufferedCount
        _ = consumeTime
    }

    private func updateDuration() {
        let duration = playerLayer.player.duration
        guard duration.isFinite, duration > 0 else { return }
        durationSeconds = duration
        durationText = Self.formatTime(duration)
    }
}
