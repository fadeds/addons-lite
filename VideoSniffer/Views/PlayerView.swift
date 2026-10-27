import SwiftUI
import UIKit
import KSPlayer

/// 播放器视图：只负责"长什么样 + 怎么交互"，播放状态全部交给 PlayerModel。
///
/// 三种形态：
/// - mini：浮窗，顶栏+底栏常显（底栏带进度条），整窗可拖动
/// - wide：充满屏幕宽度，竖屏，控制条常显
/// - full：全屏横屏，控制条自动隐藏，视频区手势控制进度/亮度/音量
struct PlayerView: View {
    let url: URL
    var referer: String?

    @EnvironmentObject private var appState: AppState
    @StateObject private var model: PlayerModel
    @StateObject private var hud = HUDCenter()

    @State private var showControls = true
    @State private var scrubProgress: Double?

    @State private var dragMode: DragMode = .none
    @State private var dragAnchor: Double = 0
    @State private var seekTarget: Double = 0

    private enum DragMode { case none, seek, brightness, volume }

    init(url: URL, referer: String? = nil) {
        self.url = url
        self.referer = referer
        _model = StateObject(wrappedValue: PlayerModel(url: url, referer: referer))
    }

    private var isFull: Bool { appState.playerMode == .full }
    private var isMini: Bool { appState.playerMode == .mini }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            if isFull {
                fullLayout(size: geo.size)
            } else {
                compactLayout(size: geo.size)
            }
        }
        .background(Color.black)
        .statusBarHidden(isFull)
        .persistentSystemOverlays(isFull ? .hidden : .automatic)
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
        .onChange(of: appState.playerMode) { mode in
            if mode == .full {
                OrientationManager.shared.lockLandscape()
            } else {
                OrientationManager.shared.lockPortrait()
            }
        }
    }

    // MARK: - 布局

    private func compactLayout(size: CGSize) -> some View {
        VStack(spacing: 0) {
            compactTopBar
            videoArea
            compactBottomBar
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }

    private func fullLayout(size: CGSize) -> some View {
        ZStack {
            Color.black
            PlayerSurface(player: model.layer)
                .allowsHitTesting(false)
            videoInteractionLayer(size: size)
            statusOverlay
            if let content = hud.content {
                hudView(content)
            }
            VStack(spacing: 0) {
                if showControls {
                    fullTopBar
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                if showControls {
                    fullBottomBar
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showControls)
    }

    private var videoArea: some View {
        ZStack {
            Color.black
            PlayerSurface(player: model.layer)
                .allowsHitTesting(false)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.togglePlay() }
            statusOverlay
            if let content = hud.content {
                hudView(content)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func videoInteractionLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(videoGesture(size: size))
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
            }
    }

    // MARK: - 顶栏

    private var compactTopBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))

            Text(displayName)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            Spacer(minLength: 6)

            iconButton("arrow.up.left.and.arrow.down.right") {
                appState.playerMode = isMini ? .wide : .full
            }

            if !isMini {
                iconButton("arrow.down.right.and.arrow.up.left") {
                    appState.playerMode = .mini
                }
            }

            iconButton("xmark") { close() }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: PlayerLayout.topBar)
        .background(Color.black.opacity(0.5))
        .contentShape(Rectangle())
    }

    private var fullTopBar: some View {
        HStack(spacing: 12) {
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.4), in: Circle())
            }

            Text(displayName)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                appState.playerMode = .mini
            } label: {
                Text("小窗")
                    .font(.footnote.weight(.semibold))
                    .padding(.vertical, 7)
                    .padding(.horizontal, 14)
                    .background(.black.opacity(0.4), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.65), .black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - 底栏

    /// 小窗/宽窗底栏：进度条常显（这是小窗之前缺失的部分）
    private var compactBottomBar: some View {
        HStack(spacing: 8) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }

            progressSlider

            Text("\(model.timeText)/\(model.durationText)")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: PlayerLayout.bottomBar)
        .background(Color.black.opacity(0.5))
    }

    private var fullBottomBar: some View {
        VStack(spacing: 2) {
            progressSlider
                .padding(.horizontal, 4)

            HStack(spacing: 16) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 34, height: 30)
                        .contentShape(Rectangle())
                }

                Text("\(model.timeText) / \(model.durationText)")
                    .font(.caption.monospacedDigit())

                Spacer()

                speedMenu
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var progressSlider: some View {
        Slider(
            value: Binding(
                get: { scrubProgress ?? model.progress },
                set: { scrubProgress = $0 }
            ),
            in: 0...1,
            onEditingChanged: { editing in
                if editing {
                    model.beginScrub()
                } else {
                    if let target = scrubProgress {
                        model.seek(to: target)
                    }
                    scrubProgress = nil
                    model.endScrub()
                }
            }
        )
        .tint(.white)
        .disabled(model.duration <= 0)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(PlayerModel.rates, id: \.self) { rate in
                Button {
                    model.setRate(rate)
                } label: {
                    if abs(model.rate - rate) < 0.01 {
                        Label(PlayerModel.rateText(rate), systemImage: "checkmark")
                    } else {
                        Text(PlayerModel.rateText(rate))
                    }
                }
            }
        } label: {
            Text(PlayerModel.rateText(model.rate))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 44)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(.black.opacity(0.45), in: Capsule())
        }
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
    }

    // MARK: - 覆盖层

    private var statusOverlay: some View {
        ZStack {
            if let message = model.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text(message)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(16)
            } else if model.isBuffering {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.15)
            }
        }
        .allowsHitTesting(false)
    }

    private func hudView(_ content: HUDContent) -> some View {
        VStack(spacing: 6) {
            Image(systemName: content.icon)
                .font(.system(size: 17, weight: .semibold))
            Text(content.text)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
            if let progress = content.progress {
                ProgressView(value: progress)
                    .tint(.white)
                    .frame(width: 96)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            .black.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .allowsHitTesting(false)
    }

    // MARK: - 手势（全屏：进度、亮度、音量）

    private func videoGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                if dragMode == .none {
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if abs(dx) > abs(dy) * 1.2 {
                        dragMode = .seek
                        dragAnchor = model.progress
                        seekTarget = model.progress
                    } else if value.startLocation.x < size.width / 2 {
                        dragMode = .brightness
                        dragAnchor = Double(currentBrightness)
                    } else {
                        dragMode = .volume
                        dragAnchor = Double(SystemVolume.shared.value)
                    }
                }

                switch dragMode {
                case .seek:
                    guard model.duration > 0 else { return }
                    let delta = Double(value.translation.width / max(size.width, 1))
                    let target = min(max(dragAnchor + delta, 0), 1)
                    seekTarget = target
                    hud.show(
                        HUDContent(
                            icon: delta >= 0 ? "goforward" : "gobackward",
                            text: "\(PlayerModel.formatTime(target * model.duration)) / \(model.durationText)",
                            progress: target
                        )
                    )

                case .brightness:
                    let delta = -Double(value.translation.height / max(size.height, 1))
                    let level = min(max(dragAnchor + delta, 0), 1)
                    setBrightness(CGFloat(level))
                    hud.show(
                        HUDContent(
                            icon: "sun.max.fill",
                            text: "亮度 \(Int(level * 100))%",
                            progress: level
                        )
                    )

                case .volume:
                    let delta = -Double(value.translation.height / max(size.height, 1))
                    let level = min(max(dragAnchor + delta, 0), 1)
                    SystemVolume.shared.set(Float(level))
                    hud.show(
                        HUDContent(
                            icon: level <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            text: "音量 \(Int(level * 100))%",
                            progress: level
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
            }
    }

    private var currentBrightness: CGFloat {
        OrientationManager.activeScene?.screen.brightness ?? 0.5
    }

    private func setBrightness(_ value: CGFloat) {
        OrientationManager.activeScene?.screen.brightness = min(max(value, 0), 1)
    }

    // MARK: - 生命周期

    private func handleAppear() {
        UIApplication.shared.isIdleTimerDisabled = true
        if appState.playerMode == .full {
            OrientationManager.shared.lockLandscape()
        }
        model.start()
    }

    private func handleDisappear() {
        UIApplication.shared.isIdleTimerDisabled = false
        OrientationManager.shared.lockPortrait()
        model.stop()
    }

    private func close() {
        OrientationManager.shared.lockPortrait()
        appState.closePlayer()
    }

    private var displayName: String {
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return name.isEmpty ? "播放" : name
    }
}

// MARK: - 尺寸

enum PlayerLayout {
    static let topBar: CGFloat = 32
    static let bottomBar: CGFloat = 40

    static func size(mode: PlayerMode, container: CGSize) -> CGSize {
        switch mode {
        case .mini:
            let width = min(max(container.width - 80, 200), 288)
            let video = (width * 9 / 16).rounded()
            return CGSize(width: width, height: video + topBar + bottomBar)
        case .wide:
            let width = max(container.width - 16, 200)
            let video = (width * 9 / 16).rounded()
            return CGSize(width: width, height: video + topBar + bottomBar)
        case .full:
            return container
        }
    }

    static func dragLimit(mode: PlayerMode, container: CGSize, window: CGSize) -> CGSize {
        guard mode == .mini else { return .zero }
        return CGSize(
            width: max((container.width - window.width) / 2 - 12, 0),
            height: max(container.height - window.height - 40, 0)
        )
    }
}

// MARK: - 小窗拖动

/// 小窗拖动。
///
/// 偏移量用 `@GestureState` 承载，手势期间只有这个 modifier 重算，
/// 内部的播放器视图树不会重建 —— 这是拖动不卡的关键。
struct WindowDragModifier: ViewModifier {
    @Binding var offset: CGSize
    let enabled: Bool
    let limit: CGSize

    @GestureState private var translation: CGSize = .zero

    private func clamp(_ value: CGSize) -> CGSize {
        CGSize(
            width: min(max(value.width, -limit.width), limit.width),
            height: min(max(value.height, -4), limit.height)
        )
    }

    func body(content: Content) -> some View {
        // 非小窗模式必须把偏移归零，否则拖过位置后再切全屏会带着偏移跑偏
        let live = enabled
            ? clamp(
                CGSize(
                    width: offset.width + translation.width,
                    height: offset.height + translation.height
                )
            )
            : .zero
        content
            .offset(x: live.width, y: live.height)
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .updating($translation) { value, state, _ in
                        guard enabled else { return }
                        state = value.translation
                    }
                    .onEnded { value in
                        guard enabled else { return }
                        offset = clamp(
                            CGSize(
                                width: offset.width + value.translation.width,
                                height: offset.height + value.translation.height
                            )
                        )
                    },
                including: enabled ? .all : .none
            )
    }
}

// MARK: - HUD

struct HUDContent: Equatable {
    let icon: String
    let text: String
    let progress: Double?
}

/// HUD 调度器：用引用类型持有 token，避免多次手势叠加时旧回调清掉新 HUD
final class HUDCenter: ObservableObject {
    @Published private(set) var content: HUDContent?

    private var token = 0

    func show(_ content: HUDContent) {
        token += 1
        let current = token
        self.content = content
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.token == current else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self.content = nil
            }
        }
    }
}
