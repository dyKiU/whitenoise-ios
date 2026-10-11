#if WN_EXPERIMENTAL_DEVICE_SYNC
    import CoreImage
    import Testing
    import UIKit
    @testable import whitenoise_ios

    @Suite @MainActor struct DevicePairingQRCodeTests {
        @Test func opaqueBinaryPacketRoundTripsWithoutChangingNativeBytes() throws {
            let bytes = Data([0, 255, 1, 128, 42])
            let payload = try DevicePairingQRCode.payload(packet: bytes.base64EncodedString())
            #expect(payload == "whitenoise-pairing:v1:AP8BgCo=")
            let packet = try DevicePairingQRCode.packet(from: payload)
            #expect(try DeviceVerificationPacketInput.decode(packet) == bytes)
        }

        @Test(arguments: [
            "nsec1example", "npub1example", "marmot://profile/npub1example", "AP8BgCo=",
            "whitenoise-pairing:v2:AP8BgCo=", "whitenoise-pairing:v1:",
            "whitenoise-pairing:v1:AP8BgCo", "whitenoise-pairing:v1: AP8BgCo=",
        ])
        func unrelatedAndNoncanonicalCodesAreRefused(_ payload: String) {
            #expect(throws: DeviceVerificationPacketInput.Error.self) {
                try DevicePairingQRCode.packet(from: payload)
            }
        }

        @Test func oversizedPacketsNeverTruncateAndPasteStillSupportsNativeBound() throws {
            let packet = Data(repeating: 165, count: DevicePairingQRCode.maximumPacketBytes + 1)
                .base64EncodedString()
            #expect(throws: DeviceVerificationPacketInput.Error.self) {
                try DevicePairingQRCode.payload(packet: packet)
            }
            #expect(throws: DeviceVerificationPacketInput.Error.self) {
                try DevicePairingQRCode.packet(from: DevicePairingQRCode.prefix + packet)
            }
        }

        @Test func largestSupportedBinaryPacketSurvivesActualImageEncodingAndScanning() throws {
            let packet = Data(repeating: 165, count: 1632).base64EncodedString()
            let payload = try DevicePairingQRCode.payload(packet: packet)
            let image = try #require(QRCode.image(from: payload, scale: 6))
            let ciImage = try #require(CIImage(image: image))
            let detector = try #require(
                CIDetector(
                    ofType: CIDetectorTypeQRCode, context: nil,
                    options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let decoded = detector.features(in: ciImage).compactMap {
                ($0 as? CIQRCodeFeature)?.messageString
            }
            #expect(decoded == [payload])
            #expect(try DevicePairingQRCode.packet(from: #require(decoded.first)) == packet)
        }

        @Test func realSetupSizedPacketCompressesAndScansWithoutChangingNativeBytes() throws {
            let bytes = Data((0..<2016).map { UInt8(truncatingIfNeeded: $0 * 73 + 19) })
            let packet = bytes.base64EncodedString()
            let payload = try DevicePairingQRCode.payload(packet: packet)
            #expect(payload.hasPrefix(DevicePairingQRCode.compressedPrefix))
            let image = try #require(QRCode.image(from: payload, scale: 6))
            let detector = try #require(
                CIDetector(
                    ofType: CIDetectorTypeQRCode, context: nil,
                    options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let decoded = detector.features(in: try #require(CIImage(image: image)))
                .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            #expect(decoded == [payload])
            #expect(try DevicePairingQRCode.packet(from: #require(decoded.first)) == packet)
        }
        @Test func malformedCompressedInputIsRejected() {
            #expect(throws: DeviceVerificationPacketInput.Error.self) {
                try DevicePairingQRCode.packet(from: DevicePairingQRCode.compressedPrefix + "AQID")
            }
        }

        @Test func cameraRejectsWrongPurposeAndRequiresExplicitRetryBeforeStagingOnePacket() throws {
            var staged: [String] = []
            var rejected = 0
            let coordinator = QRScannerView.Coordinator(
                onScan: {
                    if let packet = try? DevicePairingQRCode.packet(from: $0) { staged.append(packet) }
                },
                onError: { _ in },
                validate: { (try? DevicePairingQRCode.packet(from: $0)) != nil },
                onInvalidPayload: { rejected += 1 })
            let payload = try DevicePairingQRCode.payload(packet: "AP8BgCo=")
            coordinator.receive("nsec1example")
            coordinator.receive(payload)
            #expect(rejected == 1 && staged.isEmpty)
            coordinator.resumeScanning(attempt: 1)
            coordinator.receive(payload)
            coordinator.receive(payload)
            #expect(staged == ["AP8BgCo="])
        }
    }
#endif
