import Foundation
import UIKit

enum UpgradeError: Error, LocalizedError {
    case manifestUnavailable(String)
    case bundleMismatch(expected: String, found: String)
    case untrustedSource
    case notNewer(version: String)
    case cannotOpen

    var errorDescription: String? {
        switch self {
        case .manifestUnavailable(let detail):
            return "安装描述文件不可用：\(detail)"
        case .bundleMismatch(let expected, let found):
            return "安装包不匹配（本机 \(expected)，更新包 \(found)）"
        case .untrustedSource:
            return "更新源不在受信域名内，已阻止安装"
        case .notNewer(let version):
            return "更新包版本 \(version) 不高于当前版本，已阻止安装"
        case .cannotOpen:
            return "系统未打开安装界面"
        }
    }
}

/// 通过 itms-services 触发 OTA 覆盖安装
enum ManifestInstaller {
    /// 更新链路只接受这些域名的 HTTPS 资源。
    /// App 全局开了 NSAllowsArbitraryLoads（http 视频源必需），
    /// 若不在这里卡住，"更新"就成了绕过 ATS 的明文通道。
    static let trustedHosts: Set<String> = [
        "api.github.com",
        "github.com",
        "objects.githubusercontent.com",
        "raw.githubusercontent.com",
        "codeload.github.com"
    ]

    static func isTrustedUpdateURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        return trustedHosts.contains(host)
    }

    static func startUpgrade(manifestURL: URL) async throws {
        guard isTrustedUpdateURL(manifestURL) else { throw UpgradeError.untrustedSource }

        // 1. 下载并校验 manifest
        var request = URLRequest(url: manifestURL)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw UpgradeError.manifestUnavailable("HTTP \(http.statusCode)")
        }

        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw UpgradeError.manifestUnavailable("manifest 解析失败")
        }

        guard let foundID = Self.bundleIdentifier(in: plist) else {
            throw UpgradeError.manifestUnavailable("manifest 缺少 bundle-identifier")
        }

        let localID = Bundle.main.bundleIdentifier ?? ""
        guard foundID == localID else {
            throw UpgradeError.bundleMismatch(expected: localID, found: foundID)
        }

        // bundle-identifier 相同只说明"是同一个 App"，不代表是更新而不是降级/重放
        let currentVersion = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let remoteVersion = Self.bundleVersion(in: plist) ?? ""
        guard !remoteVersion.isEmpty,
              Self.isNewer(remoteVersion, than: currentVersion)
        else {
            throw UpgradeError.notNewer(version: remoteVersion.isEmpty ? "未知" : remoteVersion)
        }

        // 2. 构造 itms-services URL（manifest 地址需整体百分号编码）
        guard let encoded = manifestURL.absoluteString.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
            )
        ) else {
            throw UpgradeError.cannotOpen
        }

        guard let itmsURL = URL(string: "itms-services://?action=download-manifest&url=\(encoded)")
        else {
            throw UpgradeError.cannotOpen
        }

        // 3. 拉起系统安装
        let opened = await UIApplication.shared.open(itmsURL, options: [:])
        guard opened else { throw UpgradeError.cannotOpen }
    }

    /// AltStore 兜底安装链接
    static func altStoreInstallURL(ipaURL: URL) -> URL? {
        guard isTrustedUpdateURL(ipaURL) else { return nil }
        guard let encoded = ipaURL.absoluteString.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) else { return nil }
        return URL(string: "altstore://install?url=\(encoded)")
    }

    /// TrollStore 安装链接（TrollStore 1.3+，需在 TrollStore 设置中开启 URL Scheme）
    static func trollStoreInstallURL(ipaURL: URL) -> URL? {
        guard isTrustedUpdateURL(ipaURL) else { return nil }
        guard let encoded = ipaURL.absoluteString.addingPercentEncoding(
            withAllowedCharacters: unreserved
        ) else { return nil }
        return URL(string: "apple-magnifier://install?url=\(encoded)")
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func bundleIdentifier(in plist: [String: Any]) -> String? {
        guard let items = plist["items"] as? [[String: Any]] else { return nil }
        for item in items {
            if let metadata = item["metadata"] as? [String: Any],
               let bundleID = metadata["bundle-identifier"] as? String {
                return bundleID
            }
        }
        return nil
    }

    private static func bundleVersion(in plist: [String: Any]) -> String? {
        guard let items = plist["items"] as? [[String: Any]] else { return nil }
        for item in items {
            if let metadata = item["metadata"] as? [String: Any],
               let version = metadata["bundle-version"] as? String {
                return version
            }
        }
        return nil
    }

    /// 语义化版本比较（与 UpdateChecker 保持同一规则）
    private static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = components(remote)
        let l = components(local)
        for index in 0..<max(r.count, l.count) {
            let rv = index < r.count ? r[index] : 0
            let lv = index < l.count ? l[index] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") {
            text = String(text.dropFirst())
        }
        if let dash = text.firstIndex(of: "-") {
            text = String(text[text.startIndex..<dash])
        }
        return text.split(separator: ".").map { part in
            Int(part.prefix(while: { $0.isNumber })) ?? 0
        }
    }
}
