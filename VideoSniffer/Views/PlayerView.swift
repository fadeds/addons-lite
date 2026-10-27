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

            ZStack(alignment: .top) {
                Color.black
                    .zIndex(0)

                // 渲染层必须是全树唯一实例。
                // 一旦按 mode 拆成两棵子树，切全屏时 SwiftUI 会销毁旧容器、
                // 把 KSPlayer 的 UIView 搬到新容器，画面立刻冻结（音频还在跑）。
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

                // 控制层：全屏拆成"顶部半区 / 底部半区"两个独立层，
                // 都压在 zIndex(10) 上。之前是一个撑满全屏的 VStack，
                // 配合下层手势层会把按钮点击吞掉。
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
        // 小窗偏移只在这里应用：偏移量变化只会移动渲染位置，不影响任何子视图的身份
        .offset(
            x: isFull ? 0 : windowOffset.width,
            y: isFull ? 0 : windowOffset.height
        )
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

    /// 视频区手势层
    private func interactionLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(videoGesture(size: size))
            .onTapGesture { model.togglePlay() }
    }

    // MARK: - 顶栏

    private var compactTopBar: some View {
        HStack(spacing: 8) {
            // 原来是纯装饰的三横杠，点了没反应容易被当成"卡死"。
            // 换成播放/暂停，点击立即有反馈；顶栏其余区域仍可拖动窗口。
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }

            Text(displayName)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            Spacer(minLength: 6)

            iconButton("arrow.up.left.and.arrow.down.right") {
                appState.playerMode = .full
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
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                // 小窗：拖视频区就是移动窗口。
                // 手势只存在于此层，不会和顶栏/底栏的按钮抢触摸。
                guard isFull else {
                    moveWindow(with: value)
                    return
                }
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
                guard isFull else {
                    windowDragAnchor = nil
                    return
                }
                if dragMode == .seek {
                    model.seek(to: seekTarget)
                }
                dragMode = .none
            }
    }

    private func moveWindow(with value: DragGesture.Value) {
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
