import Foundation
import CommonCrypto

enum AESCryptorError: Error, LocalizedError {
    case invalidKeyLength
    case invalidIVLength
    case invalidIVHex
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .invalidKeyLength: return "AES 密钥长度无效（需要 16 字节）"
        case .invalidIVLength: return "AES IV 长度无效（需要 16 字节）"
        case .invalidIVHex: return "AES IV 十六进制格式无效"
        case .decryptionFailed: return "AES-128 解密失败（数据可能已损坏）"
        }
    }
}

enum AESCryptor {
    /// HLS AES-128-CBC 解密（PKCS#7 去填充）
    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw AESCryptorError.invalidKeyLength }
        guard iv.count == kCCBlockSizeAES128 else { throw AESCryptorError.invalidIVLength }

        let outCapacity = data.count + kCCBlockSizeAES128
        var outBytes = [UInt8](repeating: 0, count: outCapacity)
        var outCount = 0

        let status: CCCryptorStatus = data.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    outBytes.withUnsafeMutableBufferPointer { outPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            outPtr.baseAddress, outPtr.count,
                            &outCount
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { throw AESCryptorError.decryptionFailed }
        return Data(outBytes.prefix(outCount))
    }

    /// 计算分片 IV：优先使用 EXT-X-KEY 的显式 IV，否则用媒体序列号的大端 16 字节表示
    static func iv(mediaSequence: Int, explicitHex: String?) throws -> Data {
        if let hex = explicitHex {
            var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("0x") {
                trimmed = String(trimmed.dropFirst(2))
            }
            guard trimmed.count == 32, let data = Data(hexString: trimmed) else {
                throw AESCryptorError.invalidIVHex
            }
            return data
        }
        var sequence = UInt64(mediaSequence).bigEndian
        let sequenceBytes = withUnsafeBytes(of: &sequence) { Data($0) }
        return Data(repeating: 0, count: 8) + sequenceBytes
    }
}

extension Data {
    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0, !cleaned.isEmpty else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
