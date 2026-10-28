import SwiftUI
import UIKit

/// 用 UIKit 按钮替代 SwiftUI Button。
///
/// 背景：在这台设备上，浮层里的 SwiftUI Button / onTapGesture 全部收不到触摸
/// （连点击回调都不触发），但同一个容器里的 Slider、Menu 却正常。
/// UIKit 的 hitTest 是确定性的，因此控制条上的按钮统一改用 UIButton。
struct BarButton: UIViewRepresentable {
    let systemName: String
    var pointSize: CGFloat = 13
    var tint: UIColor = .white
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(
            UIImage(
                systemName: systemName,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: pointSize,
                    weight: .bold
                )
            ),
            for: .normal
        )
        button.tintColor = tint
        button.backgroundColor = .clear
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleTap),
            for: .touchUpInside
        )
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.action = action
        uiView.setImage(
            UIImage(
                systemName: systemName,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: pointSize,
                    weight: .bold
                )
            ),
            for: .normal
        )
        uiView.tintColor = tint
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func handleTap() {
            action()
        }
    }
}

/// UIKit 文本按钮（全屏里的「小窗」胶囊）
struct BarTextButton: UIViewRepresentable {
    let title: String
    let action: () -> Void

    func makeCoordinator() -> BarButton.Coordinator {
        BarButton.Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        button.layer.cornerRadius = 15
        button.contentEdgeInsets = UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        button.addTarget(
            context.coordinator,
            action: #selector(BarButton.Coordinator.handleTap),
            for: .touchUpInside
        )
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.action = action
        uiView.setTitle(title, for: .normal)
    }
}
