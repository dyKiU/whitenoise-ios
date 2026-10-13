import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // Immutable control; the generated superclass requires restating its unchecked conformance.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class EnrollmentSubscription: DeviceLinkingSubscription, @unchecked Sendable {
        override func closeStream() {}
        override func next() async throws -> DeviceLinkingSnapshotFfi {
            throw MarmotKitError.DeviceLinkingClosed
        }
    }

    // Generated superclass conformance is unchecked; NSLock protects all mutable control state.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class EnrollmentSession: DeviceLinkingSession, @unchecked Sendable {
        private let lock = NSLock()
        private let stream = EnrollmentSubscription(noPointer: .init())
        private var calls: [String] = []
        private var received: [Data] = []
        private var rejected = false
        private var pause = false
        private var pending: CheckedContinuation<Data, Never>?
        private var sharingPaused = false
        private var sharingPending: CheckedContinuation<Void, Never>?
        var actions: [String] { lock.withLock { calls } }
        var packets: [Data] { lock.withLock { received } }
        var isSharingWaiting: Bool { lock.withLock { sharingPending != nil } }
        var isWaiting: Bool { lock.withLock { pending != nil } }
        override func subscribe() -> DeviceLinkingSubscription { stream }
        override func cancel() async throws {}
        override func continueLinking(displayedRevision: UInt64) async throws {
            lock.withLock { calls.append("continue:\(displayedRevision)") }
            if lock.withLock({ rejected }) { throw MarmotKitError.DeviceLinkingStaleRevision }
        }
        override func continueLinkingAndShareChats(displayedRevision: UInt64) async throws {
            lock.withLock { calls.append("share:\(displayedRevision)") }
            if lock.withLock({ sharingPaused }) {
                await withCheckedContinuation { continuation in lock.withLock { sharingPending = continuation } }
            }
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
        func pauseSharing() { lock.withLock { sharingPaused = true } }
        func finishSharing() {
            let continuation = lock.withLock {
                let result = sharingPending
                sharingPending = nil
                return result
            }
            continuation?.resume()
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

    @MainActor @Suite struct DeviceLinkingEnrollmentActionTests {
        @Test func explicitActionsForwardOnlyToOriginalHandle() async throws {
            let session = EnrollmentSession(noPointer: .init())
            let scope = DeviceLinkingAccountScope(accountRef: "account", session: session)
            defer { scope.invalidate() }
            try await scope.continueLinking(displayedRevision: 7)
            #expect(try await scope.enrollmentPacket(displayedRevision: 8) == Data([1, 2, 3]))
            try await scope.receiveEnrollmentPacket(displayedRevision: 9, packet: Data([4, 5]))
            try await scope.finalizeLinking(displayedRevision: 10)
            #expect(session.actions == ["continue:7", "export:8", "receive:9", "finalize:10"])
            #expect(session.packets == [Data([4, 5])])
        }

        @Test func explicitSharingUsesOriginalRevisionAndRefusesRetiredOwner() async throws {
            let session = EnrollmentSession(noPointer: .init())
            let scope = DeviceLinkingAccountScope(accountRef: "account", session: session)
            try await scope.continueLinkingAndShareChats(displayedRevision: 17)
            #expect(session.actions == ["share:17"])
            session.rejectRevision()
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                try await scope.continueLinkingAndShareChats(displayedRevision: 18)
            }
            scope.invalidate()
            do {
                try await scope.continueLinkingAndShareChats(displayedRevision: 19)
                Issue.record("Retired original sharing action unexpectedly succeeded")
            } catch {}
            #expect(session.actions == ["share:17", "share:18"])
        }

        @Test func originalSdkRevisionErrorRemainsAnError() async throws {
            let session = EnrollmentSession(noPointer: .init())
            session.rejectRevision()
            let scope = DeviceLinkingAccountScope(accountRef: "account", session: session)
            defer { scope.invalidate() }
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                try await scope.continueLinking(displayedRevision: 7)
            }
            #expect(session.actions == ["continue:7"])
        }

        @Test func explicitCancellationRejectsEveryEnrollmentOperation() async throws {
            let session = EnrollmentSession(noPointer: .init())
            let scope = DeviceLinkingAccountScope(accountRef: "account", session: session)
            try await scope.cancel()
            await #expect(throws: CancellationError.self) { try await scope.continueLinking(displayedRevision: 7) }
            await #expect(throws: CancellationError.self) { try await scope.enrollmentPacket(displayedRevision: 7) }
            await #expect(throws: CancellationError.self) {
                try await scope.receiveEnrollmentPacket(displayedRevision: 7, packet: Data([1]))
            }
            await #expect(throws: CancellationError.self) { try await scope.finalizeLinking(displayedRevision: 7) }
            #expect(session.actions.isEmpty)
        }

        @Test func delayedPacketCannotEscapeAccountReplacementAndReturn() async throws {
            let session = EnrollmentSession(noPointer: .init())
            session.pauseExport()
            let store = AccountStore(defaults: IsolatedAccountDefaults.make())
            store.activeAccountRef = "A"
            let scope = try await store.holdDeviceLinkingSession(session, accountRef: "A")
            let export = Task { try? await scope.enrollmentPacket(displayedRevision: 7) }
            for _ in 0..<200 {
                if session.isWaiting { break }
                await Task.yield()
            }
            try #require(session.isWaiting)
            store.activeAccountRef = "B"
            store.activeAccountRef = "A"
            session.finishExport()
            #expect(await export.value == nil)
            #expect(store.deviceLinkingScope == nil)
            await #expect(throws: CancellationError.self) { try await scope.finalizeLinking(displayedRevision: 7) }
            #expect(session.actions == ["export:7"])
            try await store.cancelDeviceLinking()
        }

        @Test func delayedSharingCannotEscapeAccountReplacementAndReturn() async throws {
            let session = EnrollmentSession(noPointer: .init())
            session.pauseSharing()
            let store = AccountStore(defaults: IsolatedAccountDefaults.make())
            store.activeAccountRef = "A"
            let scope = try await store.holdDeviceLinkingSession(session, accountRef: "A")
            let sharing = Task {
                do {
                    try await scope.continueLinkingAndShareChats(displayedRevision: 7)
                    return true
                } catch { return false }
            }
            for _ in 0..<200 {
                if session.isSharingWaiting { break }
                await Task.yield()
            }
            try #require(session.isSharingWaiting)
            store.activeAccountRef = "B"
            store.activeAccountRef = "A"
            session.finishSharing()
            #expect(await sharing.value == false)
            #expect(store.deviceLinkingScope == nil)
            await #expect(throws: CancellationError.self) { try await scope.finalizeLinking(displayedRevision: 7) }
            #expect(session.actions == ["share:7"])
            try await store.cancelDeviceLinking()
        }

        @Test func suspensionRejectsDelayedEnrollmentResult() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EnrollmentScope-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = try MarmotClient(rootPath: directory.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(client: client, accountDefaults: IsolatedAccountDefaults.make())
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "A"
            let session = EnrollmentSession(noPointer: .init())
            session.pauseExport()
            let scope = try await app.accountStore.holdDeviceLinkingSession(session, accountRef: "A")
            let export = Task { try? await scope.enrollmentPacket(displayedRevision: 7) }
            for _ in 0..<200 {
                if session.isWaiting { break }
                await Task.yield()
            }
            try #require(session.isWaiting)
            app.setAppSceneActive(false)
            await app.startRuntimeSuspension().value
            #expect(app.runtimeSuspendedForBackground)
            session.finishExport()
            #expect(await export.value == nil)
            #expect(app.accountStore.deviceLinkingScope == nil)
            await #expect(throws: CancellationError.self) { try await scope.continueLinking(displayedRevision: 7) }
            #expect(session.actions == ["export:7"])
            try await scope.cancel()
        }
    }
#endif
