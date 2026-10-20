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
    case fetchFailed(String)
    case parseFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "视频链接无效"
        case .fetchFailed(let detail): return "网络请求失败：\(detail)"
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

        let session = makeSession(referer: video.referer)
        defer { session.finishTasksAndInvalidate() }

        // 1. 拉取播放列表
        progress?(.playlist, 0.02, "拉取播放列表")
        let text = try await fetchText(playlistURL, session: session)
        var playlist = try M3U8Parser.parse(text, baseURL: playlistURL)

        if playlist.isMaster {
            guard let variant = M3U8Parser.bestVariant(playlist) else {
                throw M3U8DownloadError.parseFailed("没有可用清晰度")
            }
            let label = variant.resolution.map { "清晰度 \($0)" }
                ?? "带宽 \(variant.bandwidth)"
            progress?(.playlist, 0.04, "选中\(label)")
            let variantText = try await fetchText(variant.url, session: session)
            playlist = try M3U8Parser.parse(variantText, baseURL: variant.url)
        }

        guard !playlist.segments.isEmpty else {
            throw M3U8DownloadError.parseFailed("播放列表没有分片")
        }

        // 2. 解析加密
        var aesKey: Data?
        if let encryption = playlist.encryption {
            switch encryption.method {
            case .none:
                break
            case .aes128:
                guard let keyURL = encryption.keyURL else {
                    throw M3U8DownloadError.unsupported("AES-128 密钥地址缺失")
                }
                let keyData = try await fetchData(keyURL, session: session)
                guard keyData.count == 16 else {
                    throw M3U8DownloadError.unsupported("AES-128 密钥长度异常")
                }
                aesKey = keyData
            case .sampleAES:
                throw M3U8DownloadError.unsupported("SAMPLE-AES 加密流")
            case .unknown:
                throw M3U8DownloadError.unsupported("未知加密方式")
            }
        }

        // 3. 下载 fMP4 初始化分片
        var initData: Data?
        if let mapURL = playlist.initMapURL {
            progress?(.download, 0.05, "下载初始化分片")
            initData = try await fetchData(
                mapURL,
                session: session,
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

        let segments = playlist.segments
        let total = segments.count
        let counter = ProgressCounter()
        let semaphore = AsyncSemaphore(permits: 4)
        let baseProgress = 0.05
        let progressWeight = 0.85
        let key = aesKey
        let ivHex = playlist.encryption?.ivHex

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, segment) in segments.enumerated() {
                group.addTask {
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }

                    let data = try await fetchSegment(
                        segment,
                        session: session,
                        referer: video.referer
                    )

                    var payload = data
                    if let key = key {
                        let iv = try AESCryptor.iv(
                            mediaSequence: segment.mediaSequence,
                            explicitHex: ivHex
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
            if let init = initData {
                try handle.write(contentsOf: init)
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
        let finalName = Storage.uniqueDestination(
            fileName: storageFileName(for: video, ext: "mp4")
        )

        do {
            let remuxedURL = workDir.appendingPathComponent("output.mp4")
            try await TSRemuxer.remux(input: mergedURL, output: remuxedURL)
            try fileManager.moveItem(at: remuxedURL, to: finalName)
        } catch {
            if error is CancellationError { throw error }
            // 转封装失败时保留合并后的原始文件（TS / 分片MP4），仍可播放
            try fileManager.moveItem(at: mergedURL, to: finalName)
        }

        progress?(.done, 1.0, "完成")
        return finalName
    }

    // MARK: - HTTP

    private static func makeSession(referer: String?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        if let referer = referer {
            config.httpAdditionalHeaders = ["Referer": referer]
        }
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }

    private static func fetchText(_ url: URL, session: URLSession) async throws -> String {
        let data = try await fetchData(url, session: session)
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let latin = String(data: data, encoding: .isoLatin1) { return latin }
        throw M3U8DownloadError.parseFailed("播放列表编码无法识别")
    }

    private static func fetchSegment(
        _ segment: M3U8Segment,
        session: URLSession,
        referer: String?
    ) async throws -> Data {
        try await fetchData(segment.url, session: session, byteRange: segment.byteRange)
    }

    private static func fetchData(
        _ url: URL,
        session: URLSession,
        byteRange: M3U8ByteRange? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let range = byteRange {
            let end = range.offset + range.length - 1
            request.setValue("bytes=\(range.offset)-\(end)", forHTTPHeaderField: "Range")
        }

        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    let ok = (200..<300).contains(http.statusCode) || http.statusCode == 206
                    if !ok {
                        throw M3U8DownloadError.fetchFailed("HTTP \(http.statusCode) \(url.lastPathComponent)")
                    }
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < 2 {
                    let nanos = UInt64(500 * (attempt + 1)) * 1_000_000
                    try? await Task.sleep(nanoseconds: nanos)
                }
            }
        }
        let detail = lastError?.localizedDescription ?? "未知错误"
        throw M3U8DownloadError.fetchFailed("\(url.lastPathComponent): \(detail)")
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

private actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        self.permits = permits
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
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
