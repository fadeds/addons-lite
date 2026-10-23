import UIKit
import MediaPlayer
import AVFoundation

/// 通过 MPVolumeView 读取/设置系统音量。
final class SystemVolume {
    static let shared = SystemVolume()

    private let volumeView = MPVolumeView(frame: .zero)

    private var slider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    private init() {
        volumeView.showsRouteButton = false
        volumeView.alpha = 0.01
        volumeView.frame = CGRect(x: -2000, y: -2000, width: 80, height: 40)
    }

    var value: Float {
        ensureInstalled()
        return slider?.value ?? AVAudioSession.sharedInstance().outputVolume
    }

    func set(_ newValue: Float) {
        ensureInstalled()
        let clamped = min(max(newValue, 0), 1)
        if let slider {
            slider.value = clamped
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.slider?.value = clamped
            }
        }
    }

    private func ensureInstalled() {
        guard volumeView.superview == nil else { return }

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first

        window?.addSubview(volumeView)
        volumeView.setNeedsLayout()
        volumeView.layoutIfNeeded()
    }
}
