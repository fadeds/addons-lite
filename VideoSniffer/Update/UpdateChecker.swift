import Foundation

struct UpdateInfo: Identifiable, Equatable {
    let version: String
    let tagName: String
    let notes: String
    let htmlURL: URL?
    let manifestAssetURL: URL?
    let ipaAssetURL: URL?
    let prerelease: Bool

    var id: String { tagName }

    static func == (lhs: UpdateInfo, rhs: UpdateInfo) -> Bool {
        lhs.id == rhs.id && lhs.version == rhs.version
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case available(UpdateInfo)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var lastCheckDate: Date?

    static let lastCheckKey = "vs_update_last_check"
    static let dismissedTagKey = "vs_update_dismissed_tag"
    static let repoKey = "update_repo"
    static let prereleaseKey = "update_include_prerelease"
    private static let checkInterval: TimeInterval = 24 * 3600

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var configuredRepo: String {
        let override = UserDefaults.standard.string(forKey: UpdateChecker.repoKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty { return override }
        let infoRepo = Bundle.main.object(forInfoDictionaryKey: "VSUpdateRepo") as? String ?? ""
        return infoRepo.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isRepoConfigured: Bool {
        let repo = configuredRepo
        guard !repo.isEmpty, !repo.hasPrefix("YOUR_NAME") else { return false }
        let parts = repo.split(separator: "/")
        return parts.count == 2 && parts[0].count > 0 && parts[1].count > 0
    }

    // MARK: - 入口

    func autoCheckIfNeeded() async {
        let last = UserDefaults.standard.object(forKey: UpdateChecker.lastCheckKey) as? Date
            ?? .distantPast
        guard Date().timeIntervalSince(last) > UpdateChecker.checkInterval else { return }
        await checkNow(silent: true)
    }

    @discardableResult
    func checkNow(silent: Bool = false) async -> Bool {
        guard phase != .checking else { return false }

        guard isRepoConfigured else {
            if !silent {
                phase = .failed("未配置更新仓库")
            }
            return false
        }

        phase = .checking
        do {
            let info = try await fetchLatestRelease(
                repo: configuredRepo,
                includePrerelease: UserDefaults.standard.bool(forKey: UpdateChecker.prereleaseKey)
            )
            UserDefaults.standard.set(Date(), forKey: UpdateChecker.lastCheckKey)
            lastCheckDate = Date()

            if isNewer(info.version, than: currentVersion) {
                let dismissed = UserDefaults.standard.string(forKey: UpdateChecker.dismissedTagKey)
                if dismissed == info.tagName {
                    phase = .upToDate(current: currentVersion)
                } else {
                    phase = .available(info)
                }
            } else {
                phase = .upToDate(current: currentVersion)
            }
            return true
        } catch {
            if !silent {
                phase = .failed(error.localizedDescription)
            }
            return false
        }
    }

    func dismiss(_ info: UpdateInfo) {
        UserDefaults.standard.set(info.tagName, forKey: UpdateChecker.dismissedTagKey)
        phase = .upToDate(current: currentVersion)
    }

    // MARK: - 版本比较

    func isNewer(_ remote: String, than local: String) -> Bool {
        let r = semanticComponents(remote)
        let l = semanticComponents(local)
        for index in 0..<max(r.count, l.count) {
            let rv = index < r.count ? r[index] : 0
            let lv = index < l.count ? l[index] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    private func semanticComponents(_ version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") {
            text = String(text.dropFirst())
        }
        // 去掉预发布后缀（1.2.3-beta.1 → 1.2.3）
        if let dashIndex = text.firstIndex(of: "-") {
            text = String(text[text.startIndex..<dashIndex])
        }
        return text.split(separator: ".").map { part in
            let digits = part.prefix(while: { $0.isNumber })
            return Int(digits) ?? 0
        }
    }

    // MARK: - GitHub API

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURLString: String
        let body: String
        let prerelease: Bool
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURLString = "html_url"
            case body
            case prerelease
            case assets
        }
    }

    private func fetchLatestRelease(repo: String, includePrerelease: Bool) async throws -> UpdateInfo {
        let endpoint: String
        if includePrerelease {
            endpoint = "https://api.github.com/repos/\(repo)/releases?per_page=5"
        } else {
            endpoint = "https://api.github.com/repos/\(repo)/releases/latest"
        }

        guard let url = URL(string: endpoint) else {
            throw UpdateError.badRepo(repo)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VideoSniffer", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.network("无响应")
        }

        switch http.statusCode {
        case 200:
            break
        case 404:
            throw UpdateError.noRelease
        case 403:
            throw UpdateError.rateLimited
        default:
            throw UpdateError.network("HTTP \(http.statusCode)")
        }

        let release: GitHubRelease
        if includePrerelease {
            let list = try JSONDecoder().decode([GitHubRelease].self, from: data)
            guard let first = list.first else { throw UpdateError.noRelease }
            release = first
        } else {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        }

        var version = release.tagName
        if version.lowercased().hasPrefix("v") {
            version = String(version.dropFirst())
        }

        let manifestAsset = release.assets.first {
            $0.name.lowercased() == "manifest.plist"
        }
        let ipaAsset = release.assets.first {
            $0.name.lowercased().hasSuffix(".ipa")
        }

        return UpdateInfo(
            version: version,
            tagName: release.tagName,
            notes: release.body,
            htmlURL: URL(string: release.htmlURLString),
            manifestAssetURL: manifestAsset.flatMap { URL(string: $0.browserDownloadUrl) },
            ipaAssetURL: ipaAsset.flatMap { URL(string: $0.browserDownloadUrl) },
            prerelease: release.prerelease
        )
    }
}

enum UpdateError: Error, LocalizedError {
    case badRepo(String)
    case noRelease
    case rateLimited
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badRepo(let repo): return "仓库地址无效：\(repo)"
        case .noRelease: return "该仓库还没有发布版本"
        case .rateLimited: return "GitHub API 限流，请稍后再试"
        case .network(let detail): return "网络错误：\(detail)"
        }
    }
}
