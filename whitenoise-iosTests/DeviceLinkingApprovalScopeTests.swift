import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // Generated superclass conformance is unchecked; NSLock protects mutable controls.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class ScopeApproval: DeviceLinkingApproval, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [UInt64] = []
        private var received: [Data] = []
        private var cancellations = 0
        private var failCleanup = false
        private var alreadyClosed = false
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
            if lock.withLock({ alreadyClosed }) { throw MarmotKitError.DeviceLinkingClosed }
            if lock.withLock({ failCleanup }) { throw MarmotKitError.DeviceLinkingRuntimeUnavailable }
        }
        func reportAlreadyClosed() { lock.withLock { alreadyClosed = true } }
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

    // Immutable generated stream control.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class ScopeSubscription: DeviceLinkingSubscription, @unchecked Sendable {
        override func closeStream() {}
        override func next() async throws -> DeviceLinkingSnapshotFfi { throw MarmotKitError.DeviceLinkingClosed }
    }

    // Generated superclass conformance is unchecked; NSLock protects cleanup controls.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class CleanupSession: DeviceLinkingSession, @unchecked Sendable {
        private let lock = NSLock()
        private var cancellations = 0
        private var failed = true
        var cancelCount: Int { lock.withLock { cancellations } }
        override func subscribe() -> DeviceLinkingSubscription { ScopeSubscription(noPointer: .init()) }
        override func cancel() async throws {
            lock.withLock { cancellations += 1 }
            if lock.withLock({ failed }) { throw MarmotKitError.DeviceLinkingRuntimeUnavailable }
        }
        func allowCleanup() { lock.withLock { failed = false } }
    }

    @MainActor @Suite struct DeviceLinkingApprovalScopeTests {
        private func waitFor(_ condition: () -> Bool) async {
            for _ in 0..<200 {
                if condition() { return }
                await Task.yield()
            }
        }
        private func hold(_ original: ScopeApproval, store: AccountStore) async throws -> DeviceLinkingApprovalScope {
            try await store.adoptDeviceLinkingApprovalFactory(
                accountRef: "A", isRuntimeCurrent: { true }, factory: { original })
        }

        @Test func nativeAlreadyClosedApprovalCompletesCleanup() async throws {
            let original = ScopeApproval(noPointer: .init())
            original.reportAlreadyClosed()
            let owner = DeviceLinkingApprovalScope(accountRef: "test", approval: original)
            try await owner.cancel()
            try await owner.cancel()
            #expect(owner.cleanupError == nil)
            #expect(original.cancelCount == 1)
            await #expect(throws: CancellationError.self) { _ = try await owner.snapshot() }
        }

        @Test func explicitActionsPreserveOriginalRevisionBytesAndSdkError() async throws {
            let original = ScopeApproval(noPointer: .init())
            let scope = DeviceLinkingApprovalScope(accountRef: "A", approval: original)
            let snapshot = try await scope.snapshot()
            #expect(snapshot.revision == 7)
            #expect(snapshot.phase == .awaitingApproval)
            try await scope.approve(displayedRevision: 7)
            try await scope.receiveEnrollmentPacket(displayedRevision: 8, packet: Data([1, 2]))
            original.rejectNextRevision()
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                try await scope.approve(displayedRevision: 6)
            }
            #expect(original.revisions == [7, 8, 6])
            #expect(original.packets == [Data([1, 2])])
            try await scope.cancel()
        }

        @Test func cancellationClosesAllPositiveActions() async throws {
            let original = ScopeApproval(noPointer: .init())
            let scope = DeviceLinkingApprovalScope(accountRef: "A", approval: original)
            try await scope.cancel()
            await #expect(throws: CancellationError.self) { try await scope.snapshot() }
            await #expect(throws: CancellationError.self) { try await scope.approve(displayedRevision: 7) }
            await #expect(throws: CancellationError.self) {
                try await scope.receiveEnrollmentPacket(displayedRevision: 7, packet: Data([1]))
            }
            #expect(original.revisions.isEmpty)
            #expect(original.cancelCount == 1)
        }

        @Test func delayedSnapshotCannotEscapeActualAccountReplacementAndReturn() async throws {
            let store = AccountStore(defaults: IsolatedAccountDefaults.make())
            store.activeAccountRef = "A"
            let original = ScopeApproval(noPointer: .init())
            let scope = try await hold(original, store: store)
            original.pauseSnapshot()
            let read = Task { try? await scope.snapshot() }
            await waitFor { original.isWaiting }
            try #require(original.isWaiting)
            store.activeAccountRef = "B"
            store.activeAccountRef = "A"
            original.finishSnapshot()
            #expect(await read.value == nil)
            #expect(store.deviceLinkingApprovalScope == nil)
            try await store.cancelDeviceLinking()
            #expect(original.cancelCount == 1)
        }

        @Test func ignoredLateFactoryCannotAttachAcrossAccountReplacementAndReturn() async throws {
            let store = AccountStore(defaults: IsolatedAccountDefaults.make())
            store.activeAccountRef = "A"
            let original = ScopeApproval(noPointer: .init())
            var result: CheckedContinuation<any DeviceLinkingApprovalProtocol, Never>?
            let pending = Task {
                try? await store.adoptDeviceLinkingApprovalFactory(accountRef: "A", isRuntimeCurrent: { true }) {
                    await withCheckedContinuation { result = $0 }
                }
            }
            await waitFor { result != nil }
            try #require(result != nil)
            store.activeAccountRef = "B"
            store.activeAccountRef = "A"
            result?.resume(returning: original)
            #expect(await pending.value == nil)
            #expect(store.deviceLinkingApprovalScope == nil)
            #expect(original.cancelCount == 1)
        }

        @Test func pendingFactoryDoesNotBlockSuspensionOrAdoptItsLateOriginal() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ApprovalScope-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = try MarmotClient(rootPath: directory.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(client: client, accountDefaults: IsolatedAccountDefaults.make())
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "A"
            let original = ScopeApproval(noPointer: .init())
            var result: CheckedContinuation<any DeviceLinkingApprovalProtocol, Never>?
            let pending = Task {
                try? await app.adoptDeviceLinkingApprovalFactory { _, _ in
                    await withCheckedContinuation { result = $0 }
                }
            }
            await waitFor { result != nil }
            try #require(result != nil)
            app.setAppSceneActive(false)
            await app.startRuntimeSuspension().value
            #expect(app.runtimeSuspendedForBackground)
            result?.resume(returning: original)
            #expect(await pending.value == nil)
            #expect(app.accountStore.deviceLinkingApprovalScope == nil)
            #expect(original.cancelCount == 1)
        }

        @Test func independentCleanupFailuresRetainExactOwnersAndBothRetry() async throws {
            let store = AccountStore(defaults: IsolatedAccountDefaults.make())
            store.activeAccountRef = "A"
            let session = CleanupSession(noPointer: .init())
            let sessionScope = try await store.holdDeviceLinkingSession(session, accountRef: "A")
            let original = ScopeApproval(noPointer: .init())
            original.failCancellation(true)
            let scope = try await hold(original, store: store)
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                try await store.cancelDeviceLinking()
            }
            #expect(session.cancelCount == 1)
            #expect(original.cancelCount == 1)
            #expect(store.retiringDeviceLinkingScope === sessionScope)
            #expect(store.retiringDeviceLinkingApprovalScope === scope)
            #expect(sessionScope.cleanupError != nil)
            #expect(scope.cleanupError != nil)
            session.allowCleanup()
            original.failCancellation(false)
            try await store.cancelDeviceLinking()
            #expect(session.cancelCount == 2)
            #expect(original.cancelCount == 2)
            #expect(store.retiringDeviceLinkingScope == nil)
            #expect(store.retiringDeviceLinkingApprovalScope == nil)
        }

        @Test func repeatedAcquisitionUsesOriginalOnlyUntilSdkTerminalObservation() async throws {
            let store = AccountStore(defaults: IsolatedAccountDefaults.make())
            store.activeAccountRef = "A"
            let original = ScopeApproval(noPointer: .init())
            var calls = 0
            let factory: @MainActor () async throws -> any DeviceLinkingApprovalProtocol = {
                calls += 1
                return original
            }
            let scope = try await store.adoptDeviceLinkingApprovalFactory(
                accountRef: "A", isRuntimeCurrent: { true }, factory: factory)
            let repeatScope = try await store.adoptDeviceLinkingApprovalFactory(
                accountRef: "A", isRuntimeCurrent: { true }, factory: factory)
            #expect(repeatScope === scope)
            #expect(calls == 1)
            original.expire()
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await store.adoptDeviceLinkingApprovalFactory(
                    accountRef: "A", isRuntimeCurrent: { true }, factory: factory)
            }
            #expect(calls == 1)
            try await store.cancelDeviceLinking()
        }

        @Test func multipleOriginalsAreRetainedOnRefusalAndFailedCleanupBlocksNewFactory() async throws {
            let store = AccountStore(defaults: IsolatedAccountDefaults.make())
            store.activeAccountRef = "A"
            let first = ScopeApproval(noPointer: .init())
            let second = ScopeApproval(noPointer: .init())
            var calls = 0
            let factory: @MainActor () async throws -> [any DeviceLinkingApprovalProtocol] = {
                calls += 1
                return [first, second]
            }
            await #expect(throws: MarmotKitError.DeviceLinkingNotReady) {
                try await store.adoptDeviceLinkingApprovalBatch(
                    accountRef: "A", isRuntimeCurrent: { true }, factory: factory)
            }
            await #expect(throws: MarmotKitError.DeviceLinkingNotReady) {
                try await store.adoptDeviceLinkingApprovalBatch(
                    accountRef: "A", isRuntimeCurrent: { true }, factory: factory)
            }
            #expect(calls == 1)
            #expect(first.cancelCount == 0)
            #expect(second.cancelCount == 0)
            #expect(store.deviceLinkingApprovalScope == nil)
            second.failCancellation(true)
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                try await store.cancelDeviceLinking()
            }
            #expect(first.cancelCount == 1)
            #expect(second.cancelCount == 1)
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                try await store.adoptDeviceLinkingApprovalBatch(
                    accountRef: "A", isRuntimeCurrent: { true }, factory: factory)
            }
            #expect(calls == 1)
            #expect(second.cancelCount == 2)
            #expect(store.retiringDeviceLinkingApprovalScope?.cleanupError != nil)
            second.failCancellation(false)
            try await store.cancelDeviceLinking()
            #expect(store.retiringDeviceLinkingApprovalScope == nil)
            let fresh = ScopeApproval(noPointer: .init())
            _ = try await hold(fresh, store: store)
            try await store.cancelDeviceLinking()
            #expect(fresh.cancelCount == 1)
        }

        @Test func lateFactoryCleanupFailureRetainsOriginalAndBlocksReplacement() async throws {
            let store = AccountStore(defaults: IsolatedAccountDefaults.make())
            store.activeAccountRef = "A"
            let original = ScopeApproval(noPointer: .init())
            original.failCancellation(true)
            var result: CheckedContinuation<any DeviceLinkingApprovalProtocol, Never>?
            let pending = Task {
                try? await store.adoptDeviceLinkingApprovalFactory(accountRef: "A", isRuntimeCurrent: { true }) {
                    await withCheckedContinuation { result = $0 }
                }
            }
            await waitFor { result != nil }
            try #require(result != nil)
            store.activeAccountRef = "B"
            result?.resume(returning: original)
            #expect(await pending.value == nil)
            #expect(original.cancelCount == 1)
            #expect(store.retiringDeviceLinkingApprovalScope?.cleanupError != nil)
            store.activeAccountRef = "A"
            var replacementCalls = 0
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                try await store.adoptDeviceLinkingApprovalFactory(
                    accountRef: "A", isRuntimeCurrent: { true },
                    factory: {
                        replacementCalls += 1
                        return ScopeApproval(noPointer: .init())
                    }
                )
            }
            #expect(replacementCalls == 0)
            original.failCancellation(false)
            try await store.cancelDeviceLinking()
            #expect(store.retiringDeviceLinkingApprovalScope == nil)
        }

        @Test func failedSessionCleanupAlsoBlocksFreshApprovalAcquisition() async throws {
            let store = AccountStore(defaults: IsolatedAccountDefaults.make())
            store.activeAccountRef = "A"
            let session = CleanupSession(noPointer: .init())
            _ = try await store.holdDeviceLinkingSession(session, accountRef: "A")
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                try await store.cancelDeviceLinking()
            }
            let approval = ScopeApproval(noPointer: .init())
            var calls = 0
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                try await store.adoptDeviceLinkingApprovalFactory(
                    accountRef: "A", isRuntimeCurrent: { true },
                    factory: {
                        calls += 1
                        return approval
                    }
                )
            }
            #expect(calls == 0)
            #expect(store.deviceLinkingApprovalScope == nil)
            session.allowCleanup()
            _ = try await hold(approval, store: store)
            try await store.cancelDeviceLinking()
            #expect(approval.cancelCount == 1)
        }
    }
#endif
