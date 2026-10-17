#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import Testing
    @testable import whitenoise_ios
    @MainActor struct PairingMultipartQRCodeTests {
        @Test func boundedMultipartTransportContract() throws {
            #expect(try PairingMultipartQRContractChecks.run() == 10)
        }
    }
    /// The same checks execute against the actual codec in the app and standalone native lane.
    enum PairingMultipartQRContractChecks {
        enum Failure: Error { case contract }
        static func check(_ condition: Bool) throws { if !condition { throw Failure.contract } }
        static func refused(_ operation: () throws -> Void) throws {
            do { try operation() } catch is DevicePairingQRCode.MultipartFailure { return } catch is DeviceVerificationPacketInput.Error { return }
            throw Failure.contract
        }
        static func randomBytes(_ count: Int) -> Data {
            var state: UInt64 = 0x1234_5678_9ABC_DEF1
            return Data(
                (0..<count).map { _ in
                    state ^= state << 13
                    state ^= state >> 7
                    state ^= state << 17
                    return UInt8(truncatingIfNeeded: state)
                })
        }
        static func changed(_ frame: String, field: Int, value: String) -> String {
            var fields = frame.dropFirst(DevicePairingQRCode.fragmentPrefix.count).split(
                separator: ":", omittingEmptySubsequences: false
            ).map(String.init)
            fields[field] = value
            return DevicePairingQRCode.fragmentPrefix + fields.joined(separator: ":")
        }
        static func run() throws -> Int {
            let now = ContinuousClock().now
            let small = Data(repeating: 9, count: 128)
            let compressed = Data(repeating: 7, count: 2016)
            try check(try DevicePairingQRCode.payloads(packet: small.base64EncodedString()) == [DevicePairingQRCode.payload(packet: small.base64EncodedString())])
            try check(try DevicePairingQRCode.payloads(packet: compressed.base64EncodedString()) == [DevicePairingQRCode.payload(packet: compressed.base64EncodedString())])
            let bytes = randomBytes(4678)
            let pages = try DevicePairingQRCode.payloads(packet: bytes.base64EncodedString())
            try check(pages.count == 4 && pages.allSatisfy { $0.utf8.count <= 2200 })
            var reordered = DevicePairingQRCode.FragmentAccumulator(now: now)
            var restored: String?
            for frame in pages.reversed() {
                restored = try reordered.ingest(frame, now: now)
                try check(try reordered.ingest(frame, now: now) == nil)
            }
            try check(restored == bytes.base64EncodedString())
            try check(reordered.receivedFrameCount == 4 && reordered.totalFrameCount == 4)

            var conflict = DevicePairingQRCode.FragmentAccumulator(now: now)
            _ = try conflict.ingest(pages[0], now: now)
            try refused {
                _ = try conflict.ingest(
                    changed(pages[0], field: 4, value: Data(repeating: 1, count: 1536).base64EncodedString()), now: now)
            }
            try refused {
                _ = try conflict.ingest(changed(pages[1], field: 0, value: String(repeating: "a", count: 64)), now: now)
            }
            for frame in pages.dropFirst() { restored = try conflict.ingest(frame, now: now) }
            try check(restored == bytes.base64EncodedString())

            var corrupt = DevicePairingQRCode.FragmentAccumulator(now: now)
            for frame in pages.dropLast() {
                _ = try corrupt.ingest(changed(frame, field: 0, value: String(repeating: "0", count: 64)), now: now)
            }
            try refused {
                _ = try corrupt.ingest(
                    changed(pages.last!, field: 0, value: String(repeating: "0", count: 64)), now: now)
            }
            try check(corrupt.receivedFrameCount == 0)

            for (field, value) in [(1, "04678"), (1, "49153"), (2, "00"), (2, "-1"), (3, "33"), (3, "0"), (4, "AB==")] {
                var invalid = DevicePairingQRCode.FragmentAccumulator(now: now)
                try refused { _ = try invalid.ingest(changed(pages[0], field: field, value: value), now: now) }
                try check(invalid.receivedFrameCount == 0)
            }
            var invalid = DevicePairingQRCode.FragmentAccumulator(now: now)
            try refused { _ = try invalid.ingest(String(repeating: "a", count: 2201), now: now) }
            try refused { _ = try DevicePairingQRCode.packet(from: pages[0]) }

            let maximum = randomBytes(49152)
            let maximumPages = try DevicePairingQRCode.payloads(packet: maximum.base64EncodedString())
            try check(maximumPages.count == 32 && maximumPages.allSatisfy { $0.utf8.count <= 2200 })
            var full = DevicePairingQRCode.FragmentAccumulator(now: now)
            for frame in maximumPages { restored = try full.ingest(frame, now: now) }
            try check(restored == maximum.base64EncodedString())
            try refused { _ = try DevicePairingQRCode.payloads(packet: randomBytes(49153).base64EncodedString()) }

            var expiry = DevicePairingQRCode.FragmentAccumulator(now: now)
            _ = try expiry.ingest(pages[0], now: now + .seconds(119))
            try refused { _ = try expiry.ingest(pages[1], now: now + .seconds(120)) }
            try check(expiry.receivedFrameCount == 0)
            try refused { _ = try expiry.ingest(pages[0], now: now) }

            var retired = DevicePairingQRCode.FragmentAccumulator(now: now)
            _ = try retired.ingest(pages[0], now: now)
            retired.reset()
            try check(retired.receivedFrameCount == 0 && retired.totalFrameCount == nil)
            try refused { _ = try retired.ingest(pages[0], now: now) }

            var backwards = DevicePairingQRCode.FragmentAccumulator(now: now)
            _ = try backwards.ingest(pages[0], now: now + .seconds(1))
            try refused { _ = try backwards.ingest(pages[1], now: now) }
            var mixed = DevicePairingQRCode.FragmentAccumulator(now: now)
            _ = try mixed.ingest(pages[0], now: now)
            try refused { _ = try mixed.ingest(DevicePairingQRCode.payload(packet: small.base64EncodedString()), now: now) }
            return 10
        }
    }
#endif
