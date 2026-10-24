#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Testing

    @testable import whitenoise_ios

    struct DeviceVerificationFailureTests {
        @Test func nativeRejectionsRemainDistinctWithoutLoggingDetails() {
            let cases: [(MarmotKitError, DeviceVerificationFailure)] = [
                (.DeviceLinkingInvalidPacket, .invalidPacket),
                (.DeviceLinkingClosed, .closed),
                (.DeviceLinkingNotReady, .notReady),
                (.DeviceLinkingStaleRevision, .staleRevision),
                (.DeviceLinkingRuntimeUnavailable, .runtimeUnavailable),
                (.KeystoreUnavailable(details: "sensitive sentinel"), .secretStoreUnavailable),
                (.DeviceLinkingUnsupported, .unsupported),
                (.Runtime(details: "sensitive sentinel"), .other),
            ]
            for (error, expected) in cases {
                let category = DeviceVerificationFailure(error)
                #expect(category == expected)
                #expect(!category.rawValue.contains("sentinel"))
            }
        }

        @Test func inputAndHostErrorsNeverExposeTheirPayloads() {
            #expect(DeviceVerificationFailure(DeviceVerificationPacketInput.Error.invalidPacket) == .invalidPacket)
            #expect(DeviceVerificationFailure(CancellationError()) == .cancelled)
            let unknown = NSError(domain: "sensitive sentinel", code: 7, userInfo: [NSLocalizedDescriptionKey: "private data"])
            #expect(DeviceVerificationFailure(unknown) == .other)
            #expect(DeviceVerificationFailure(unknown).rawValue == "other")
        }
    }
#endif
