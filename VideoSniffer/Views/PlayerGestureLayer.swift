import SwiftUI
import UIKit

/// 视频区手势层。
///
/// 与控制条按钮同理：SwiftUI 的 DragGesture / onTapGesture 在这个浮层里
/// 命中测试不可靠，改用 UIKit 的识别器，逻辑仍留在 SwiftUI 侧处理。
struct PlayerGestureLayer: UIViewRepresentable {
    var onPanBegan: (CGSize, CGPoint) -> Void = { _, _ in }
    var onPanChanged: (CGSize, CGFloat, CGFloat) -> Void = { _, _, _ in }
    var onPanEnded: () -> Void = {}
    var onSingleTap: () -> Void = {}
    var onDoubleTap: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isMultipleTouchEnabled = false

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        // 双击优先：单击要等双击失败才触发
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap)
        )
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap)
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)

        context.coordinator.host = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: PlayerGestureLayer
        weak var host: UIView?

        init(_ parent: PlayerGestureLayer) {
            self.parent = parent
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let host else { return }
            let size = host.bounds.size
            switch gesture.state {
            case .began:
                parent.onPanBegan(size, gesture.location(in: host))
            case .changed:
                let delta = gesture.translation(in: host)
                parent.onPanChanged(size, delta.x, delta.y)
            case .ended, .cancelled, .failed:
                parent.onPanEnded()
            default:
                break
            }
        }

        @objc func handleSingleTap() {
            parent.onSingleTap()
        }

        @objc func handleDoubleTap() {
            parent.onDoubleTap()
        }
    }
}

/// 小窗拖动手柄：同样用 UIKit 识别器
struct PlayerDragHandle: UIViewRepresentable {
    var onChanged: (CGFloat, CGFloat) -> Void
    var onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        context.coordinator.host = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: PlayerDragHandle
        weak var host: UIView?

        init(_ parent: PlayerDragHandle) {
            self.parent = parent
        }

        @objc func handle(_ gesture: UIPanGestureRecognizer) {
            guard let host else { return }
            // 用 window 作参考系，避免父视图变化时位移抖动
            let translation = gesture.translation(in: host.window)
            switch gesture.state {
            case .began, .changed:
                parent.onChanged(translation.x, translation.y)
            case .ended, .cancelled, .failed:
                parent.onEnded()
            default:
                break
            }
        }
    }
}

