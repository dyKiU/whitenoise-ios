import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // Immutable control; the generated superclass requires restating its unchecked conformance.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class EnrollmentSubscription: DeviceLinkingSubscription, @unchecked Sendable {
        private let lock = NSLock()
        private var emitted = false
        override func close() {}
        override func next() async throws -> DeviceLinkingSnapshotFfi {
            let first = lock.withLock {
                let first = !emitted
                emitted = true
                return first
            }
            guard first else { throw MarmotKitError.DeviceLinkingClosed }
            return .init(revision: 7, phase: .verificationCompleteEnrollmentPending, decimals: nil)
        }
    }

    // Generated superclass conformance is unchecked; NSLock protects all mutable control state.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class EnrollmentSession: DeviceLinkingSession, @unchecked Sendable {
        private let lock = NSLock()
        private let stream = EnrollmentSubscription(noPointer: .init())
        private var failedCleanup = false
        private var cancellations = 0
        var cancelCount: Int { lock.withLock { cancellations } }
        func failCancellation(_ value: Bool) { lock.withLock { failedCleanup = value } }
        private var calls: [String] = []
        private var received: [Data] = []
        private var rejected = false
        private var pause = false
        private var pending: CheckedContinuation<Data, Never>?
        var actions: [String] { lock.withLock { calls } }
        var packets: [Data] { lock.withLock { received } }
        var isWaiting: Bool { lock.withLock { pending != nil } }
        override func subscribe() -> DeviceLinkingSubscription { stream }
        override func cancel() async throws {
            lock.withLock { cancellations += 1 }
            if lock.withLock({ failedCleanup }) { throw MarmotKitError.DeviceLinkingRuntimeUnavailable }
        }
        override func continueLinking(displayedRevision: UInt64) async throws {
            lock.withLock { calls.append("continue:\(displayedRevision)") }
            if lock.withLock({ rejected }) { throw MarmotKitError.DeviceLinkingStaleRevision }
        }
        override func enrollmentPacket(displayedRevision: UInt64) async throws -> Data {
            lock.withLock { calls.append("export:\(displayedRevision)") }
            if lock.withLock({ pause }) {
                return await withCheckedContinuation { continuation in
                    lock.withLock { pending = continuation }
                }
            }
            return Data([1, 2, 3])
        }
        override func receiveEnrollmentPacket(displayedRevision: UInt64, packet: Data) async throws {
            lock.withLock {
                calls.append("receive:\(displayedRevision)")
                received.append(packet)
            }
        }
        override func finalizeLinking(displayedRevision: UInt64) async throws {
            lock.withLock { calls.append("finalize:\(displayedRevision)") }
        }
        func rejectRevision() { lock.withLock { rejected = true } }
        func pauseExport() { lock.withLock { pause = true } }
        func finishExport() {
            let continuation = lock.withLock {
                let result = pending
                pending = nil
                return result
            }
            continuation?.resume(returning: Data([1, 2, 3]))
        }
    }

    // Generated superclass conformance is unchecked; NSLock protects mutable controls.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class ScopeApproval: DeviceLinkingApproval, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [UInt64] = []
        private var received: [Data] = []
        private var cancellations = 0
        private var failCleanup = false
        private var rejectRevision = false
        private var pause = false
        private var phase: DeviceLinkingApprovalPhaseFfi = .awaitingApproval
        private var pending: CheckedContinuation<DeviceLinkingApprovalSnapshotFfi, Never>?
        var revisions: [UInt64] { lock.withLock { calls } }
        var packets: [Data] { lock.withLock { received } }
        var cancelCount: Int { lock.withLock { cancellations } }
        var isWaiting: Bool { lock.withLock { pending != nil } }
        override func snapshot() async throws -> DeviceLinkingApprovalSnapshotFfi {
            if lock.withLock({ pause }) {
                return await withCheckedContinuation { continuation in lock.withLock { pending = continuation } }
            }
            return DeviceLinkingApprovalSnapshotFfi(revision: 7, phase: lock.withLock { phase })
        }
        override func approve(displayedRevision: UInt64) async throws {
            lock.withLock { calls.append(displayedRevision) }
            if lock.withLock({ rejectRevision }) { throw MarmotKitError.DeviceLinkingStaleRevision }
        }
        override func receiveEnrollmentPacket(displayedRevision: UInt64, packet: Data) async throws {
            lock.withLock {
                calls.append(displayedRevision)
                received.append(packet)
            }
        }
        override func cancel() async throws {
            lock.withLock { cancellations += 1 }
            if lock.withLock({ failCleanup }) { throw MarmotKitError.DeviceLinkingRuntimeUnavailable }
        }
        func failCancellation(_ value: Bool) { lock.withLock { failCleanup = value } }
        func rejectNextRevision() { lock.withLock { rejectRevision = true } }
        func pauseSnapshot() { lock.withLock { pause = true } }
        func expire() { lock.withLock { phase = .expired } }
        func finishSnapshot() {
            let continuation = lock.withLock {
                let result = pending
                pending = nil
                return result
            }
            continuation?.resume(returning: DeviceLinkingApprovalSnapshotFfi(revision: 7, phase: .awaitingApproval))
        }
    }

    @MainActor @Suite struct DeviceEnrollmentViewModelTests {
        private func withApp(_ operation: (AppState) async throws -> Void) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("EnrollmentModel-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try MarmotClient(rootPath: root.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(
                client: client, accountDefaults: IsolatedAccountDefaults.make(),
                runtimeClientFactory: { _, _, cursorPersistence, telemetryConfig in
                    try MarmotClient(
                        rootPath: root.path, relayUrls: ["wss://relay.example.invalid"],
                        cursorPersistence: cursorPersistence, telemetryConfig: telemetryConfig
                    )
                }
            )
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "A"
            do { try await operation(app) } catch {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                throw error
            }
            app.setAppSceneActive(false)
            await app.startRuntimeSuspension().value
        }
        private func waitFor(_ condition: () -> Bool) async {
            for _ in 0..<200 {
                if condition() { return }
                await Task.yield()
            }
        }
        private func sessionModel(_ app: AppState, original: EnrollmentSession) async throws
            -> DeviceEnrollmentViewModel
        {
            let scope = try await app.adoptDeviceLinkingFactory { _, _ in original }
            await waitFor { scope.latestSnapshot != nil }
            try #require(scope.latestSnapshot != nil)
            return try app.makeDeviceEnrollmentModel()
        }
        @Test func transportActionsUseOriginalRevisionAndBoundedOpaqueBytes() async throws {
            try await withApp { app in
                let original = EnrollmentSession(noPointer: .init())
                let held = try await app.adoptDeviceLinkingFactory { _, _ in original }
                let model = DeviceEnrollmentViewModel(
                    original: held, isCurrent: { app.accountStore.deviceLinkingScope === held },
                    cancel: {
                        try await app.accountStore.cancelDeviceLinking()
                    }, enrollmentSupported: true)
                try await model.performTransportAction(.continueLinking, displayedRevision: 7)
                try await model.performTransportAction(.exportPacket, displayedRevision: 8)
                #expect(model.outgoingPacket == Data([1, 2, 3]).base64EncodedString())
                try await model.performTransportAction(
                    .receivePacket, displayedRevision: 9, input: Data([4, 5]).base64EncodedString())
                try await model.performTransportAction(.finalizeLinking, displayedRevision: 10)
                #expect(original.actions == ["continue:7", "export:8", "receive:9", "finalize:10"])
                #expect(original.packets == [Data([4, 5])])
                original.rejectRevision()
                await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                    try await model.performTransportAction(.continueLinking, displayedRevision: 7)
                }
                try await model.cancel()
                #expect(model.outgoingPacket == nil)
            }
        }
        @Test func unsupportedTransportNeverInvokesOriginal() async throws {
            try await withApp { app in
                let original = EnrollmentSession(noPointer: .init())
                let scope = try await app.adoptDeviceLinkingFactory { _, _ in original }
                let model = DeviceEnrollmentViewModel(
                    original: scope, isCurrent: { app.accountStore.deviceLinkingScope === scope },
                    cancel: { try await app.accountStore.cancelDeviceLinking() }, enrollmentSupported: false)
                await #expect(throws: MarmotKitError.DeviceLinkingNotReady) {
                    try await model.performTransportAction(.continueLinking, displayedRevision: 7)
                }
                #expect(original.actions.isEmpty)
            }
        }

        @Test(arguments: [false, true]) func lateTransportExportCannotPopulateRetiredOwner(suspend: Bool) async throws {
            try await withApp { app in
                let original = EnrollmentSession(noPointer: .init())
                let held = try await app.adoptDeviceLinkingFactory { _, _ in original }
                let model = DeviceEnrollmentViewModel(
                    original: held,
                    isCurrent: {
                        app.accountStore.deviceLinkingScope === held && app.isAppSceneActive
                    }, cancel: { try await app.accountStore.cancelDeviceLinking() }, enrollmentSupported: true)
                original.pauseExport()
                let operation = Task { try? await model.performTransportAction(.exportPacket, displayedRevision: 7) }
                await waitFor { original.isWaiting }
                try #require(original.isWaiting)
                if suspend {
                    app.setAppSceneActive(false)
                    await app.startRuntimeSuspension().value
                } else {
                    app.activeAccountRef = "B"
                    app.activeAccountRef = "A"
                }
                original.finishExport()
                await operation.value
                #expect(model.outgoingPacket == nil && !model.isActive)
            }
        }

        @Test func malformedTransportInputAndCancellationNeverReuseDisplayedPacket() async throws {
            try await withApp { app in
                let original = EnrollmentSession(noPointer: .init())
                let held = try await app.adoptDeviceLinkingFactory { _, _ in original }
                let model = DeviceEnrollmentViewModel(
                    original: held, isCurrent: { app.accountStore.deviceLinkingScope === held },
                    cancel: {
                        try await app.accountStore.cancelDeviceLinking()
                    }, enrollmentSupported: true)
                await #expect(throws: DeviceEnrollmentPacketInput.Error.invalidPacket) {
                    try await model.performTransportAction(.receivePacket, displayedRevision: 7, input: "!")
                }
                #expect(original.actions.isEmpty)
                try await model.performTransportAction(.exportPacket, displayedRevision: 7)
                original.failCancellation(true)
                await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) { try await model.cancel() }
                #expect(model.outgoingPacket == nil && model.cleanupError != nil && !model.isActive)
                original.failCancellation(false)
                try await model.cancel()
                #expect(model.cleanupError == nil)
                #expect(original.cancelCount == 2)
            }
        }

        @Test func actualSdkCapabilityPreservesAlreadyHeldEnrollmentTransport() async throws {
            try await withApp { app in
                let original = EnrollmentSession(noPointer: .init())
                let held = try await sessionModel(app, original: original)
                let verification = app.makeDeviceVerificationViewModel()
                #expect(verification.enrollmentSupported)
                #expect(try verification.enrollmentTransport() === held)
            }
        }

        @Test func modelRequiresAlreadyHeldOriginal() async throws {
            try await withApp { app in
                #expect(throws: MarmotKitError.DeviceLinkingNotReady) { try app.makeDeviceEnrollmentModel() }
            }
        }
        @Test func explicitSessionActionsForwardCapturedRevisionBytesAndError() async throws {
            try await withApp { app in
                let original = EnrollmentSession(noPointer: .init())
                let model = try await sessionModel(app, original: original)
                #expect(try app.makeDeviceEnrollmentModel() === model)
                let shown = try #require(model.snapshot)
                try await model.continueLinking(displayedRevision: shown.revision)
                #expect(try await model.enrollmentPacket(displayedRevision: 8) == Data([1, 2, 3]))
                try await model.receiveEnrollmentPacket(displayedRevision: 9, packet: Data([4, 5]))
                try await model.finalizeLinking(displayedRevision: 10)
                #expect(original.actions == ["continue:7", "export:8", "receive:9", "finalize:10"])
                #expect(original.packets == [Data([4, 5])])
                original.rejectRevision()
                await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                    try await model.continueLinking(displayedRevision: shown.revision)
                }
                try await model.cancel()
            }
        }
        @Test func delayedPacketCannotEscapeActualAppAccountReplacementAndReturn() async throws {
            try await withApp { app in
                let original = EnrollmentSession(noPointer: .init())
                let model = try await sessionModel(app, original: original)
                original.pauseExport()
                let read = Task { try? await model.enrollmentPacket(displayedRevision: 7) }
                await waitFor { original.isWaiting }
                try #require(original.isWaiting)
                app.activeAccountRef = "B"
                app.activeAccountRef = "A"
                original.finishExport()
                #expect(await read.value == nil)
                #expect(!model.isActive && model.snapshot == nil)
                await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                    try await model.finalizeLinking(displayedRevision: 7)
                }
            }
        }
        @Test(arguments: [false, true]) func delayedPacketCannotEscapeSuspensionOrSameAccountRestart(restart: Bool)
            async throws
        {
            try await withApp { app in
                let original = EnrollmentSession(noPointer: .init())
                let model = try await sessionModel(app, original: original)
                let generation = app.runtimeEventsGeneration
                original.pauseExport()
                let read = Task { try? await model.enrollmentPacket(displayedRevision: 7) }
                await waitFor { original.isWaiting }
                try #require(original.isWaiting)
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                #expect(app.runtimeSuspendedForBackground)
                if restart {
                    app.setAppSceneActive(true)
                    await app.bootstrap()
                    app.activeAccountRef = "A"
                    #expect(app.runtimeEventsGeneration != generation)
                }
                original.finishExport()
                #expect(await read.value == nil)
                #expect(!model.isActive && model.snapshot == nil)
            }
        }
        @Test func explicitOriginalApprovalNeverComesFromRefreshOrDecode() async throws {
            try await withApp { app in
                let original = ScopeApproval(noPointer: .init())
                _ = try await app.adoptDeviceLinkingApprovalFactory { _, _ in original }
                let model = try await app.makeDeviceEnrollmentApprovalModel()
                #expect(try await app.makeDeviceEnrollmentApprovalModel() === model)
                try await model.refresh()
                let shown = try #require(model.snapshot)
                let packet = try DeviceEnrollmentPacketInput.decode("AQID")
                #expect(original.revisions.isEmpty)
                try await model.approve(displayedRevision: shown.revision)
                try await model.receiveEnrollmentPacket(displayedRevision: 8, packet: packet)
                original.rejectNextRevision()
                await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                    try await model.approve(displayedRevision: 9)
                }
                #expect(original.revisions == [7, 8, 9] && original.packets == [packet])
                try await model.cancel()
            }
        }
        @Test func actualAccountExitInvalidatesDelayedApprovalSnapshot() async throws {
            try await withApp { app in
                let original = ScopeApproval(noPointer: .init())
                _ = try await app.adoptDeviceLinkingApprovalFactory { _, _ in original }
                let model = try await app.makeDeviceEnrollmentApprovalModel()
                original.pauseSnapshot()
                let read = Task { try? await model.refresh() }
                await waitFor { original.isWaiting }
                try #require(original.isWaiting)
                app.setPhase(.ready)
                _ = await app.signOut()
                original.finishSnapshot()
                #expect(await read.value == nil)
                #expect(!model.isActive && model.snapshot == nil)
                #expect(original.revisions.isEmpty && original.cancelCount == 1)
            }
        }
        @Test func cancellationKeepsExactFailedOriginalCleanupRetryable() async throws {
            try await withApp { app in
                let original = EnrollmentSession(noPointer: .init())
                let model = try await sessionModel(app, original: original)
                original.failCancellation(true)
                await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) { try await model.cancel() }
                #expect(!model.isActive && model.snapshot == nil)
                original.failCancellation(false)
                try await model.cancel()
                #expect(original.cancelCount == 2)
            }
        }
        @Test func malformedOrOversizedInputCannotCreateAnAction() {
            for text in ["", "AQI", "AQID=", Data(repeating: 1, count: 16_385).base64EncodedString()] {
                #expect(throws: DeviceEnrollmentPacketInput.Error.invalidPacket) {
                    try DeviceEnrollmentPacketInput.decode(text)
                }
            }
        }
    }
#endif
