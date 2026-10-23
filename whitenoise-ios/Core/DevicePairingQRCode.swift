#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Compression
    import Foundation

    /// A purpose-tagged transport envelope, never a source of pairing authority.
    nonisolated enum DevicePairingQRCode {
        /// Only a bounded transport format check; Core validates the actual attempt.
        static func isAutomaticBootstrap(_ bytes: Data) -> Bool {
            guard bytes.count <= 1024, let code = String(data: bytes, encoding: .utf8) else { return false }
            return code.hasPrefix("WNPAIR1:") || code.hasPrefix("WNPAIR2:")
        }

        static let prefix = "whitenoise-pairing:v1:"
        static let maximumUTF8Bytes = 2200
        static let compressedPrefix = "whitenoise-pairing:v2:deflate:"
        static let maximumPacketBytes = 49_152
        private typealias Failure = DeviceVerificationPacketInput.Error

        static func payload(packet: String) throws -> String {
            let bytes = try DeviceVerificationPacketInput.decode(packet)
            guard bytes.base64EncodedString() == packet else { throw Failure.invalidPacket }
            if packet.utf8.count <= maximumUTF8Bytes - prefix.utf8.count { return prefix + packet }
            let capacity = (maximumUTF8Bytes - compressedPrefix.utf8.count) / 4 * 3
            return compressedPrefix + (try compressed(bytes, capacity: capacity)).base64EncodedString()
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
            guard count > 0 else { throw Failure.invalidPacket }
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
