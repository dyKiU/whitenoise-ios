import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // Immutable control; the generated superclass requires restating its unchecked conformance.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class ActionSubscription: DeviceLinkingSubscription, @unchecked Sendable {
        override func closeStream() {}
        override func next() async throws -> DeviceLinkingSnapshotFfi {
            throw MarmotKitError.DeviceLinkingClosed
        }
    }

    // Generated superclass conformance is unchecked; NSLock protects all mutable control state.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class ActionSession: DeviceLinkingSession, @unchecked Sendable {
        private let lock = NSLock()
        private let stream = ActionSubscription(noPointer: .init())
        private var confirmed: [UInt64] = []
        private var packetReads = 0
        private var staleRevision = false
        private var pauseExport = false
        private var pendingExport: CheckedContinuation<[DeviceLinkingOutgoingPacketFfi], Never>?
        var confirmations: [UInt64] { lock.withLock { confirmed } }
        var readCount: Int { lock.withLock { packetReads } }
        var exportIsWaiting: Bool { lock.withLock { pendingExport != nil } }

        override func subscribe() -> DeviceLinkingSubscription { stream }
        override func cancel() async throws {}
        override func confirmComparison(displayedRevision: UInt64) async throws {
            lock.withLock { confirmed.append(displayedRevision) }
            if lock.withLock({ staleRevision }) { throw MarmotKitError.DeviceLinkingStaleRevision }
        }
        override func outgoingPackets() async throws -> [DeviceLinkingOutgoingPacketFfi] {
            lock.withLock { packetReads += 1 }
            if lock.withLock({ pauseExport }) {
                return await withCheckedContinuation { continuation in
                    lock.withLock { pendingExport = continuation }
                }
            }
            return [DeviceLinkingOutgoingPacketFfi(acknowledgementId: "test-packet", bytes: Data([1, 2, 3]))]
        }
        func pauseNextExport() { lock.withLock { pauseExport = true } }
        func rejectDisplayedRevision() { lock.withLock { staleRevision = true } }
        func finishExport() {
            let continuation = lock.withLock {
                let result = pendingExport
                pendingExport = nil
                return result
            }
            continuation?.resume(returning: [
                DeviceLinkingOutgoingPacketFfi(acknowledgementId: "test-packet", bytes: Data([1, 2, 3]))
            ])
        }
    }

    @MainActor @Suite struct DeviceLinkingOwnedActionTests {
        @Test func activeActionsUseTheOriginalSessionAndExactDisplayedRevision() async throws {
            let session = ActionSession(noPointer: .init())
            let scope = DeviceLinkingAccountScope(accountRef: "account", session: session)
            defer { scope.invalidate() }
            try await scope.confirmComparison(displayedRevision: 7)
            let packet = try await scope.outgoingPackets()
            #expect(session.confirmations == [7])
            #expect(session.readCount == 1)
            #expect(
                packet == [DeviceLinkingOutgoingPacketFfi(acknowledgementId: "test-packet", bytes: Data([1, 2, 3]))])
        }

        @Test func retiredOriginalRejectsConfirmationAndPacketReads() async throws {
            let session = ActionSession(noPointer: .init())
            let scope = DeviceLinkingAccountScope(accountRef: "account", session: session)
            scope.invalidate()
            await #expect(throws: CancellationError.self) {
                try await scope.confirmComparison(displayedRevision: 7)
            }
            await #expect(throws: CancellationError.self) {
                try await scope.outgoingPackets()
            }
            #expect(session.confirmations.isEmpty)
            #expect(session.readCount == 0)
        }

        @Test func sdkStaleRevisionRejectionRemainsAnError() async throws {
            let session = ActionSession(noPointer: .init())
            session.rejectDisplayedRevision()
            let scope = DeviceLinkingAccountScope(accountRef: "account", session: session)
            defer { scope.invalidate() }
            do {
                try await scope.confirmComparison(displayedRevision: 7)
                Issue.record("A rejected displayed revision must not be reported as confirmed")
            } catch MarmotKitError.DeviceLinkingStaleRevision {
                #expect(session.confirmations == [7])
            }
        }

        @Test func delayedPacketCannotEscapeTheRetiredOriginalScope() async throws {
            let session = ActionSession(noPointer: .init())
            session.pauseNextExport()
            let store = AccountStore(defaults: IsolatedAccountDefaults.make())
            store.activeAccountRef = "old"
            let scope = try await store.holdDeviceLinkingSession(session, accountRef: "old")
            defer { scope.invalidate() }
            let export = Task { try? await scope.outgoingPackets() }
            for _ in 0..<200 {
                if session.exportIsWaiting { break }
                await Task.yield()
            }
            try #require(session.exportIsWaiting)
            store.activeAccountRef = "replacement"
            session.finishExport()
            #expect(await export.value == nil)
            #expect(session.readCount == 1)
            #expect(store.deviceLinkingScope == nil)
            try await store.cancelDeviceLinking()
        }
    }
#endif
