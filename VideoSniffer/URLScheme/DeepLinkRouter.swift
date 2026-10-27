import Foundation

enum DeepLinkAction {
    case addVideo(VideoInfo)
    case checkUpdate
    case showDownloads
}

enum DeepLinkRouter {
    static let scheme = "videosniffer"

    static func parse(_ url: URL) -> DeepLinkAction? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let host = (components.host ?? "").lowercased()
        let items = components.queryItems ?? []

        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        switch host {
        case "add", "download":
            // 深链来自任意 App / 任意网页，必须锁死 http(s)。
            // 否则 file:// 之类会被直接塞进下载队列，落地文件还能通过「文件」App 取走。
            guard let raw = value("url") ?? value("u"),
                  let videoURL = URL(string: raw),
                  let videoScheme = videoURL.scheme?.lowercased(),
                  videoScheme == "http" || videoScheme == "https",
                  let videoHost = videoURL.host,
                  !videoHost.isEmpty
            else { return nil }
            let video = VideoInfo(
                url: raw,
                referer: value("referer") ?? value("page"),
                pageTitle: value("title"),
                source: .deeplink
            )
            return .addVideo(video)

        case "update", "check-update", "check":
            return .checkUpdate

        case "downloads", "tasks":
            return .showDownloads

        default:
            return nil
        }
    }
}
