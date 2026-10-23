import Foundation
import UIKit

/// 跨隔离域传递后台 URLSession 完成回调
final class BackgroundCompletionBox: @unchecked Sendable {    static let shared = BackgroundCompletionBox()

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

enum DownloadOutcome {
    case success(String)
    case failure(String)
}

/// 在 didFinishDownloadingTo 与 didCompleteWithError 之间同步落盘结果，避免并发任务乱序
final class DownloadResultBox: @unchecked Sendable {
    static let shared = DownloadResultBox()

    private let lock = NSLock()
    private var results: [String: DownloadOutcome] = [:]

    func store(_ result: DownloadOutcome, for id: String) {
        lock.lock()
        results[id] = result
        lock.unlock()
    }

    func take(_ id: String) -> DownloadOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return results.removeValue(forKey: id)
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
        pruneMissingFiles()
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
                backgroundSession.getAllTasks { [weak self] sessionTasks in
                    let download = sessionTasks.first(where: { $0.taskDescription == id })
                    Task { @MainActor [weak self] in
                        if let download {
                            download.cancel()
                        } else {
                            self?.markCancelledIfActive(id: id)
                        }
                    }
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

    /// 文件被外部删除后，同步清掉对应任务记录，避免列表残留
    func forgetFile(named fileName: String) {
        let before = tasks.count
        tasks.removeAll { $0.fileName == fileName }
        if tasks.count != before { persist() }
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

    /// 已完成但文件已被删除（如从「文件」App 中删掉）的记录不再保留
    private func pruneMissingFiles() {
        let fm = FileManager.default
        let before = tasks.count
        tasks.removeAll { record in
            guard record.state == .completed, let name = record.fileName else { return false }
            let url = Storage.downloadsURL.appendingPathComponent(name)
            return !fm.fileExists(atPath: url.path)
        }
        if tasks.count != before { persist() }
    }

    private func markCancelledIfActive(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].isActive else { return }
        tasks[index].state = .cancelled
        tasks[index].finishedAt = .now
        persist()
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
            guard tasks.contains(where: { $0.id == id }) else {
                // 任务记录已被移除：删除刚落地的文件，避免孤儿文件残留
                try? FileManager.default.removeItem(at: fileURL)
                hlsTasks[id] = nil
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
            DownloadResultBox.shared.store(
                .failure("HTTP \(http.statusCode)（服务器拒绝访问，可能需要 Referer/Cookie）"),
                for: id
            )
            return
        }

        do {
            let suggested = downloadTask.response?.suggestedFilename
            let rawName = suggested ?? "video_\(Int(Date().timeIntervalSince1970)).mp4"
            let destination = Storage.uniqueDestination(
                fileName: Storage.sanitizeFileName(rawName)
            )
            try FileManager.default.moveItem(at: location, to: destination)
            DownloadResultBox.shared.store(.success(destination.lastPathComponent), for: id)
        } catch {
            DownloadResultBox.shared.store(
                .failure("保存文件失败：\(error.localizedDescription)"),
                for: id
            )
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
            let stored = DownloadResultBox.shared.take(id)
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 已落盘但任务报错：删除文件，避免残留
                if case .some(.success(let name)) = stored {
                    try? FileManager.default.removeItem(
                        at: Storage.downloadsURL.appendingPathComponent(name)
                    )
                }
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

        // 无错误：以 didFinishDownloadingTo 同步记录的落盘结果为准
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = DownloadResultBox.shared.take(id)
            guard let index = self.tasks.firstIndex(where: { $0.id == id }) else {
                // 记录已被删除：清理刚落地的文件，避免孤儿文件残留
                if case .some(.success(let name)) = result {
                    try? FileManager.default.removeItem(
                        at: Storage.downloadsURL.appendingPathComponent(name)
                    )
                }
                return
            }

            switch result {
            case .some(.success(let name)):
                self.tasks[index].state = .completed
                self.tasks[index].progress = 1.0
                self.tasks[index].fileName = name
                self.tasks[index].errorMessage = nil
                self.tasks[index].finishedAt = .now
            case .some(.failure(let message)):
                self.tasks[index].state = .failed
                self.tasks[index].errorMessage = message
                self.tasks[index].finishedAt = .now
            case .none:
                if let name = self.tasks[index].fileName, !name.isEmpty {
                    self.tasks[index].state = .completed
                    self.tasks[index].progress = 1.0
                    self.tasks[index].errorMessage = nil
                    self.tasks[index].finishedAt = .now
                } else {
                    self.tasks[index].state = .failed
                    self.tasks[index].errorMessage = "下载结果未知（服务端未返回文件）"
                    self.tasks[index].finishedAt = .now
                }
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
