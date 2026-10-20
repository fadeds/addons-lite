import Foundation

enum VideoKind: String, Codable, Hashable {
    case hls
    case mp4
    case flv
    case webm
    case other

    var label: String {
        switch self {
        case .hls: return "HLS"
        case .mp4: return "MP4"
        case .flv: return "FLV"
        case .webm: return "WEBM"
        case .other: return "视频"
        }
    }
}

struct VideoInfo: Identifiable, Codable, Hashable {
    enum Source: String, Codable {
        case extensionDetection
        case manual
        case clipboard
        case deeplink
    }

    var id: String = UUID().uuidString
    var url: String
    var referer: String?
    var pageTitle: String?
    var source: Source = .extensionDetection
    var detectedAt: Date = .now

    init(
        id: String = UUID().uuidString,
        url: String,
        referer: String? = nil,
        pageTitle: String? = nil,
        source: Source = .extensionDetection,
        detectedAt: Date = .now
    ) {
        self.id = id
        self.url = url
        self.referer = referer
        self.pageTitle = pageTitle
        self.source = source
        self.detectedAt = detectedAt
    }

    var parsedURL: URL? { URL(string: url) }

    var host: String { parsedURL?.host ?? url }

    var isHLS: Bool { url.lowercased().contains("m3u8") }

    var kind: VideoKind {
        guard !isHLS else { return .hls }
        let u = url.lowercased()
        if u.contains(".mp4") { return .mp4 }
        if u.contains(".flv") { return .flv }
        if u.contains(".webm") { return .webm }
        return .other
    }

    var displayTitle: String {
        if let t = pageTitle, !t.isEmpty { return t }
        if let last = parsedURL?.lastPathComponent, !last.isEmpty, last != "/" { return last }
        return host
    }

    var shortFileName: String {
        guard let last = parsedURL?.lastPathComponent, !last.isEmpty, last.contains(".") else {
            return "video_\(Int(detectedAt.timeIntervalSince1970))"
        }
        return last
    }
}
