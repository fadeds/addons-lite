import AVFoundation
import Foundation
import KSPlayer

/// 播放器状态机。
///
/// 只负责"播放"这一件事：进度、时长、播放/暂停、倍速、跳转。
/// 不持有任何布局或手势状态——那些属于 PlayerView。
///
/// 关键点：`currentTime` 回调频率可达每秒数十次，若每次都写 `@Published`
/// 会让 SwiftUI 反复重建整个播放器视图（含 UIViewRepresentable），
/// 这是拖动小窗时卡死的主因，所以这里做了 0.25s 节流。
final class PlayerModel: NSObject, ObservableObject, KSPlayerLayerDelegate {
    enum Status: Equatable {
        case idle
        case preparing
        case playing
        case paused
        case ended
        case failed(String)
    }

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

    let layer: KSPlayerLayer

    @Published private(set) var status: Status = .idle
    @Published private(set) var isBuffering = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var timeText = "00:00"
    @Published private(set) var durationText = "--:--"
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Double = 1

    private var started = false
    private var stopped = false
    private var scrubbing = false
    private var didConfigureAudio = false
    private var lastTick = Date.distantPast
    private var stallToken = 0

    var isPlaying: Bool { status == .playing }

    var errorMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    init(url: URL, referer: String?) {
        let options = KSOptions()
        options.isAccurateSeek = true
        options.registerRemoteControll = false
        options.referer = referer

        layer = KSPlayerLayer(url: url, isAutoPlay: false, options: options)
        super.init()

        layer.delegate = self
        layer.player.contentMode = .scaleAspectFit
        layer.player.view?.backgroundColor = .black
    }

    deinit {
        // 只解绑，不在这里调 stop：deinit 可能落在非主线程，
        // 而 KSPlayer 的 stop 需要主线程，是"偶发卡死/崩溃"的来源之一。
        layer.delegate = nil
    }

    // MARK: - 生命周期

    func start() {
        guard !started, !stopped else { return }
        started = true
        status = .preparing
        isBuffering = true
        play()
        armStallWatch(seconds: 20)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        stallToken += 1 // 让待触发的兜底回调失效
        layer.delegate = nil
        layer.stop()
        isBuffering = false
    }

    // MARK: - 播放控制

    func play() {
        guard !stopped else { return }
        configureAudioIfNeeded()
        layer.play()
    }

    func togglePlay() {
        guard !stopped else { return }
        if status == .ended {
            seek(to: 0)
            play()
            return
        }
        if layer.state.isPlaying {
            layer.pause()
        } else {
            play()
        }
    }

    func setRate(_ value: Double) {
        rate = value
        layer.player.playbackRate = Float(value)
    }

    // MARK: - 进度

    func beginScrub() {
        scrubbing = true
    }

    func endScrub() {
        scrubbing = false
        lastTick = .distantPast
    }

    /// 按 0...1 的比例跳转
    func seek(to progress: Double) {
        guard duration > 0, !stopped else { return }
        let clamped = min(max(progress, 0), 1)
        let target = clamped * duration

        self.progress = clamped
        timeText = Self.formatTime(target)

        // 注意：seek 期间不要显示 loading。
        // KSPlayer 在 player.seekable == false 时只把目标时间存起来并回调 false，
        // 不会再发 .bufferFinished，一旦显示 loading 就会永远卡住。
        layer.seek(time: target, autoPlay: layer.state.isPlaying) { _ in }

        // 回调可能不触发（播放器未就绪等），兜底收掉可能残留的 loading
        armStallWatch(seconds: 3)
    }

    // MARK: - KSPlayerLayerDelegate

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard !stopped else { return }
        switch state {
        case .initialized:
            if !started { status = .idle }
        case .preparing, .readyToPlay:
            isBuffering = true
        case .buffering:
            isBuffering = true
            if status != .paused { status = .playing }
        case .bufferFinished:
            isBuffering = false
            status = .playing
            applyRateIfNeeded()
        case .paused:
            isBuffering = false
            status = .paused
        case .playedToTheEnd:
            isBuffering = false
            status = .ended
            progress = 1
            timeText = durationText
        case .error:
            isBuffering = false
            status = .failed("播放失败：格式不支持或文件损坏")
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        guard !stopped else { return }
        updateDuration(totalTime)
        guard !scrubbing, currentTime.isFinite else { return }

        // 节流：4Hz 足够流畅，又不会把主线程拖垮
        let now = Date()
        guard now.timeIntervalSince(lastTick) >= 0.25 else { return }
        lastTick = now

        let clamped = max(0, currentTime)
        timeText = Self.formatTime(clamped)
        if duration > 0 {
            progress = min(max(clamped / duration, 0), 1)
        }
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard !stopped else { return }
        isBuffering = false
        if error != nil {
            status = .failed("播放失败：格式不支持或文件损坏")
        } else {
            status = .ended
            progress = 1
            timeText = durationText
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        _ = layer
        _ = bufferedCount
        _ = consumeTime
    }

    // MARK: - 内部

    private func applyRateIfNeeded() {
        let target = Float(rate)
        if abs(layer.player.playbackRate - target) > 0.01 {
            layer.player.playbackRate = target
        }
    }

    private func updateDuration(_ value: TimeInterval) {
        guard value.isFinite, value > 0, abs(value - duration) > 0.5 else { return }
        duration = value
        durationText = Self.formatTime(value)
    }

    /// loading 兜底：状态回调丢失时，到期后强制收掉 loading
    private func armStallWatch(seconds: TimeInterval) {
        stallToken += 1
        let token = stallToken
        // 必须回主线程改 @Published，且用 token 防止旧回调盖掉新状态
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.stallToken == token, !self.stopped, self.isBuffering else {
                return
            }
            self.isBuffering = false
            if self.status == .preparing { self.status = .playing }
        }
    }

    private func configureAudioIfNeeded() {
        guard !didConfigureAudio else { return }
        didConfigureAudio = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}
