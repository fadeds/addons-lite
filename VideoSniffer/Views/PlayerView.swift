import SwiftUI
import UIKit
import KSPlayer

/// 播放器视图：只负责"长什么样 + 怎么交互"，播放状态全部交给 PlayerModel。
///
/// 两种形态：
/// - mini：浮窗，视频区拖动 = 移动窗口，底栏带进度条
/// - full：全屏横屏，视频区手势控制进度/亮度/音量
struct PlayerView: View {
    let url: URL
    var referer: String?

    /// 小窗偏移由宿主持有，这里只负责展示与写入
    var windowOffset: CGSize = .zero
    var windowOffsetLimit: CGSize = .zero
    var onWindowOffsetChange: (CGSize) -> Void = { _ in }

    @EnvironmentObject private var appState: AppState
    @StateObject private var model: PlayerModel
    @StateObject private var hud = HUDCenter()

    @State private var scrubProgress: Double?

    @State private var dragMode: DragMode = .none
    @State private var dragAnchor: Double = 0
    @State private var seekTarget: Double = 0
    /// 小窗拖动的起始偏移（手势开始时记录）
    @State private var windowDragAnchor: CGSize?

    private enum DragMode { case none, seek, brightness, volume }

    init(
        url: URL,
        referer: String? = nil,
        windowOffset: CGSize = .zero,
        windowOffsetLimit: CGSize = .zero,
        onWindowOffsetChange: @escaping (CGSize) -> Void = { _ in }
    ) {
        self.url = url
        self.referer = referer
        self.windowOffset = windowOffset
        self.windowOffsetLimit = windowOffsetLimit
        self.onWindowOffsetChange = onWindowOffsetChange
        _model = StateObject(wrappedValue: PlayerModel(url: url, referer: referer))
    }

    private var isFull: Bool { appState.playerMode == .full }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let topH = isFull ? 0 : PlayerLayout.topBar
            let botH = isFull ? 0 : PlayerLayout.bottomBar
            let videoH = max(geo.size.height - topH - botH, 1)
            let videoSize = CGSize(width: geo.size.width, height: videoH)

            // 结构以 v0.1.40 为基准（那版用户确认过小窗顶栏可点）：
            // ZStack + 显式 zIndex 分层，控制层整块压在 10 上。
            ZStack(alignment: .top) {
                Color.black
                    .zIndex(0)

                // 渲染层全树唯一实例：按 mode 拆成两棵子树会让 KSPlayer 的
                // UIView 被搬家，画面冻结但音频继续。
                PlayerSurface(player: model.layer)
                    .frame(width: geo.size.width, height: videoH)
                    .padding(.top, topH)
                    .allowsHitTesting(false)
                    .clipped()
                    .zIndex(1)

                interactionLayer(size: videoSize)
                    .frame(width: geo.size.width, height: videoH)
                    .padding(.top, topH)
                    .zIndex(2)

                statusOverlay
                    .frame(width: geo.size.width, height: videoH)
                    .padding(.top, topH)
                    .allowsHitTesting(false)
                    .zIndex(3)

                if let content = hud.content {
                    hudView(content)
                        .frame(width: geo.size.width, height: videoH)
                        .padding(.top, topH)
                        .zIndex(4)
                }

                if isFull {
                    VStack(spacing: 0) {
                        fullTopBar
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .zIndex(10)

                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        fullBottomBar
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .zIndex(10)
                } else {
                    VStack(spacing: 0) {
                        compactTopBar
                        Spacer(minLength: 0)
                        compactBottomBar
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .zIndex(10)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(
                RoundedRectangle(cornerRadius: isFull ? 0 : 12, style: .continuous)
            )
            .overlay {
                if !isFull {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(Color.black)
        .statusBarHidden(isFull)
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

    /// 视频区手势层：双击播放/暂停；全屏时拖动调进度/亮度/音量
    private func interactionLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(videoGesture(size: size))
            .onTapGesture(count: 2) { model.togglePlay() }
    }

    // MARK: - 顶栏

    private var compactTopBar: some View {
        HStack(spacing: 6) {
            // 拖动手柄：拖拽只在这 30pt 宽的区域生效。
            // 之前把 DragGesture 包在整窗上，会把顶栏/底栏按钮的 tap 全部吞掉。
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 30, height: PlayerLayout.topBar)
                .contentShape(Rectangle())
                .gesture(windowDragGesture)

            Text(displayName)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            Spacer(minLength: 6)

            // 控制条按钮统一用 UIKit 的 UIButton：
            // SwiftUI 的 Button / onTapGesture 在这个浮层里收不到触摸
            BarButton(systemName: "arrow.up.left.and.arrow.down.right") {
                appState.playerMode = .full
            }
            .frame(width: 34, height: PlayerLayout.topBar)

            BarButton(systemName: "xmark") {
                close()
            }
            .frame(width: 34, height: PlayerLayout.topBar)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: PlayerLayout.topBar)
        .background(Color.black.opacity(0.5))
    }

    /// 小窗拖动：只挂在顶栏手柄上
    private var windowDragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if windowDragAnchor == nil { windowDragAnchor = windowOffset }
                let start = windowDragAnchor ?? windowOffset
                var next = CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                )
                next.width = min(max(next.width, -windowOffsetLimit.width), windowOffsetLimit.width)
                next.height = min(max(next.height, 0), windowOffsetLimit.height)
                onWindowOffsetChange(next)
            }
            .onEnded { _ in windowDragAnchor = nil }
    }

    private var fullTopBar: some View {
        HStack(spacing: 12) {
            BarButton(systemName: "xmark", pointSize: 14) {
                close()
            }
            .frame(width: 40, height: 40)
            .background(Circle().fill(.black.opacity(0.4)))

            Text(displayName)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            Spacer(minLength: 8)

            BarTextButton(title: "小窗 ") {
                appState.playerMode = .mini
            }
            .fixedSize()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 40)
        .padding(.top, 10)
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

    /// 小窗/宽窗底栏：进度条常显 + 倍速
    private var compactBottomBar: some View {
        HStack(spacing: 8) {
            BarButton(
                systemName: model.isPlaying ? "pause.fill" : "play.fill",
                pointSize: 12
            ) {
                model.togglePlay()
            }
            .frame(width: 32, height: PlayerLayout.bottomBar)

            progressSlider

            Text("\(model.timeText)/\(model.durationText)")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()

            speedMenuCompact
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: PlayerLayout.bottomBar)
        .background(Color.black.opacity(0.5))
    }

    private var speedMenuCompact: some View {
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
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 30, height: 20)
                .background(.white.opacity(0.14), in: Capsule())
        }
    }

    private var fullBottomBar: some View {
        VStack(spacing: 2) {
            progressSlider
                .padding(.horizontal, 4)

            HStack(spacing: 16) {
                BarButton(
                    systemName: model.isPlaying ? "pause.fill" : "play.fill",
                    pointSize: 20
                ) {
                    model.togglePlay()
                }
                .frame(width: 44, height: 36)

                Text("\(model.timeText) / \(model.durationText)")
                    .font(.caption.monospacedDigit())

                Spacer()

                speedMenu
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 6)
        .padding(.bottom, 18)
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
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                // 只服务于全屏的进度/亮度/音量；小窗不挂这个手势
                guard isFull else { return }
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
                guard isFull else { return }
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
            // 小窗充满宽度（左右各留 12pt），高度按 16:9 + 控制条
            let width = max(container.width - 24, 200)
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
