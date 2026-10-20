import Foundation

enum M3U8ParseError: Error, LocalizedError {
    case notPlaylist
    case missingSegments

    var errorDescription: String? {
        switch self {
        case .notPlaylist: return "不是有效的 M3U8 播放列表"
        case .missingSegments: return "播放列表中没有分片"
        }
    }
}

struct M3U8Encryption {
    enum Method: String {
        case none
        case aes128 = "AES-128"
        case sampleAES = "SAMPLE-AES"
        case unknown
    }

    var method: Method
    var keyURL: URL?
    var ivHex: String?
}

struct M3U8ByteRange {
    var offset: Int
    var length: Int
}

struct M3U8Segment {
    var url: URL
    var duration: Double
    var mediaSequence: Int
    var byteRange: M3U8ByteRange?
}

struct M3U8Variant {
    var url: URL
    var bandwidth: Int
    var resolution: String?
    var codecs: String?
}

struct M3U8Playlist {
    var isMaster: Bool
    var variants: [M3U8Variant]
    var segments: [M3U8Segment]
    var encryption: M3U8Encryption?
    var initMapURL: URL?
    var initMapRange: M3U8ByteRange?
    var targetDuration: Double
    var hasEndList: Bool

    var totalDuration: Double {
        segments.reduce(0) { $0 + $1.duration }
    }
}

enum M3U8Parser {
    static func parse(_ text: String, baseURL: URL) throws -> M3U8Playlist {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.first?.hasPrefix("#EXTM3U") == true else {
            throw M3U8ParseError.notPlaylist
        }

        var isMaster = false
        var variants: [M3U8Variant] = []
        var segments: [M3U8Segment] = []
        var encryption: M3U8Encryption?
        var initMapURL: URL?
        var initMapRange: M3U8ByteRange?
        var targetDuration: Double = 0
        var hasEndList = false

        var pendingVariant: (bandwidth: Int, resolution: String?, codecs: String?)?
        var pendingDuration: Double = 0
        var pendingRange: M3U8ByteRange?
        var lastRangeEnd = 0
        var sequenceBase = 0

        for line in lines {
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    isMaster = true
                    let attrs = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                    pendingVariant = (
                        bandwidth: intAttribute("BANDWIDTH", in: attrs) ?? intAttribute("AVERAGE-BANDWIDTH", in: attrs) ?? 0,
                        resolution: stringAttribute("RESOLUTION", in: attrs),
                        codecs: stringAttribute("CODECS", in: attrs)
                    )
                } else if line.hasPrefix("#EXTINF:") {
                    let value = String(line.dropFirst("#EXTINF:".count))
                    let durationPart = value.components(separatedBy: ",").first ?? value
                    pendingDuration = Double(durationPart.trimmingCharacters(in: .whitespaces)) ?? 0
                } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                    let value = String(line.dropFirst("#EXT-X-TARGETDURATION:".count))
                    targetDuration = Double(value) ?? targetDuration
                } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                    let value = String(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count))
                    sequenceBase = Int(value) ?? 0
                } else if line.hasPrefix("#EXT-X-KEY:") {
                    let attrs = String(line.dropFirst("#EXT-X-KEY:".count))
                    let methodRaw = stringAttribute("METHOD", in: attrs) ?? "NONE"
                    let method: M3U8Encryption.Method
                    switch methodRaw {
                    case "NONE": method = .none
                    case "AES-128": method = .aes128
                    case "SAMPLE-AES": method = .sampleAES
                    default: method = .unknown
                    }
                    let uri = stringAttribute("URI", in: attrs)
                    let iv = stringAttribute("IV", in: attrs)
                    encryption = M3U8Encryption(
                        method: method,
                        keyURL: uri.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL },
                        ivHex: iv
                    )
                } else if line.hasPrefix("#EXT-X-MAP:") {
                    let attrs = String(line.dropFirst("#EXT-X-MAP:".count))
                    if let uri = stringAttribute("URI", in: attrs),
                       let url = URL(string: uri, relativeTo: baseURL) {
                        initMapURL = url.absoluteURL
                        if let rangeRaw = stringAttribute("BYTERANGE", in: attrs) {
                            initMapRange = parseByteRange(rangeRaw, previousEnd: 0)
                        }
                    }
                } else if line == "#EXT-X-ENDLIST" {
                    hasEndList = true
                } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                    let value = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                    pendingRange = parseByteRange(value, previousEnd: lastRangeEnd)
                }
                continue
            }

            // 数据行
            guard let lineURL = URL(string: line, relativeTo: baseURL)?.absoluteURL else {
                continue
            }

            if let variant = pendingVariant {
                variants.append(
                    M3U8Variant(
                        url: lineURL,
                        bandwidth: variant.bandwidth,
                        resolution: variant.resolution,
                        codecs: variant.codecs
                    )
                )
                pendingVariant = nil
                continue
            }

            if let range = pendingRange {
                lastRangeEnd = range.offset + range.length
            }
            segments.append(
                M3U8Segment(
                    url: lineURL,
                    duration: pendingDuration,
                    mediaSequence: sequenceBase + segments.count,
                    byteRange: pendingRange
                )
            )
            pendingDuration = 0
            pendingRange = nil
        }

        if isMaster {
            guard !variants.isEmpty else { throw M3U8ParseError.missingSegments }
            return M3U8Playlist(
                isMaster: true,
                variants: variants,
                segments: [],
                encryption: nil,
                initMapURL: nil,
                initMapRange: nil,
                targetDuration: targetDuration,
                hasEndList: hasEndList
            )
        }

        guard !segments.isEmpty else { throw M3U8ParseError.missingSegments }
        return M3U8Playlist(
            isMaster: false,
            variants: [],
            segments: segments,
            encryption: encryption,
            initMapURL: initMapURL,
            initMapRange: initMapRange,
            targetDuration: targetDuration,
            hasEndList: hasEndList
        )
    }

    static func bestVariant(_ playlist: M3U8Playlist) -> M3U8Variant? {
        playlist.variants.max { $0.bandwidth < $1.bandwidth }
    }

    // MARK: - 属性解析

    static func stringAttribute(_ name: String, in attrs: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?:^|,)\(escaped)=(?:\"([^\"]*)\"|([^,]*))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(attrs.startIndex..., in: attrs)
        guard let match = regex.firstMatch(in: attrs, range: range) else { return nil }

        if match.range(at: 1).location != NSNotFound,
           let swiftRange = Range(match.range(at: 1), in: attrs) {
            let value = String(attrs[swiftRange])
            return value.isEmpty ? nil : value
        }
        if match.range(at: 2).location != NSNotFound,
           let swiftRange = Range(match.range(at: 2), in: attrs) {
            let value = String(attrs[swiftRange])
                .trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func intAttribute(_ name: String, in attrs: String) -> Int? {
        guard let raw = stringAttribute(name, in: attrs) else { return nil }
        return Int(raw)
    }

    static func parseByteRange(_ raw: String, previousEnd: Int) -> M3U8ByteRange? {
        let parts = raw.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: "@")
        guard let length = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              length > 0
        else { return nil }
        let offset: Int
        if parts.count > 1, let explicit = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
            offset = explicit
        } else {
            offset = previousEnd
        }
        return M3U8ByteRange(offset: offset, length: length)
    }
}
