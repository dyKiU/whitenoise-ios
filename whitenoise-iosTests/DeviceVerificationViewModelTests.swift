import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // Generated superclass requires unchecked conformance; NSLock owns mutable controls.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class VerificationStream: DeviceLinkingSubscription, @unchecked Sendable {
        private let lock = NSLock()
        private var emitted = false
        private var pending: CheckedContinuation<DeviceLinkingSnapshotFfi, Error>?
        override func next() async throws -> DeviceLinkingSnapshotFfi {
            let first = lock.withLock {
                let first = !emitted
                emitted = true
                return first
            }
            if first { return .init(revision: 7, phase: .comparisonAvailable, decimals: nil) }
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending = continuation }
            }
        }
        override func close() {
            let continuation = lock.withLock {
                let old = pending
                pending = nil
                return old
            }
            continuation?.resume(throwing: MarmotKitError.DeviceLinkingClosed)
        }
    }

    // Generated superclass requires unchecked conformance; NSLock owns mutable controls.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class VerificationSession: DeviceLinkingSession, @unchecked Sendable {
        let stream = VerificationStream(noPointer: .init())
        private let lock = NSLock()
        private var revisions: [UInt64] = []
        private var received: [Data] = []
        private var acknowledgements: [String] = []
        var receivedPackets: [Data] { lock.withLock { received } }
        var acknowledged: [String] { lock.withLock { acknowledgements } }
        private var pending: CheckedContinuation<[DeviceLinkingOutgoingPacketFfi], Never>?
        var confirmed: [UInt64] { lock.withLock { revisions } }
        var isWaiting: Bool { lock.withLock { pending != nil } }
        override func subscribe() -> DeviceLinkingSubscription { stream }
        override func cancel() async throws {}
        override func setupPacket() -> Data { Data([5, 6, 7]) }
        override func receivePacket(packet: Data) async throws { lock.withLock { received.append(packet) } }
        override func acknowledgePacket(acknowledgementId: String) async throws {
            lock.withLock { acknowledgements.append(acknowledgementId) }
        }
        override func confirmComparison(displayedRevision: UInt64) async throws {
            lock.withLock { revisions.append(displayedRevision) }
        }
        override func outgoingPackets() async throws -> [DeviceLinkingOutgoingPacketFfi] {
            await withCheckedContinuation { continuation in lock.withLock { pending = continuation } }
        }
        func finishPackets() {
            let continuation = lock.withLock {
                let old = pending
                pending = nil
                return old
            }
            continuation?.resume(returning: [])
        }
    }

    @MainActor @Suite struct DeviceVerificationViewModelTests {
        private func waitFor(_ condition: () -> Bool) async {
            for _ in 0..<200 {
                if condition() { return }
                await Task.yield()
            }
        }

        @Test func accountReplacementRetiresDisplayAndRejectsDelayedPackets() async throws {
            let store = AccountStore(defaults: IsolatedAccountDefaults.make())
            store.activeAccountRef = "original"
            let session = VerificationSession(noPointer: .init())
            let original = try await store.holdDeviceLinkingSession(session, accountRef: "original")
            let model = DeviceVerificationViewModel(
                owner: original, isCurrent: { store.deviceLinkingScope === original })
            await waitFor { original.latestSnapshot != nil }
            #expect(model.snapshot?.revision == 7)
            let packets = Task { try await model.outgoingPackets() }
            await waitFor { session.isWaiting }
            store.activeAccountRef = "replacement"
            session.finishPackets()
            await #expect(throws: CancellationError.self) { _ = try await packets.value }
            #expect(model.snapshot == nil)
            await #expect(throws: CancellationError.self) { try await model.confirm(displayedRevision: 7) }
            #expect(session.confirmed.isEmpty)
            try await store.cancelDeviceLinking()
        }

        @Test func actualRuntimeSuspensionRetiresRenderedRevision() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Verification-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = try MarmotClient(rootPath: directory.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(client: client, accountDefaults: IsolatedAccountDefaults.make())
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "original"
            let session = VerificationSession(noPointer: .init())
            let original = try await app.accountStore.holdDeviceLinkingSession(session, accountRef: "original")
            let model = DeviceVerificationViewModel(
                owner: original, isCurrent: { app.accountStore.deviceLinkingScope === original })
            await waitFor { original.latestSnapshot != nil }
            #expect(model.snapshot?.revision == 7)
            try await model.confirm(displayedRevision: 6)
            #expect(session.confirmed == [6])
            app.setAppSceneActive(false)
            await app.startRuntimeSuspension().value
            #expect(model.snapshot == nil)
            await #expect(throws: CancellationError.self) { try await model.confirm(displayedRevision: 7) }
            #expect(session.confirmed == [6])
        }

        @Test func sameAccountReturnDoesNotReviveOriginalDisplayTicket() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "VerificationReturn-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = try MarmotClient(rootPath: directory.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(client: client, accountDefaults: IsolatedAccountDefaults.make())
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "original"
            let session = VerificationSession(noPointer: .init())
            let original = try await app.accountStore.holdDeviceLinkingSession(session, accountRef: "original")
            let model = app.makeDeviceVerificationViewModel()
            await waitFor { original.latestSnapshot != nil }
            #expect(model.snapshot?.revision == 7)
            let ticket = app.accountStore.deviceLinkingOwnershipIdentity
            app.activeAccountRef = "replacement"
            app.activeAccountRef = "original"
            #expect(app.accountStore.deviceLinkingOwnershipIdentity != ticket)
            #expect(!model.isActive)
            #expect(model.snapshot == nil)
            await #expect(throws: CancellationError.self) { try await model.begin() }
            await #expect(throws: CancellationError.self) { try await model.cancel() }
            #expect(session.confirmed.isEmpty)
            app.setAppSceneActive(false)
            await app.startRuntimeSuspension().value
        }

        @Test func approvalKeepsOriginalOpaqueInputsAndRequiresExplicitAcknowledgement() async throws {
            let store = AccountStore(defaults: IsolatedAccountDefaults.make())
            store.activeAccountRef = "original"
            let session = VerificationSession(noPointer: .init())
            let target = Data([4, 3, 2])
            let request = Data([1, 2, 3])
            var inputs: [(Data, Data?)] = []
            let model = DeviceVerificationViewModel(
                isCurrent: { store.activeAccountRef == "original" },
                cancel: { try await store.cancelDeviceLinking() },
                approve: { received, selector in
                    inputs.append((received, selector))
                    return try await store.holdDeviceLinkingSession(session, accountRef: "original")
                },
                targets: { [.init(selector: target, deviceCount: 1)] },
                verificationSupported: true
            )
            try await model.loadTargets()
            await #expect(throws: CancellationError.self) {
                try await model.approve(request: request, target: Data([9]))
            }
            #expect(inputs.isEmpty)
            try await model.approve(request: request, target: target)
            #expect(inputs.count == 1)
            #expect(inputs[0].0 == request)
            #expect(inputs[0].1 == target)
            #expect(try model.setupPacket() == Data([5, 6, 7]))
            #expect(session.acknowledged.isEmpty)
            try await model.receivePacket(Data([8, 9]))
            #expect(session.receivedPackets == [Data([8, 9])])
            try await model.acknowledgePacket("original-ack")
            #expect(session.acknowledged == ["original-ack"])
            try await model.cancel()
        }

        @Test func packetInputIsCanonicalAndBoundedWithoutInterpretingPermission() throws {
            #expect(try DeviceVerificationPacketInput.decode("AQID") == Data([1, 2, 3]))
            #expect(throws: DeviceVerificationPacketInput.Error.self) { try DeviceVerificationPacketInput.decode("") }
            #expect(throws: DeviceVerificationPacketInput.Error.self) {
                try DeviceVerificationPacketInput.decode("A QID")
            }
            #expect(throws: DeviceVerificationPacketInput.Error.self) {
                try DeviceVerificationPacketInput.decode(String(repeating: "A", count: 65_537))
            }
        }
    }
#endif
