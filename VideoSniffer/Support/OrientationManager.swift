import UIKit

/// 屏幕方向控制。
///
/// iOS 16 起，仅修改 `supportedInterfaceOrientationsFor` 的返回值不会立刻生效：
/// 必须让 UIKit 重新查询一次（`setNeedsUpdateOfSupportedInterfaceOrientations`），
/// 再用 `requestGeometryUpdate` 主动请求旋转。
///
/// 还有一个坑：这两个动作都不能和 SwiftUI 的布局更新挤在同一帧里。
/// 视图形态刚切换时同步请求，系统会判定"场景/控制器尚未就绪"而拒绝，
/// 表现就是"点了全屏只放大、不横屏"。所以每次请求前先让出一帧。
final class OrientationManager {
    static let shared = OrientationManager()

    /// 旋转请求彻底失败（多为系统"竖排方向锁定"开启）。AppState 监听后给用户提示。
    static let rotationFailed = Notification.Name("VideoSniffer.rotationFailed")

    /// AppDelegate 从这里取当前允许的方向
    private(set) var allowed: UIInterfaceOrientationMask = .portrait

    private init() {}

    func lockPortrait() {
        apply(.portrait, requesting: .portrait)
    }

    func lockLandscape() {
        apply(.landscape, requesting: .landscapeRight)
    }

    // MARK: - 内部

    private func apply(
        _ mask: UIInterfaceOrientationMask,
        requesting orientation: UIInterfaceOrientationMask
    ) {
        allowed = mask
        // 让出当前帧，等 SwiftUI 把新布局提交完
        DispatchQueue.main.async { [weak self] in
            self?.perform(orientation, attempt: 0)
        }
    }

    private func perform(_ orientation: UIInterfaceOrientationMask, attempt: Int) {
        guard let scene = Self.activeScene else { return }

        // 每轮都让 UIKit 重新查询一次（AppDelegate 会读 allowed）
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }

        // 方向重查是下一轮 runloop 生效，立刻请求会被判为方向不受支持
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in
                // 只有失败才会回调；场景未激活、布局未稳定、用户开了方向锁都会走到这里
                guard let self else { return }
                guard attempt < 3 else {
                    // 重试耗尽：最常见的原因是系统「竖排方向锁定」还开着
                    NotificationCenter.default.post(name: Self.rotationFailed, object: nil)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(attempt + 1)) {
                    self.perform(orientation, attempt: attempt + 1)
                }
            }
        }
    }

    static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}
