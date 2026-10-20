import AVFoundation
import Foundation

enum TSRemuxerError: Error, LocalizedError {
    case cannotOpenInput(String)
    case noTracks
    case readerFailed(String)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenInput(let detail): return "无法读取输入文件：\(detail)"
        case .noTracks: return "输入文件不包含音视频轨道"
        case .readerFailed(let detail): return "读取媒体数据失败：\(detail)"
        case .writerFailed(let detail): return "写入 MP4 失败：\(detail)"
        }
    }
}

/// 将 MPEG-TS / 分片 MP4 转封装为标准 MP4。
/// 先尝试无损直通（不重编码），失败后自动回退为 H.264/AAC 重编码。
enum TSRemuxer {
    static func remux(input: URL, output: URL) async throws {
        try? FileManager.default.removeItem(at: output)

        do {
            try await run(input: input, output: output, reencode: false)
        } catch {
            try? FileManager.default.removeItem(at: output)
            if error is CancellationError { throw error }
            try await run(input: input, output: output, reencode: true)
        }
    }

    private static func run(input: URL, output: URL, reencode: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try blockingRemux(input: input, output: output, reencode: reencode)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 核心实现

    private static func blockingRemux(input: URL, output: URL, reencode: Bool) throws {
        let asset = AVURLAsset(url: input)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw TSRemuxerError.cannotOpenInput(error.localizedDescription)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        } catch {
            throw TSRemuxerError.writerFailed(error.localizedDescription)
        }

        struct Pair {
            let output: AVAssetReaderOutput
            let input: AVAssetWriterInput
        }

        var pairs: [Pair] = []

        for mediaType in [AVMediaType.video, .audio] {
            for track in asset.tracks(withMediaType: mediaType) {
                let readerOutput: AVAssetReaderTrackOutput
                let writerInput: AVAssetWriterInput

                if reencode {
                    if mediaType == .video {
                        let decodeSettings: [String: Any] = [
                            kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                        ]
                        readerOutput = AVAssetReaderTrackOutput(
                            track: track,
                            outputSettings: decodeSettings
                        )

                        let transformed = track.naturalSize.applying(track.preferredTransform)
                        let width = evenDimension(abs(transformed.width))
                        let height = evenDimension(abs(transformed.height))
                        let compression: [String: Any] = [
                            AVVideoAverageBitRateKey: max(width * height * 4, 2_500_000),
                            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                        ]
                        let videoSettings: [String: Any] = [
                            AVVideoCodecKey: AVVideoCodecType.h264,
                            AVVideoWidthKey: width,
                            AVVideoHeightKey: height,
                            AVVideoCompressionPropertiesKey: compression
                        ]
                        writerInput = AVAssetWriterInput(
                            mediaType: .video,
                            outputSettings: videoSettings
                        )
                    } else {
                        let decodeSettings: [String: Any] = [
                            AVFormatIDKey: kAudioFormatLinearPCM,
                            AVLinearPCMBitDepthKey: 16,
                            AVLinearPCMIsBigEndianKey: false,
                            AVLinearPCMIsFloatKey: false,
                            AVLinearPCMIsNonInterleaved: false
                        ]
                        readerOutput = AVAssetReaderTrackOutput(
                            track: track,
                            outputSettings: decodeSettings
                        )
                        writerInput = AVAssetWriterInput(
                            mediaType: .audio,
                            outputSettings: aacSettings(for: track)
                        )
                    }
                } else {
                    readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                    writerInput = AVAssetWriterInput(mediaType: mediaType, outputSettings: nil)
                }

                writerInput.expectsMediaDataInRealTime = false
                writerInput.transform = track.preferredTransform

                guard reader.canAdd(readerOutput) else { continue }
                reader.add(readerOutput)
                guard writer.canAdd(writerInput) else { continue }
                writer.add(writerInput)
                pairs.append(Pair(output: readerOutput, input: writerInput))
            }
        }

        guard !pairs.isEmpty else { throw TSRemuxerError.noTracks }

        guard writer.startWriting() else {
            throw TSRemuxerError.writerFailed(writer.error?.localizedDescription ?? "startWriting 失败")
        }
        reader.startReading()

        let queue = DispatchQueue(label: "com.videosniffer.remux")
        let group = DispatchGroup()

        for pair in pairs {
            let finished = OnceFlag()
            group.enter()
            pair.input.requestMediaDataWhenReady(on: queue) {
                while pair.input.isReadyForMoreMediaData {
                    guard reader.status == .reading else {
                        pair.input.markAsFinished()
                        finished.fire { group.leave() }
                        return
                    }
                    guard let sample = pair.output.copyNextSampleBuffer() else {
                        pair.input.markAsFinished()
                        finished.fire { group.leave() }
                        return
                    }
                    guard pair.input.append(sample) else {
                        pair.input.markAsFinished()
                        finished.fire { group.leave() }
                        return
                    }
                }
            }
        }

        group.wait()

        if reader.status == .failed {
            writer.cancelWriting()
            throw TSRemuxerError.readerFailed(
                reader.error?.localizedDescription ?? "未知读取错误"
            )
        }

        let finishGroup = DispatchGroup()
        finishGroup.enter()
        writer.finishWriting {
            finishGroup.leave()
        }
        finishGroup.wait()

        switch writer.status {
        case .completed:
            return
        case .cancelled:
            throw TSRemuxerError.writerFailed("写入已取消")
        default:
            throw TSRemuxerError.writerFailed(
                writer.error?.localizedDescription ?? "未知写入错误"
            )
        }
    }

    // MARK: - 辅助

    private static func evenDimension(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        let even = max(2, rounded) / 2 * 2
        return min(even, 8192)
    }

    private static func aacSettings(for track: AVAssetTrack) -> [String: Any] {
        var sampleRate: Float64 = 44100
        var channels: UInt32 = 2

        if let desc = track.formatDescriptions.first {
            let formatDesc = desc as! CMAudioFormatDescription
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee {
                if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
                if asbd.mChannelsPerFrame > 0 { channels = asbd.mChannelsPerFrame }
            }
        }

        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(min(max(channels, 1), 2)),
            AVEncoderBitRateKey: 128_000
        ]
    }
}

/// 同一队列上保证只执行一次的辅助（用于 DispatchGroup.leave 配对）
private final class OnceFlag {
    private var fired = false

    func fire(_ block: () -> Void) {
        guard !fired else { return }
        fired = true
        block()
    }
}
