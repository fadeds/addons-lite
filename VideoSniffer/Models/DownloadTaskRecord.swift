import Foundation

struct DownloadTaskRecord: Identifiable, Codable, Hashable {
    enum State: String, Codable {
        case queued
        case downloading
        case remuxing
        case completed
        case failed
        case cancelled
    }

    var id: String = UUID().uuidString
    var video: VideoInfo
    var state: State = .queued
    var progress: Double = 0
    var totalBytes: Int64?
    var receivedBytes: Int64?
    var fileName: String?
    var errorMessage: String?
    var createdAt: Date = .now
    var finishedAt: Date?

    init(video: VideoInfo) {
        self.video = video
    }

    var isActive: Bool {
        switch state {
        case .queued, .downloading, .remuxing: return true
        case .completed, .failed, .cancelled: return false
        }
    }

    var stateLabel: String {
        switch state {
        case .queued: return "等待中"
        case .downloading: return "下载中"
        case .remuxing: return "转封装中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}
