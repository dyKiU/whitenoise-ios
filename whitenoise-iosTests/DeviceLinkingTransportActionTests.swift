import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // Immutable control; the generated superclass requires restating its unchecked conformance.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class TransportSubscription: DeviceLinkingSubscription, @unchecked Sendable {
        override func closeStream() {}
        override func next() async throws -> DeviceLinkingSnapshotFfi { throw MarmotKitError.DeviceLinkingClosed }
    }

    // Generated superclass conformance is unchecked; NSLock protects all mutable control state.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class TransportSession: DeviceLinkingSession, @unchecked Sendable {
        private let lock = NSLock()
        private let stream = TransportSubscription(noPointer: .init())
        private var setups: [Data] = []
        private var packets: [Data] = []
        private var acknowledgements: [String] = []
        private var setupReads = 0
        private var rejectPacket = false
        var receivedSetups: [Data] { lock.withLock { setups } }
        var receivedPackets: [Data] { lock.withLock { packets } }
        var acknowledged: [String] { lock.withLock { acknowledgements } }
        var readCount: Int { lock.withLock { setupReads } }

        override func subscribe() -> DeviceLinkingSubscription { stream }
        override func cancel() async throws {}
        override func setupPacket() -> Data {
            lock.withLock { setupReads += 1 }
            return Data([5, 6, 7])
        }
        override func receiveSetupPacket(packet: Data) async throws { lock.withLock { setups.append(packet) } }
        override func receivePacket(packet: Data) async throws {
            lock.withLock { packets.append(packet) }
            if lock.withLock({ rejectPacket }) { throw MarmotKitError.DeviceLinkingClosed }
        }
        override func acknowledgePacket(acknowledgementId: String) async throws {
            lock.withLock { acknowledgements.append(acknowledgementId) }
        }
        func rejectNextPacket() { lock.withLock { rejectPacket = true } }
    }

    @MainActor @Suite struct DeviceLinkingTransportActionTests {
        @Test func transportPreservesOriginalOpaqueBytesAndAcknowledgement() async throws {
            let session = TransportSession(noPointer: .init())
            let scope = DeviceLinkingAccountScope(accountRef: "account", session: session)
            defer { scope.invalidate() }
            #expect(try scope.setupPacket() == Data([5, 6, 7]))
            try await scope.receiveSetupPacket(Data([1, 2, 3]))
            try await scope.receivePacket(Data([4, 5, 6]))
            try await scope.acknowledgePacket("opaque-ack")
            #expect(session.readCount == 1)
            #expect(session.receivedSetups == [Data([1, 2, 3])])
            #expect(session.receivedPackets == [Data([4, 5, 6])])
            #expect(session.acknowledged == ["opaque-ack"])
        }

        @Test func retiredScopeDoesNotAccessAnyTransportAction() async throws {
            let session = TransportSession(noPointer: .init())
            let scope = DeviceLinkingAccountScope(accountRef: "account", session: session)
            scope.invalidate()
            #expect(throws: CancellationError.self) { try scope.setupPacket() }
            await #expect(throws: CancellationError.self) { try await scope.receiveSetupPacket(Data([1])) }
            await #expect(throws: CancellationError.self) { try await scope.receivePacket(Data([2])) }
            await #expect(throws: CancellationError.self) { try await scope.acknowledgePacket("opaque-ack") }
            #expect(session.readCount == 0)
            #expect(session.receivedSetups.isEmpty)
            #expect(session.receivedPackets.isEmpty)
            #expect(session.acknowledged.isEmpty)
        }

        @Test func sdkPacketRejectionIsPreservedWithoutAcknowledgement() async throws {
            let session = TransportSession(noPointer: .init())
            session.rejectNextPacket()
            let scope = DeviceLinkingAccountScope(accountRef: "account", session: session)
            defer { scope.invalidate() }
            do {
                try await scope.receivePacket(Data([9]))
                Issue.record("An SDK-rejected packet must not be accepted")
            } catch MarmotKitError.DeviceLinkingClosed {
                #expect(session.receivedPackets == [Data([9])])
                #expect(session.acknowledged.isEmpty)
            }
        }
    }
#endif
