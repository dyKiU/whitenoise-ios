import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    @MainActor @Suite struct IOSDeviceLinkingAutomaticActivationTests {
        private func waitFor(_ condition: () -> Bool) async {
            for _ in 0..<200 {
                if condition() { return }
                await Task.yield()
            }
        }
        @Test func lateAutomaticBootstrapCannotEscapeRetiredAccountScope() async throws {
            let original = LifetimeSession(noPointer: .init())
            let owner = DeviceLinkingAccountScope(accountRef: "test", session: original)
            let activation = Task { try await owner.activateAutomaticPairing(displayBootstrap: true) }
            await waitFor { original.bootstrapIsWaiting }
            #expect(original.bootstrapIsWaiting)
            owner.invalidate()
            original.finishBootstrap()
            await #expect(throws: CancellationError.self) { try await activation.value }
            #expect(throws: CancellationError.self) { try owner.setupPacket() }
            try await owner.cancel()
            original.stream.finishWithClosed()
        }

        @Test func scannerActivatesWithoutShowingAResponseQR() async throws {
            let original = LifetimeSession(noPointer: .init())
            let owner = DeviceLinkingAccountScope(accountRef: "test", session: original)
            let activation = Task { try await owner.activateAutomaticPairing(displayBootstrap: false) }
            await waitFor { original.bootstrapIsWaiting }
            #expect(original.bootstrapIsWaiting)
            original.finishBootstrap()
            try await activation.value
            #expect(try owner.setupPacket().isEmpty)
            try await owner.cancel()
            original.stream.finishWithClosed()
        }

        @Test func automaticEnrollmentPreservesExplicitSharingChoiceAndDisplayedRevision() async throws {
            let original = LifetimeSession(noPointer: .init())
            let owner = DeviceLinkingAccountScope(accountRef: "test", session: original)
            let activation = Task { try await owner.activateAutomaticPairing(displayBootstrap: false) }
            await waitFor { original.bootstrapIsWaiting }
            #expect(original.bootstrapIsWaiting)
            original.finishBootstrap()
            try await activation.value
            try await owner.continueLinking(displayedRevision: 7)
            try await owner.continueLinkingAndShareChats(displayedRevision: 9)
            #expect(original.recordedAutomaticChoices.map(\.0) == [7, 9])
            #expect(original.recordedAutomaticChoices.map(\.1) == [false, true])
            try await owner.cancel()
            await #expect(throws: CancellationError.self) {
                try await owner.continueLinkingAndShareChats(displayedRevision: 10)
            }
            #expect(original.recordedAutomaticChoices.count == 2)
            original.stream.finishWithClosed()
        }

    }
#endif
