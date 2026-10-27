import Foundation

enum M3U8Stage {
    case playlist
    case download
    case merge
    case remux
    case done
}

enum M3U8DownloadError: Error, LocalizedError {
    case invalidURL
    case fetchFailed(String, Int)
    case parseFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "视频链接无效"
        case .fetchFailed(let detail, _): return "网络请求失败：\(detail)"
        case .parseFailed(let detail): return "解析失败：\(detail)"
        case .unsupported(let detail): return "暂不支持：\(detail)"
        }
    }
}

enum M3U8Downloader {
    typealias ProgressHandler = @Sendable (M3U8Stage, Double, String) -> Void

    static func download(
        _ video: VideoInfo,
        into destinationDir: URL,
        progress: ProgressHandler?
    ) async throws -> URL {
        guard let playlistURL = video.parsedURL else {
            throw M3U8DownloadError.invalidURL
        }

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        // 1. 拉取播放列表（403 时自动探测 Referer）
        progress?(.playlist, 0.02, "拉取播放列表")
        var (text, activeReferer) = try await fetchPlaylistText(
            playlistURL,
            session: session,
            preferred: video.referer
        )
        var playlist = try M3U8Parser.parse(text, baseURL: playlistURL)

        if playlist.isMaster {
            guard let variant = M3U8Parser.bestVariant(playlist) else {
                throw M3U8DownloadError.parseFailed("没有可用清晰度")
            }
            let label = variant.resolution.map { "清晰度 \($0)" }
                ?? "带宽 \(variant.bandwidth)"
            progress?(.playlist, 0.04, "选中\(label)")
            (text, activeReferer) = try await fetchPlaylistText(
                variant.url,
                session: session,
                preferred: activeReferer
            )
            playlist = try M3U8Parser.parse(text, baseURL: variant.url)
        }

        guard !playlist.segments.isEmpty else {
            throw M3U8DownloadError.parseFailed("播放列表没有分片")
        }

        let segments = playlist.segments
        let total = segments.count
        // 固定下来供并发闭包捕获（捕获 var 在并发执行下是警告项）
        let referer = activeReferer

        // 2. 预取加密密钥：按分片记录（支持密钥轮换 / 中途转明文）
        var keyURLs: Set<URL> = []
        var hasSampleAES = false
        var hasUnknownMethod = false
        for segment in segments {
            switch segment.keyMethod {
            case .none, .aes128:
                break
            case .sampleAES:
                hasSampleAES = true
            case .unknown:
                hasUnknownMethod = true
            }
            if let keyURL = segment.keyURI {
                keyURLs.insert(keyURL)
            }
        }
        if hasSampleAES { throw M3U8DownloadError.unsupported("SAMPLE-AES 加密流") }
        if hasUnknownMethod { throw M3U8DownloadError.unsupported("未知加密方式") }

        var keyCache: [URL: Data] = [:]
        for keyURL in keyURLs {
            let keyData = try await fetchData(
                keyURL,
                session: session,
                referer: activeReferer
            )
            guard keyData.count == 16 else {
                throw M3U8DownloadError.unsupported("AES-128 密钥长度异常")
            }
            keyCache[keyURL] = keyData
        }
        let keys = keyCache

        // 3. 下载 fMP4 初始化分片
        var initData: Data?
        if let mapURL = playlist.initMapURL {
            progress?(.download, 0.05, "下载初始化分片")
            initData = try await fetchData(
                mapURL,
                session: session,
                referer: activeReferer,
                byteRange: playlist.initMapRange
            )
        }

        // 4. 并发下载媒体分片
        let fileManager = FileManager.default
        let workDir = destinationDir.appendingPathComponent(
            ".\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDir) }

        let counter = ProgressCounter()
        let cursor = SegmentCursor()
        let baseProgress = 0.05
        let progressWeight = 0.85
        let concurrency = min(4, total)

        // 固定 worker 池：只为 4 个 worker 建任务，用游标抢 index。
        // 原来按分片数建任务（1 小时视频约 900 个）再挂信号量，任务调度开销与内存都高一个量级。
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    while true {
                        let index = cursor.next()
                        guard index < total else { return }
                        try Task.checkCancellation()

                        let segment = segments[index]
                        let data = try await fetchSegment(
                            segment,
                            session: session,
                            referer: referer
                        )

                        var payload = data
                        if segment.keyMethod == .aes128 {
                            guard let keyURL = segment.keyURI, let key = keys[keyURL] else {
                                throw M3U8DownloadError.unsupported("分片缺少 AES-128 密钥")
                            }
                            let iv = try AESCryptor.iv(
                                mediaSequence: segment.mediaSequence,
                                explicitHex: segment.ivHex
                            )
                            payload = try AESCryptor.decrypt(data, key: key, iv: iv)
                        }

                        let segmentURL = workDir.appendingPathComponent(
                            String(format: "seg_%06d.bin", index)
                        )
                        try payload.write(to: segmentURL)

                        let finished = counter.increment()
                        let percent = baseProgress
                            + progressWeight * Double(finished) / Double(total)
                        progress?(
                            .download,
                            percent,
                            "下载分片 \(finished)/\(total)"
                        )
                    }
                }
            }
            try await group.waitForAll()
        }

        // 5. 按序合并
        progress?(.merge, 0.92, "合并分片")
        let isFragmentedMP4 = initData != nil
        let mergedURL = workDir.appendingPathComponent(
            isFragmentedMP4 ? "merged.mp4" : "merged.ts"
        )
        fileManager.createFile(atPath: mergedURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: mergedURL)
        do {
            if let initSegment = initData {
                try handle.write(contentsOf: initSegment)
            }
            for index in 0..<total {
                let segmentURL = workDir.appendingPathComponent(
                    String(format: "seg_%06d.bin", index)
                )
                guard let segmentData = try? Data(
                    contentsOf: segmentURL,
                    options: .mappedIfSafe
                ) else {
                    throw M3U8DownloadError.parseFailed("分片 \(index) 缺失")
                }
                try handle.write(contentsOf: segmentData)
                if index % 40 == 0 {
                    let percent = 0.92 + 0.03 * Double(index) / Double(max(total, 1))
                    progress?(.merge, percent, "合并 \(index + 1)/\(total)")
                }
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        // 6. 转封装为 MP4
        progress?(.remux, 0.96, "转封装 MP4")
        let preferredName = storageFileName(for: video, ext: "mp4")
        let finalURL: URL

        do {
            let remuxedURL = workDir.appendingPathComponent("output.mp4")
            try await TSRemuxer.remux(input: mergedURL, output: remuxedURL)
            // 选名与移动在同一把锁内完成，避免与直链下载撞名
            finalURL = try Storage.commitDownload(
                from: remuxedURL,
                preferredName: preferredName
            )
        } catch {
            if error is CancellationError { throw error }
            // 转封装失败时保留合并后的原始文件（TS / 分片MP4），仍可播放
            finalURL = try Storage.commitDownload(
                from: mergedURL,
                preferredName: preferredName
            )
        }

        progress?(.done, 1.0, "完成")
        return finalURL
    }

    // MARK: - HTTP

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }

    private static func makeRequest(
        _ url: URL,
        referer: String?,
        byteRange: M3U8ByteRange?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let referer, !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
            if let refURL = URL(string: referer),
               let scheme = refURL.scheme,
               let host = refURL.host {
                request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
        }
        if let range = byteRange {
            let end = range.offset + range.length - 1
            request.setValue("bytes=\(range.offset)-\(end)", forHTTPHeaderField: "Range")
        }
        return request
    }

    /// 常见 CDN 需要的 Referer（域名 → 候选页面）
    private static let knownReferers: [String: [String]] = [
        "surrit.com": [
            "https://missav.ws/",
            "https://missav.live/",
            "https://missav.com/"
        ]
    ]

    private static func candidateReferers(for url: URL, excluding: String?) -> [String] {
        guard let scheme = url.scheme, let host = url.host else { return [] }
        var candidates: [String] = ["\(scheme)://\(host)/"]
        if !host.hasPrefix("www.") {
            candidates.append("\(scheme)://www.\(host)/")
        }

        var parts = host.components(separatedBy: ".")
        while parts.count > 2 {
            parts.removeFirst()
            candidates.append("\(scheme)://\(parts.joined(separator: "."))/")
        }

        for domain in [host, parts.joined(separator: ".")] {
            if let known = knownReferers[domain] {
                candidates.append(contentsOf: known)
            }
        }

        var seen: Set<String> = []
        return candidates.filter { candidate in
            guard candidate != excluding else { return false }
            return seen.insert(candidate).inserted
        }
    }

    private static func decodeText(_ data: Data) throws -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let latin = String(data: data, encoding: .isoLatin1) { return latin }
        throw M3U8DownloadError.parseFailed("播放列表编码无法识别")
    }

    /// 拉取播放列表；遇到 401/403/439 时自动切换候选 Referer 重试
    private static func fetchPlaylistText(
        _ url: URL,
        session: URLSession,
        preferred: String?
    ) async throws -> (String, String?) {
        do {
            let data = try await fetchData(url, session: session, referer: preferred)
            return (try decodeText(data), preferred)
        } catch let error as M3U8DownloadError {
            guard case .fetchFailed(_, let status) = error,
                  status == 401 || status == 403 || status == 439
            else { throw error }
        }

        var lastError: Error?
        for candidate in candidateReferers(for: url, excluding: preferred) {
            try Task.checkCancellation()
            do {
                let data = try await fetchData(url, session: session, referer: candidate)
                return (try decodeText(data), candidate)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? M3U8DownloadError.fetchFailed("HTTP 403（Referer 探测失败）", 403)
    }

    private static func fetchSegment(
        _ segment: M3U8Segment,
        session: URLSession,
        referer: String?
    ) async throws -> Data {
        try await fetchData(
            segment.url,
            session: session,
            referer: referer,
            byteRange: segment.byteRange
        )
    }

    private static func fetchData(
        _ url: URL,
        session: URLSession,
        referer: String? = nil,
        byteRange: M3U8ByteRange? = nil
    ) async throws -> Data {
        let request = makeRequest(url, referer: referer, byteRange: byteRange)

        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    let ok = (200..<300).contains(http.statusCode) || http.statusCode == 206
                    if !ok {
                        let snippet = String(data: data.prefix(160), encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let hint = errnoHint(status: http.statusCode)
                        let extra = snippet.isEmpty ? "" : " | \(snippet)"
                        throw M3U8DownloadError.fetchFailed(
                            "HTTP \(http.statusCode) \(hint)\(extra)",
                            http.statusCode
                        )
                    }
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as M3U8DownloadError {
                throw error
            } catch {
                lastError = error
                if attempt < 2 {
                    let nanos = UInt64(500 * (attempt + 1)) * 1_000_000
                    try? await Task.sleep(nanoseconds: nanos)
                }
            }
        }
        let detail = lastError?.localizedDescription ?? "未知错误"
        throw M3U8DownloadError.fetchFailed("\(url.lastPathComponent): \(detail)", 0)
    }

    private static func errnoHint(status: Int) -> String {
        switch status {
        case 401, 403, 439: return "（服务器拒绝访问，可能需要 Referer/Cookie）"
        case 404: return "（资源不存在）"
        case 429: return "（请求过于频繁）"
        case 500...599: return "（服务器错误）"
        default: return ""
        }
    }

    // MARK: - 文件名

    private static func storageFileName(for video: VideoInfo, ext: String) -> String {
        let raw = video.shortFileName
        let base = (raw as NSString).deletingPathExtension
        let cleaned = Storage.sanitizeFileName(base.isEmpty ? "video" : base)
        return "\(cleaned).\(ext)"
    }
}

// MARK: - 并发工具

/// 分片游标：worker 池用原子自增抢下一个待下载下标
private final class SegmentCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = index
        index += 1
        return current
    }
}

private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
