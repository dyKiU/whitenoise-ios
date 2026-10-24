#if WN_EXPERIMENTAL_DEVICE_SYNC
    import CoreImage
    import Foundation
    import Testing
    import UIKit
    @testable import whitenoise_ios

    @MainActor struct PairingQRImportMultipartTests {
        private func frames() throws -> [String] {
            try DevicePairingQRCode.payloads(packet: PairingMultipartQRContractChecks.randomBytes(8186).base64EncodedString())
        }

        @Test func cameraRetryAndSheetReopenRetainPartsAndOriginalDeadline() throws {
            let now = ContinuousClock().now
            let transport = DevicePairingQRImport(now: now, isCurrent: { true })
            let pages = try frames()
            #expect(try transport.receive(pages[0], now: now) == nil)
            #expect(try transport.receive(pages[0], now: now + .seconds(119)) == nil)
            #expect(transport.receivedFrames == 1 && transport.totalFrames == 6)
            #expect(throws: DevicePairingQRCode.MultipartFailure.self) {
                try transport.receive(pages[1], now: now + .seconds(120))
            }
            #expect(transport.terminal && transport.receivedFrames == 0)
        }

        @Test func changedAccountOrOriginalRefusesLateFrameAndClearsPartialBytes() throws {
            let current = MainActorTestFlag(true)
            let transport = DevicePairingQRImport(isCurrent: { current.value })
            let pages = try frames()
            _ = try transport.receive(pages[0])
            current.value = false
            #expect(throws: DevicePairingQRCode.MultipartFailure.self) { try transport.receive(pages[1]) }
            #expect(transport.terminal && transport.receivedFrames == 0)
            current.value = true
            #expect(throws: DevicePairingQRCode.MultipartFailure.self) { try transport.receive(pages[0]) }
        }

        @Test func explicitAbandonmentRetiresOldTicketAndFreshImportDoesNotReuseParts() throws {
            let pages = try frames()
            let old = DevicePairingQRImport(isCurrent: { true })
            _ = try old.receive(pages[0])
            old.retire()
            let next = DevicePairingQRImport(isCurrent: { true })
            #expect(old.ticket != next.ticket)
            #expect(throws: DevicePairingQRCode.MultipartFailure.self) { try old.receive(pages[1]) }
            #expect(try next.receive(pages[1]) == nil)
            #expect(next.receivedFrames == 1)
        }

        @Test func completedImportStagesOneCanonicalPacketWithoutReemitting() throws {
            let bytes = PairingMultipartQRContractChecks.randomBytes(8186)
            let pages = try DevicePairingQRCode.payloads(packet: bytes.base64EncodedString())
            let transport = DevicePairingQRImport(isCurrent: { true })
            var staged: [String] = []
            for page in pages.reversed() { if let packet = try transport.receive(page) { staged.append(packet) } }
            #expect(staged.count == 1)
            #expect(try DeviceVerificationPacketInput.decode(#require(staged.first)) == bytes)
            #expect(transport.terminal)
            #expect(throws: DevicePairingQRCode.MultipartFailure.self) { try transport.receive(pages[0]) }
        }

        @Test func actualImageRendererScansEveryEnrollmentSizedFrameBeforeStaging() throws {
            let bytes = PairingMultipartQRContractChecks.randomBytes(8186)
            let pages = try DevicePairingQRCode.payloads(packet: bytes.base64EncodedString())
            let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let transport = DevicePairingQRImport(isCurrent: { true })
            var packet: String?
            for page in pages {
                let image = try #require(QRCode.image(from: page, scale: 6))
                let decoded = detector.features(in: try #require(CIImage(image: image)))
                    .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
                #expect(decoded == [page])
                packet = try transport.receive(#require(decoded.first))
            }
            #expect(try DeviceVerificationPacketInput.decode(#require(packet)) == bytes)
        }
    }
#endif
