import Foundation

enum StorageError: Error, LocalizedError {
    case nameExhausted

    var errorDescription: String? {
        switch self {
        case .nameExhausted: return "无法生成可用的文件名（同名文件过多）"
        }
    }
}

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
        var tmp = tmpURL
        try? tmp.setResourceValues(values)
    }

    /// 清理下载目录中遗留的隐藏临时项（HLS 工作目录 .UUID 等）
    static func cleanupDownloadsArtifacts() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: downloadsURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for url in entries where url.lastPathComponent.hasPrefix(".") {
            try? fileManager.removeItem(at: url)
        }
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
        // 不再 prettyPrinted：任务列表每次状态变更都全量重写，格式化只会白烧 CPU 和磁盘
        encoder.outputFormatting = [.sortedKeys]
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
        // ".." 不含非法字符，但会被 appendingPathComponent 解析成上级目录
        while name.contains("..") {
            name = name.replacingOccurrences(of: "..", with: "_")
        }
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        if name.isEmpty {
            name = "video_\(Int(Date().timeIntervalSince1970))"
        }
        if name.count > 100 {
            // 截断时保住扩展名：否则 AVFoundation 会因后缀缺失拒绝播放
            let ext = (name as NSString).pathExtension
            if ext.isEmpty {
                name = String(name.prefix(100))
            } else {
                let base = (name as NSString).deletingPathExtension
                let keep = max(1, 100 - ext.count - 1)
                name = String(base.prefix(keep)) + "." + ext
            }
        }
        return name
    }

    private static let nameLock = NSLock()

    /// 选一个不冲突的文件名并把文件移入下载目录（同一把锁内完成"检查 + 移动"）。
    /// 直链下载回调与 HLS 流水线可能同时落盘，先 fileExists 再 moveItem 会撞名：
    /// 第二个 moveItem 抛错后任务被标记失败，文件直接丢。
    static func commitDownload(from source: URL, preferredName: String) throws -> URL {
        ensureDirectories()
        let dir = downloadsURL
        let dirPath = dir.standardizedFileURL.path + "/"
        let sanitized = sanitizeFileName(preferredName)
        let base = (sanitized as NSString).deletingPathExtension
        let ext = (sanitized as NSString).pathExtension

        nameLock.lock()
        defer { nameLock.unlock() }

        for index in 0...999 {
            let name: String
            if index == 0 {
                name = sanitized
            } else if ext.isEmpty {
                name = "\(base)_\(index)"
            } else {
                name = "\(base)_\(index).\(ext)"
            }

            let candidate = dir.appendingPathComponent(name, isDirectory: false)
                .standardizedFileURL
            // 兜底：任何清洗漏网都不能写到下载目录之外
            guard candidate.path.hasPrefix(dirPath) else { continue }
            guard !fileManager.fileExists(atPath: candidate.path) else { continue }

            do {
                try fileManager.moveItem(at: source, to: candidate)
                return candidate
            } catch {
                // 外部进程抢注同名时换下一个名字重试，其它 IO 错误原样抛出
                if fileManager.fileExists(atPath: candidate.path) { continue }
                throw error
            }
        }
        throw StorageError.nameExhausted
    }
}
