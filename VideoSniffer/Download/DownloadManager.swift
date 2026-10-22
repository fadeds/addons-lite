import Foundation
import UIKit

/// 跨隔离域传递后台 URLSession 完成回调
final class BackgroundCompletionBox: @unchecked Sendable {
    static let shared = BackgroundCompletionBox()

    private let lock = NSLock()
    private var _handler: (() -> Void)?

    var handler: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _handler
        }
        set {
            lock.lock()
            _handler = newValue
            lock.unlock()
        }
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    static let tasksFile = "download_tasks.json"
    static let backgroundIdentifier = "com.videosniffer.app.background-downloads"

    @Published private(set) var tasks: [DownloadTaskRecord] = []

    private var hlsTasks: [String: Task<Void, Never>] = [:]
    private var lastPersist = Date.distantPast

    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: DownloadManager.backgroundIdentifier
        )
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        tasks = Storage.load([DownloadTaskRecord].self, from: DownloadManager.tasksFile) ?? []
        restoreInterruptedTasks()
        _ = backgroundSession
    }

    var activeCount: Int {
        tasks.filter { $0.isActive }.count
    }

    // MARK: - 公开接口

    func enqueue(_ video: VideoInfo) {
        guard !tasks.contains(where: { $0.video.url == video.url && $0.isActive }) else {
            return
        }
        let record = DownloadTaskRecord(video: video)
        tasks.insert(record, at: 0)
        persist()
        start(id: record.id)
    }

    func retry(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].state = .queued
        tasks[index].progress = 0
        tasks[index].receivedBytes = nil
        tasks[index].totalBytes = nil
        tasks[index].errorMessage = nil
        tasks[index].finishedAt = nil
        persist()
        start(id: id)
    }

    func cancel(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks[index]

        switch task.state {
        case .queued, .downloading:
            if task.video.isHLS {
                hlsTasks[id]?.cancel()
                hlsTasks[id] = nil
                set(id: id) { record in
                    record.state = .cancelled
                    record.finishedAt = .now
                }
            } else {
                backgroundSession.getAllTasks { sessionTasks in
                    sessionTasks
                        .first(where: { $0.taskDescription == id })?
                        .cancel()
                }
            }
        case .remuxing:
            hlsTasks[id]?.cancel()
            hlsTasks[id] = nil
            set(id: id) { record in
                record.state = .cancelled
                record.finishedAt = .now
            }
        case .completed, .failed, .cancelled:
            break
        }
    }

    func remove(id: String, deleteFile: Bool) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks[index]
        if task.isActive { cancel(id: id) }
        if deleteFile, let fileName = task.fileName {
            let fileURL = Storage.downloadsURL.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        tasks.removeAll { $0.id == id }
        persist()
    }

    func clearFinished() {
        tasks.removeAll { !$0.isActive }
        persist()
    }

    func fileURL(for task: DownloadTaskRecord) -> URL? {
        guard let fileName = task.fileName else { return nil }
        let url = Storage.downloadsURL.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 启动与恢复

    private func restoreInterruptedTasks() {
        var changed = false
        for index in tasks.indices where tasks[index].isActive {
            // HLS 依赖前台流水线，进程重启即中断；直接下载交给后台会话自行恢复
            if tasks[index].video.isHLS {
                tasks[index].state = .failed
                tasks[index].errorMessage = "下载中断，请点击重试"
                changed = true
            }
        }
        if changed { persist() }
    }

    private func start(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let video = tasks[index].video
        tasks[index].state = .downloading
        persist()

        if video.isHLS {
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runHLS(id: id, video: video)
            }
            hlsTasks[id] = task
        } else {
            guard let url = video.parsedURL else {
                finish(id: id, state: .failed, error: "无效链接")
                return
            }
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            if let referer = video.referer {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
            let download = backgroundSession.downloadTask(with: request)
            download.taskDescription = id
            download.resume()
        }
    }

    private func runHLS(id: String, video: VideoInfo) async {
        do {
            let fileURL = try await M3U8Downloader.download(
                video,
                into: Storage.downloadsURL
            ) { [weak self] stage, percent, label in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.set(id: id) { record in
                        record.state = (stage == .remux) ? .remuxing : .downloading
                        record.progress = min(max(percent, 0), 1)
                        _ = label
                    }
                }
            }
            guard !Task.isCancelled else {
                set(id: id) { $0.state = .cancelled; $0.finishedAt = .now }
                return
            }
            set(id: id) { record in
                record.state = .completed
                record.progress = 1.0
                record.fileName = fileURL.lastPathComponent
                record.finishedAt = .now
                record.errorMessage = nil
            }
        } catch is CancellationError {
            set(id: id) { record in
                record.state = .cancelled
                record.finishedAt = .now
            }
        } catch {
            set(id: id) { record in
                record.state = .failed
                record.errorMessage = error.localizedDescription
                record.finishedAt = .now
            }
        }
        hlsTasks[id] = nil
    }

    // MARK: - 状态写入

    private func set(id: String, _ mutate: (inout DownloadTaskRecord) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = tasks[index].isActive
        mutate(&tasks[index])
        if wasActive && !tasks[index].isActive {
            persist() // 进入终态立即落盘
        } else {
            persistThrottled()
        }
    }

    private func finish(id: String, state: DownloadTaskRecord.State, error: String?) {
        set(id: id) { record in
            record.state = state
            record.errorMessage = error
            record.finishedAt = .now
        }
    }

    private func persist() {
        Storage.save(tasks, to: DownloadManager.tasksFile)
        lastPersist = Date()
    }

    private func persistThrottled() {
        if Date().timeIntervalSince(lastPersist) > 1.5 {
            persist()
        }
    }
}

// MARK: - 后台 URLSession 委托

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let status = http.statusCode
            Task { @MainActor [weak self] in
                self?.set(id: id) { record in
                    record.state = .failed
                    record.errorMessage = "HTTP \(status)（服务器拒绝访问，可能需要 Referer/Cookie）"
                    record.finishedAt = .now
                }
            }
            return
        }

        let suggested = downloadTask.response?.suggestedFilename
        var moveError: Error?
        var finalName: String?

        do {
            let rawName = suggested ?? "video_\(Int(Date().timeIntervalSince1970)).mp4"
            let destination = Storage.uniqueDestination(
                fileName: Storage.sanitizeFileName(rawName)
            )
            try FileManager.default.moveItem(at: location, to: destination)
            finalName = destination.lastPathComponent
        } catch {
            moveError = error
        }

        let name = finalName
        let failure = moveError
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let failure {
                self.set(id: id) { record in
                    record.state = .failed
                    record.errorMessage = "保存文件失败：\(failure.localizedDescription)"
                    record.finishedAt = .now
                }
            } else {
                self.set(id: id) { record in
                    record.fileName = name
                }
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription else { return }
        let expected = totalBytesExpectedToWrite
        Task { @MainActor [weak self] in
            self?.set(id: id) { record in
                record.state = .downloading
                record.receivedBytes = totalBytesWritten
                if expected > 0 {
                    record.totalBytes = expected
                    record.progress = Double(totalBytesWritten) / Double(expected)
                }
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let id = task.taskDescription else { return }

        if let error = error as NSError? {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if error.code == NSURLErrorCancelled {
                    self.set(id: id) { record in
                        record.state = .cancelled
                        record.finishedAt = .now
                    }
                } else {
                    self.set(id: id) { record in
                        record.state = .failed
                        record.errorMessage = error.localizedDescription
                        record.finishedAt = .now
                    }
                }
            }
            return
        }

        // 无错误：确认文件已落地
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let index = self.tasks.firstIndex(where: { $0.id == id }) else { return }
            let record = self.tasks[index]
            if record.state != .completed, record.fileName == nil {
                self.tasks[index].state = .failed
                self.tasks[index].errorMessage = "下载结果未知"
                self.tasks[index].finishedAt = .now
            } else if let name = record.fileName {
                self.tasks[index].state = .completed
                self.tasks[index].progress = 1.0
                self.tasks[index].errorMessage = nil
                self.tasks[index].finishedAt = .now
                _ = name
            }
            self.persist()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = BackgroundCompletionBox.shared.handler
        BackgroundCompletionBox.shared.handler = nil
        if let handler {
            DispatchQueue.main.async {
                handler()
            }
        }
    }
}
