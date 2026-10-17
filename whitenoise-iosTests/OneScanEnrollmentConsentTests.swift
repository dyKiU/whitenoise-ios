import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // Generated superclass is unchecked; NSLock protects the original action record.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class OneScanApproval: DeviceLinkingApproval, @unchecked Sendable {
        private let lock = NSLock()
        private var shared: [UInt64] = []
        var sharedRevisions: [UInt64] { lock.withLock { shared } }
        override func snapshot() async throws -> DeviceLinkingApprovalSnapshotFfi {
            .init(revision: 7, phase: .awaitingApproval)
        }
        override func reviewMetadata(displayedRevision: UInt64) async throws -> DeviceLinkingApprovalReviewMetadataFfi {
            .init(
                revision: displayedRevision, sourceDevicePublicKey: Data(repeating: 1, count: 32),
                joiningDevicePublicKey: Data(repeating: 2, count: 32), existingDeviceCount: 2)
        }
        override func approveAndShareChats(displayedRevision: UInt64) async throws {
            lock.withLock { shared.append(displayedRevision) }
        }
        override func cancel() async throws {}
    }

    @MainActor @Suite struct OneScanEnrollmentConsentTests {
        @Test func siblingSharingRequiresTheDisplayedReviewAndExplicitAction() async throws {
            let original = OneScanApproval(noPointer: .init())
            let owner = DeviceLinkingApprovalScope(accountRef: "test", approval: original)
            let model = DeviceEnrollmentApprovalViewModel(original: owner, isCurrent: { true }, cancel: {})
            try await model.refreshForDisplay()
            #expect(model.reviewDisplay?.revision == 7)
            #expect(original.sharedRevisions.isEmpty)
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                try await model.performReviewAction(.approveAndShareChats, displayedRevision: 6)
            }
            #expect(original.sharedRevisions.isEmpty)
            try await model.performReviewAction(.approveAndShareChats, displayedRevision: 7)
            #expect(original.sharedRevisions == [7])
            model.invalidate()
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await model.performReviewAction(.approveAndShareChats, displayedRevision: 7)
            }
            #expect(original.sharedRevisions == [7])
            try await owner.cancel()
        }

        @Test func enrollmentSharesOnlyAfterExplicitUserAction() async throws {
            let original = LifetimeSession(noPointer: .init())
            let owner = DeviceLinkingAccountScope(accountRef: "test", session: original)
            let activation = Task { try await owner.activateAutomaticPairing(displayBootstrap: false) }
            for _ in 0..<200 {
                if original.bootstrapIsWaiting { break }
                await Task.yield()
            }
            #expect(original.bootstrapIsWaiting)
            original.finishBootstrap()
            try await activation.value
            let model = DeviceEnrollmentViewModel(
                original: owner, isCurrent: { true }, cancel: {}, enrollmentSupported: true)
            #expect(original.recordedAutomaticChoices.isEmpty)
            try await model.performTransportAction(.shareChats, displayedRevision: 7)
            #expect(original.recordedAutomaticChoices.map(\.0) == [7])
            #expect(original.recordedAutomaticChoices.map(\.1) == [true])
            model.invalidate()
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await model.performTransportAction(.shareChats, displayedRevision: 8)
            }
            #expect(original.recordedAutomaticChoices.count == 1)
            try await owner.cancel()
            original.stream.finishWithClosed()
        }
    }
#endif
