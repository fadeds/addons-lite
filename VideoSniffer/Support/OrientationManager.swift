import UIKit

/// 屏幕方向控制。
///
/// iOS 16 起，仅仅修改 `supportedInterfaceOrientationsFor` 的返回值不会立刻生效：
/// 必须让 UIKit 重新查询一次（`setNeedsUpdateOfSupportedInterfaceOrientations`），
/// 再用 `requestGeometryUpdate` 主动请求旋转。缺了前者，表现为"点了全屏只放大、不横屏"。
final class OrientationManager {
    static let shared = OrientationManager()

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
        guard let scene = Self.activeScene else { return }

        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        request(orientation, on: scene, attempt: 0)
    }

    private func request(
        _ orientation: UIInterfaceOrientationMask,
        on scene: UIWindowScene,
        attempt: Int
    ) {
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in
            // 场景未激活、布局未稳定、或用户开了方向锁时会被系统拒绝，短间隔重试
            guard attempt < 2 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * Double(attempt + 1)) {
                self.request(orientation, on: scene, attempt: attempt + 1)
            }
        }
    }

    static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}
