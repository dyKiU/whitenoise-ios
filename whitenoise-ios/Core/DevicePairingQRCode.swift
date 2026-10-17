#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Compression
    import Foundation
    import CryptoKit

    /// A purpose-tagged transport envelope, never a source of pairing authority.
    nonisolated enum DevicePairingQRCode {
        static let prefix = "whitenoise-pairing:v1:"
        static let maximumUTF8Bytes = 2200
        static let compressedPrefix = "whitenoise-pairing:v2:deflate:"
        static let maximumPacketBytes = 49_152
        enum MultipartFailure: Error { case invalidPacket, tooLarge, expired, conflictingTransfer }
        private typealias Failure = DeviceVerificationPacketInput.Error

        static func payload(packet: String) throws -> String {
            let bytes = try DeviceVerificationPacketInput.decode(packet)
            guard bytes.base64EncodedString() == packet else { throw Failure.invalidPacket }
            if packet.utf8.count <= maximumUTF8Bytes - prefix.utf8.count { return prefix + packet }
            let capacity = (maximumUTF8Bytes - compressedPrefix.utf8.count) / 4 * 3
            return compressedPrefix + (try compressed(bytes, capacity: capacity)).base64EncodedString()
        }
        static let fragmentPrefix = "whitenoise-pairing:v3:part:"
        static let fragmentBytes = 1536
        static let maximumFrames = 32

        /// Transport integrity only; the original SDK still authenticates reconstructed bytes.
        static func payloads(packet: String) throws -> [String] {
            let bytes = try DeviceVerificationPacketInput.decode(packet)
            do { return [try payload(packet: packet)] } catch MultipartFailure.tooLarge {
                guard !bytes.isEmpty, bytes.count <= maximumPacketBytes else { throw MultipartFailure.tooLarge }
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let count = (bytes.count + fragmentBytes - 1) / fragmentBytes
                guard count >= 2, count <= maximumFrames else { throw MultipartFailure.tooLarge }
                return try (0..<count).map { ordinal in
                    let lower = ordinal * fragmentBytes
                    let part = bytes.subdata(in: lower..<min(lower + fragmentBytes, bytes.count))
                    let payload =
                        "\(fragmentPrefix)\(digest):\(bytes.count):\(ordinal):\(count):\(part.base64EncodedString())"
                    guard payload.utf8.count <= maximumUTF8Bytes else { throw MultipartFailure.tooLarge }
                    return payload
                }
            }
        }

        static func validateFrame(_ payload: String) throws {
            if payload.hasPrefix(fragmentPrefix) { _ = try Fragment(payload) }
            else { _ = try packet(from: payload) }
        }

        private struct Fragment {
            let digest: String
            let totalBytes: Int
            let ordinal: Int
            let count: Int
            let bytes: Data
            init(_ payload: String) throws {
                guard payload.utf8.count <= maximumUTF8Bytes, payload.hasPrefix(fragmentPrefix) else {
                    throw MultipartFailure.invalidPacket
                }
                let fields = payload.dropFirst(fragmentPrefix.count).split(
                    separator: ":", omittingEmptySubsequences: false)
                guard fields.count == 5 else { throw MultipartFailure.invalidPacket }
                let hash = String(fields[0])
                guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                else { throw MultipartFailure.invalidPacket }
                func canonical(_ value: Substring) throws -> Int {
                    guard let number = Int(value), String(number) == value else { throw MultipartFailure.invalidPacket }
                    return number
                }
                let total = try canonical(fields[1])
                let index = try canonical(fields[2])
                let parts = try canonical(fields[3])
                guard total > 0, total <= maximumPacketBytes, parts >= 2, parts <= maximumFrames,
                    parts == (total + fragmentBytes - 1) / fragmentBytes, index >= 0, index < parts,
                    let body = Data(base64Encoded: String(fields[4])), body.base64EncodedString() == fields[4],
                    body.count == (index == parts - 1 ? total - fragmentBytes * (parts - 1) : fragmentBytes)
                else { throw MultipartFailure.invalidPacket }
                digest = hash
                totalBytes = total
                ordinal = index
                count = parts
                bytes = body
            }
        }

        struct FragmentAccumulator {
            private let deadline: ContinuousClock.Instant
            private var lastNow: ContinuousClock.Instant
            private var digest: String?
            private var byteCount = 0
            private var frameCount = 0
            private var parts: [Int: Data] = [:]
            private var completed = false
            private var retired = false
            var isTerminal: Bool { completed || retired }
            var receivedFrameCount: Int { parts.count }
            var totalFrameCount: Int? { digest == nil ? nil : frameCount }

            init(now: ContinuousClock.Instant = ContinuousClock().now) {
                deadline = now + .seconds(120)
                lastNow = now
            }
            /// Reset is terminal. A fresh account/owner import creates a fresh accumulator.
            mutating func reset() {
                retired = true
                parts.removeAll()
                digest = nil
                byteCount = 0
                frameCount = 0
            }
            mutating func ingest(_ payload: String, now: ContinuousClock.Instant = ContinuousClock().now) throws
                -> String?
            {
                guard !retired, now >= lastNow, now < deadline else {
                    reset()
                    throw MultipartFailure.expired
                }
                lastNow = now
                if !payload.hasPrefix(fragmentPrefix) {
                    guard digest == nil, !completed else { throw MultipartFailure.conflictingTransfer }
                    let packet = try DevicePairingQRCode.packet(from: payload)
                    completed = true
                    return packet
                }
                let fragment = try Fragment(payload)
                if let digest {
                    guard digest == fragment.digest, byteCount == fragment.totalBytes, frameCount == fragment.count
                    else { throw MultipartFailure.conflictingTransfer }
                } else {
                    guard !completed else { throw MultipartFailure.conflictingTransfer }
                    digest = fragment.digest
                    byteCount = fragment.totalBytes
                    frameCount = fragment.count
                }
                if let old = parts[fragment.ordinal] {
                    guard old == fragment.bytes else { throw MultipartFailure.conflictingTransfer }
                    return nil
                }
                guard !completed else { throw MultipartFailure.conflictingTransfer }
                parts[fragment.ordinal] = fragment.bytes
                guard parts.count == frameCount else { return nil }
                var packet = Data()
                packet.reserveCapacity(byteCount)
                for ordinal in 0..<frameCount {
                    guard let part = parts[ordinal] else { throw MultipartFailure.invalidPacket }
                    packet.append(part)
                }
                guard packet.count == byteCount,
                    SHA256.hash(data: packet).map({ String(format: "%02x", $0) }).joined() == digest
                else {
                    reset()
                    throw MultipartFailure.invalidPacket
                }
                completed = true
                return packet.base64EncodedString()
            }
        }

        static func packet(from payload: String) throws -> String {
            guard payload.utf8.count <= maximumUTF8Bytes else { throw Failure.invalidPacket }
            let compressed = payload.hasPrefix(compressedPrefix)
            guard compressed || payload.hasPrefix(prefix) else { throw Failure.invalidPacket }
            let label = compressed ? compressedPrefix : prefix
            let encoded = String(payload.dropFirst(label.count))
            guard !encoded.isEmpty, let bytes = Data(base64Encoded: encoded),
                bytes.base64EncodedString() == encoded
            else { throw Failure.invalidPacket }
            let packet = compressed ? try decompressed(bytes).base64EncodedString() : encoded
            _ = try DeviceVerificationPacketInput.decode(packet)
            return packet
        }

        // Fixed output buffers bound allocation and refuse truncated decompression.
        private static func compressed(_ bytes: Data, capacity: Int) throws -> Data {
            var output = [UInt8](repeating: 0, count: capacity)
            let count = bytes.withUnsafeBytes { source in
                output.withUnsafeMutableBufferPointer { destination in
                    compression_encode_buffer(
                        destination.baseAddress!, capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!, bytes.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard count > 0 else { throw MultipartFailure.tooLarge }
            return Data(output.prefix(count))
        }
        private static func decompressed(_ bytes: Data) throws -> Data {
            var output = [UInt8](repeating: 0, count: maximumPacketBytes + 1)
            let capacity = output.count
            let count = bytes.withUnsafeBytes { source in
                output.withUnsafeMutableBufferPointer { destination in
                    compression_decode_buffer(
                        destination.baseAddress!, capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!, bytes.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard count > 0, count <= maximumPacketBytes else { throw Failure.invalidPacket }
            return Data(output.prefix(count))
        }
    }
#endif
