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
            guard let videoURL = value("url") ?? value("u"),
                  !videoURL.isEmpty,
                  URL(string: videoURL) != nil
            else { return nil }
            let video = VideoInfo(
                url: videoURL,
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
