import Foundation

enum Storage {
    static let fileManager = FileManager.default

    static var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var downloadsURL: URL {
        documentsURL.appendingPathComponent("Downloads", isDirectory: true)
    }

    static var supportURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VideoSniffer", isDirectory: true)
    }

    static var tmpURL: URL {
        documentsURL.appendingPathComponent(".tmp", isDirectory: true)
    }

    static func ensureDirectories() {
        for dir in [downloadsURL, supportURL, tmpURL] {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // 临时目录不参与 iCloud 备份
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? tmpURL.setResourceValues(values)
    }

    static func load<T: Decodable>(_ type: T.Type, from fileName: String) -> T? {
        let url = supportURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to fileName: String) {
        ensureDirectories()
        let url = supportURL.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func delete(_ fileName: String) {
        let url = supportURL.appendingPathComponent(fileName)
        try? fileManager.removeItem(at: url)
    }

    static func directorySize(_ dir: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            total += Int64(size ?? 0)
        }
        return total
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 清洗文件名中的非法字符
    static func sanitizeFileName(_ raw: String) -> String {
        let decoded = raw.removingPercentEncoding ?? raw
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let mapped = decoded.unicodeScalars.map { illegal.contains($0) ? "_" : $0 }
        var name = String(String.UnicodeScalarView(mapped))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = "video_\(Int(Date().timeIntervalSince1970))"
        }
        if name.count > 100 {
            name = String(name.prefix(100))
        }
        return name
    }

    /// 生成不冲突的目标文件名
    static func uniqueDestination(fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = downloadsURL.appendingPathComponent(fileName)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)_\(index)" : "\(base)_\(index).\(ext)"
            candidate = downloadsURL.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }
}
