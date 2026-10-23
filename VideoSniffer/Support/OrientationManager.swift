import UIKit

/// 控制 App 是否允许横屏：仅播放器界面开启
final class OrientationManager {
    static let shared = OrientationManager()

    var allowLandscape = false
    var userDidOverrideInitialOrientation = false

    private init() {}
}
