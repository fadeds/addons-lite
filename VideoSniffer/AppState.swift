import SwiftUI
import UIKit

@MainActor
final class AppState: ObservableObject {
    static let pendingFile = "pending_videos.json"

    @Published var selectedTab: Int = 0
    @Published var pendingVideos: [VideoInfo] = []
    @Published var toast: String?

    let downloadManager = DownloadManager.shared
    let updateChecker = UpdateChecker()

    private var toastTask: Task<Void, Never>?

    init() {
        pendingVideos = Storage.load([VideoInfo].self, from: AppState.pendingFile) ?? []
    }

    func onLaunch() async {
        Storage.ensureDirectories()
        await updateChecker.autoCheckIfNeeded()
    }

    // MARK: - Deep Link

    func handleDeepLink(_ url: URL) {
        guard let action = DeepLinkRouter.parse(url) else { return }
        switch action {
        case .addVideo(let video):
            addPending(video)
            selectedTab = 0
            showToast("已接收视频链接")
        case .checkUpdate:
            selectedTab = 3
            Task { await updateChecker.checkNow() }
        case .showDownloads:
            selectedTab = 1
        }
    }

    // MARK: - 待下载列表

    func addPending(_ video: VideoInfo) {
        if let index = pendingVideos.firstIndex(where: { $0.url == video.url }) {
            var existing = pendingVideos[index]
            if existing.referer == nil { existing.referer = video.referer }
            if existing.pageTitle == nil { existing.pageTitle = video.pageTitle }
            pendingVideos[index] = existing
        } else {
            pendingVideos.insert(video, at: 0)
        }
        persistPending()
    }

    func removePending(at offsets: IndexSet) {
        pendingVideos.remove(atOffsets: offsets)
        persistPending()
    }

    func removePending(_ video: VideoInfo) {
        pendingVideos.removeAll { $0.id == video.id }
        persistPending()
    }

    func enqueue(_ video: VideoInfo) {
        downloadManager.enqueue(video)
        removePending(video)
        selectedTab = 1
    }

    func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let url = URL(string: text),
              url.scheme?.hasPrefix("http") == true
        else {
            showToast("剪贴板中没有有效链接")
            return
        }
        addPending(VideoInfo(url: text, source: .clipboard))
        showToast("已从剪贴板添加")
    }

    // MARK: - 更新

    func checkUpdate() async {
        await updateChecker.checkNow()
    }

    // MARK: - Toast

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func persistPending() {
        Storage.save(pendingVideos, to: AppState.pendingFile)
    }
}
