#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation

    /// A purpose-tagged transport envelope, never a source of pairing authority.
    nonisolated enum DevicePairingQRCode {
        static let prefix = "whitenoise-pairing:v1:"
        static let maximumUTF8Bytes = 2200

        static func payload(packet: String) throws -> String {
            guard packet.utf8.count <= maximumUTF8Bytes - prefix.utf8.count else {
                throw DeviceVerificationPacketInput.Error.invalidPacket
            }
            _ = try DeviceVerificationPacketInput.decode(packet)
            guard !packet.isEmpty, Data(base64Encoded: packet)?.base64EncodedString() == packet else {
                throw DeviceVerificationPacketInput.Error.invalidPacket
            }
            return prefix + packet
        }

        static func packet(from payload: String) throws -> String {
            guard payload.utf8.count <= maximumUTF8Bytes, payload.hasPrefix(prefix) else {
                throw DeviceVerificationPacketInput.Error.invalidPacket
            }
            let packet = String(payload.dropFirst(prefix.count))
            guard try self.payload(packet: packet) == payload else {
                throw DeviceVerificationPacketInput.Error.invalidPacket
            }
            return packet
        }
    }
#endif
