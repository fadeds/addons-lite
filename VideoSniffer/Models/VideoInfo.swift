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

    /// 与 Safari 扩展保持一致的直链判定：后缀后必须是 ? # 或结尾，
    /// 避免把 m3u8player / .mp4x 这类路径误判成视频地址
    private static let mediaExtensions = ["m3u8", "mp4", "m4v", "mov", "flv", "webm"]

    private var matchedExtension: String? {
        let lower = url.lowercased()
        for ext in Self.mediaExtensions {
            let needle = "." + ext
            guard let range = lower.range(of: needle) else { continue }
            let after = lower.index(after: range.upperBound)
            guard after < lower.endIndex else { return ext }
            if lower[after] == "?" || lower[after] == "#" { return ext }
        }
        return nil
    }

    var isHLS: Bool { matchedExtension == "m3u8" }

    var kind: VideoKind {
        switch matchedExtension {
        case "m3u8": return .hls
        case "mp4", "m4v", "mov": return .mp4
        case "flv": return .flv
        case "webm": return .webm
        case nil: return .other
        }
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
