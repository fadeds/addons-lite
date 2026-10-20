import Foundation
import UIKit

enum UpgradeError: Error, LocalizedError {
    case manifestUnavailable(String)
    case bundleMismatch(expected: String, found: String)
    case cannotOpen

    var errorDescription: String? {
        switch self {
        case .manifestUnavailable(let detail):
            return "安装描述文件不可用：\(detail)"
        case .bundleMismatch(let expected, let found):
            return "安装包不匹配（本机 \(expected)，更新包 \(found)）"
        case .cannotOpen:
            return "系统未打开安装界面"
        }
    }
}

/// 通过 itms-services 触发 OTA 覆盖安装
enum ManifestInstaller {
    static func startUpgrade(manifestURL: URL) async throws {
        // 1. 下载并校验 manifest
        let (data, response) = try await URLSession.shared.data(from: manifestURL)
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
        guard let encoded = ipaURL.absoluteString.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) else { return nil }
        return URL(string: "altstore://install?url=\(encoded)")
    }

    /// TrollStore 安装链接（TrollStore 1.3+，需在 TrollStore 设置中开启 URL Scheme）
    static func trollStoreInstallURL(ipaURL: URL) -> URL? {
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
}
