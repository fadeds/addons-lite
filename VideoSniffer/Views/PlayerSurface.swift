import SwiftUI
import UIKit
import KSPlayer

/// 把 KSPlayer 的渲染视图挂进 SwiftUI。
///
/// 铁律：`updateUIView` 只做"一次性挂载"，**绝不修改 frame**。
/// 拖动小窗时 SwiftUI 每帧都会调用 updateUIView，若在这里改 frame 就会触发
/// UIView 布局 → SwiftUI 重新布局 的反馈环，主线程直接被拖死（表现为卡死）。
/// 尺寸交给 autoresizingMask 和容器自身的 layoutSubviews 处理。
struct PlayerSurface: UIViewRepresentable {
    let player: KSPlayerLayer

    func makeUIView(context: Context) -> PlayerSurfaceContainer {
        let container = PlayerSurfaceContainer()
        container.backgroundColor = .black
        container.isUserInteractionEnabled = false
        container.attach(player.player.view)
        return container
    }

    func updateUIView(_ uiView: PlayerSurfaceContainer, context: Context) {
        uiView.attach(player.player.view)
    }
}

final class PlayerSurfaceContainer: UIView {
    func attach(_ surface: UIView?) {
        guard let surface else { return }
        // 已经挂在本容器里就绝不再动它。
        // 反复 remove/add 会让 KSPlayer 的渲染层重新绑定，表现为画面冻结。
        if surface.superview === self { return }

        surface.removeFromSuperview()
        surface.backgroundColor = .black
        surface.isUserInteractionEnabled = false
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.frame = bounds
        addSubview(surface)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let mounted = subviews.first, mounted.frame != bounds else { return }
        mounted.frame = bounds
    }
}
