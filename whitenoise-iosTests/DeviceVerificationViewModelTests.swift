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
        override func closeStream() {
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

        @Test func scanStartsExchangeWithoutConfirmingComparisonOrSharing() async throws {
            let store = AccountStore(defaults: IsolatedAccountDefaults.make())
            store.activeAccountRef = "scan-test"
            let session = VerificationSession(noPointer: .init())
            let original = try await store.holdDeviceLinkingSession(session, accountRef: "scan-test")
            var enrollmentCalls = 0
            let model = DeviceVerificationViewModel(
                begin: { original }, cancel: {}, approve: { _, _ in original },
                targets: { [] }, verificationSupported: true, enrollmentSupported: true,
                enrollment: {
                    enrollmentCalls += 1
                    throw MarmotKitError.DeviceLinkingNotReady
                })
            try await model.scanAndSync(request: Data("WNPAIR1:synthetic-bootstrap".utf8))
            #expect(model.owner === original)
            #expect(enrollmentCalls == 0)
            #expect(session.confirmed.isEmpty)
            try await store.cancelDeviceLinking()
        }

        @Test func cancellingScanDuringTargetReadPreventsFactory() async throws {
            var read: CheckedContinuation<[DeviceLinkingTargetFfi], Never>?
            var factoryCalls = 0
            let model = DeviceVerificationViewModel(
                begin: { throw MarmotKitError.DeviceLinkingNotReady }, cancel: {},
                approve: { _, _ in
                    factoryCalls += 1
                    throw MarmotKitError.DeviceLinkingNotReady
                }, targets: { await withCheckedContinuation { read = $0 } }, verificationSupported: true)
            let task = Task { try await model.scanAndSync(request: Data("WNPAIR1:synthetic-bootstrap".utf8)) }
            for _ in 0..<200 {
                if read != nil { break }
                await Task.yield()
            }
            let continuation = try #require(read)
            task.cancel()
            continuation.resume(returning: [])
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(factoryCalls == 0 && model.owner == nil)
        }

        @Test(arguments: [0, 1, 2]) func scanUsesFreshUnambiguousTargetWithoutGrantingTrust(count: Int) async throws {
            var inputs: [(Data, Data?)] = []
            var reads = 0
            var confirmations = 0
            let model = DeviceVerificationViewModel(
                begin: { throw MarmotKitError.DeviceLinkingNotReady }, cancel: {},
                approve: { request, target in
                    inputs.append((request, target))
                    throw MarmotKitError.DeviceLinkingNotReady
                },
                targets: {
                    reads += 1
                    return (0..<count).map { .init(selector: Data([UInt8($0)]), deviceCount: 2) }
                }, verificationSupported: true,
                enrollment: {
                    confirmations += 1
                    throw MarmotKitError.DeviceLinkingNotReady
                })
            let request = Data("WNPAIR1:synthetic-bootstrap".utf8)
            await #expect(throws: (any Error).self) { try await model.scanAndSync(request: request) }
            #expect(reads == 1)
            #expect(inputs.count == (count > 1 ? 0 : 1))
            if count <= 1 {
                #expect(inputs[0].0 == request)
                #expect(inputs[0].1 == (count == 0 ? nil : Data([0])))
            }
            #expect(confirmations == 0 && model.owner == nil)
        }

        @Test func invalidScanAndFailedTargetReadCannotStartBootstrap() async throws {
            var reads = 0
            var factories = 0
            let model = DeviceVerificationViewModel(
                begin: { throw MarmotKitError.DeviceLinkingNotReady }, cancel: {},
                approve: { _, _ in
                    factories += 1
                    throw MarmotKitError.DeviceLinkingNotReady
                },
                targets: {
                    reads += 1
                    throw MarmotKitError.DeviceLinkingRuntimeUnavailable
                }, verificationSupported: true)
            for request in [Data(), Data("not-a-pairing-code".utf8), Data(repeating: 65, count: 1025)] {
                await #expect(throws: (any Error).self) { try await model.scanAndSync(request: request) }
            }
            #expect(reads == 0 && factories == 0)
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                try await model.scanAndSync(request: Data("WNPAIR1:synthetic-bootstrap".utf8))
            }
            #expect(reads == 1 && factories == 0)
        }

        @Test func firstDeviceSetupRequiresSuccessfulEmptyReadAndPreservesNilFactoryInput() async throws {
            let store = AccountStore(defaults: IsolatedAccountDefaults.make())
            store.activeAccountRef = "original"
            let session = VerificationSession(noPointer: .init())
            var inputs: [(Data, Data?)] = []
            let model = DeviceVerificationViewModel(
                isCurrent: { store.activeAccountRef == "original" },
                cancel: { try await store.cancelDeviceLinking() },
                approve: { bytes, selector in
                    inputs.append((bytes, selector))
                    return try await store.holdDeviceLinkingSession(session, accountRef: "original")
                }, targets: { [] }, verificationSupported: true)
            #expect(!model.offersFirstDeviceSetupAttempt)
            try await model.loadTargets()
            #expect(model.offersFirstDeviceSetupAttempt)
            let bytes = Data([1, 2, 3])
            try await model.approveFirstDeviceSetup(request: bytes)
            #expect(inputs.count == 1 && inputs[0].0 == bytes && inputs[0].1 == nil)
            try await model.confirm(displayedRevision: 4)
            #expect(session.confirmed == [4])
            try await model.cancel()
        }

        @Test func failedOrInflightReadNeverFallsBackToFirstDeviceSetup() async throws {
            var failRead = false
            var delayed: CheckedContinuation<[DeviceLinkingTargetFfi], Never>?
            var blockRead = false
            var calls = 0
            let model = DeviceVerificationViewModel(
                approve: { _, _ in
                    calls += 1
                    throw MarmotKitError.DeviceLinkingRuntimeUnavailable
                },
                targets: {
                    if failRead { throw MarmotKitError.DeviceLinkingRuntimeUnavailable }
                    if blockRead { return await withCheckedContinuation { delayed = $0 } }
                    return []
                }, verificationSupported: true)
            try await model.loadTargets()
            failRead = true
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) { try await model.loadTargets() }
            #expect(!model.offersFirstDeviceSetupAttempt)
            await #expect(throws: (any Error).self) { try await model.approveFirstDeviceSetup(request: Data([1])) }
            failRead = false
            blockRead = true
            let read = Task { try await model.loadTargets() }
            await waitFor { delayed != nil }
            try #require(delayed != nil)
            #expect(!model.offersFirstDeviceSetupAttempt)
            await #expect(throws: (any Error).self) { try await model.approveFirstDeviceSetup(request: Data([1])) }
            delayed?.resume(returning: [])
            try await read.value
            #expect(calls == 0)
        }

        @Test func selectedTargetAndAuthoritativeFactoryDenialNeverBecomeBootstrapFallback() async throws {
            var calls: [Data?] = []
            let target = Data([9])
            let model = DeviceVerificationViewModel(
                approve: { _, selected in
                    calls.append(selected)
                    throw MarmotKitError.DeviceLinkingNotReady
                },
                targets: { [.init(selector: target, deviceCount: 2)] }, verificationSupported: true)
            try await model.loadTargets()
            #expect(!model.offersFirstDeviceSetupAttempt)
            await #expect(throws: (any Error).self) { try await model.approveFirstDeviceSetup(request: Data([1])) }
            await #expect(throws: CancellationError.self) {
                try await model.approve(request: Data([1]), target: Data([8]))
            }
            await #expect(throws: MarmotKitError.DeviceLinkingNotReady) {
                try await model.approve(request: Data([1]), target: target)
            }
            #expect(calls.count == 1 && calls[0] == target && model.owner == nil)
        }

        @Test func firstDeviceAttemptPreservesActualSdkMissingAccountRefusal() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("FirstSetup-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try MarmotClient(rootPath: root.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(client: client, accountDefaults: IsolatedAccountDefaults.make())
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "missing"
            let model = DeviceVerificationViewModel(
                approve: { bytes, selector in
                    try await app.approveOwnedDeviceLinkingSession(request: bytes, target: selector)
                }, targets: { [] }, verificationSupported: true)
            try await model.loadTargets()
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                try await model.approveFirstDeviceSetup(request: Data([1]))
            }
            #expect(model.owner == nil && app.accountStore.deviceLinkingScope == nil)
            app.setAppSceneActive(false)
            await app.startRuntimeSuspension().value
        }

        @Test(arguments: [false, true]) func lateTargetReadCannotOfferSetupAfterActualOwnerRetirement(
            suspend: Bool
        ) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SetupRead-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try MarmotClient(rootPath: root.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(client: client, accountDefaults: IsolatedAccountDefaults.make())
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "A"
            let actualOwner = app.makeDeviceVerificationViewModel()
            var delayed: CheckedContinuation<[DeviceLinkingTargetFfi], Never>?
            var calls = 0
            let model = DeviceVerificationViewModel(
                isCurrent: { actualOwner.isActive },
                approve: { _, _ in
                    calls += 1
                    throw MarmotKitError.DeviceLinkingRuntimeUnavailable
                },
                targets: { await withCheckedContinuation { delayed = $0 } }, verificationSupported: true)
            let read = Task { try? await model.loadTargets() }
            await waitFor { delayed != nil }
            try #require(delayed != nil)
            if suspend {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
            } else {
                app.activeAccountRef = "B"
                app.activeAccountRef = "A"
            }
            delayed?.resume(returning: [])
            #expect(await read.value == nil && !model.offersFirstDeviceSetupAttempt)
            await #expect(throws: CancellationError.self) {
                try await model.approveFirstDeviceSetup(request: Data([1]))
            }
            #expect(calls == 0 && model.targets.isEmpty)
            app.setAppSceneActive(false)
            await app.startRuntimeSuspension().value
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
