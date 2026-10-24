import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    private actor HistoryConsentPause {
        private var entered = false
        private var entry: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        func pause() async {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
                entered = true
                entry?.resume()
                entry = nil
            }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { entry = $0 }
        }
        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }
    // SDK originals cross actor boundaries; only this isolated counter state uses a lock.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class HistoryConsentOriginal: HistoryConsentProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var approvals: [UInt64] = []
        private var cancellations = 0
        let failApproval: Bool
        private let pause: HistoryConsentPause?
        private var altered = false
        init(failApproval: Bool = false, pause: HistoryConsentPause? = nil) {
            self.failApproval = failApproval
            self.pause = pause
        }
        func alterReview() { lock.withLock { altered = true } }
        var captured: ([UInt64], Int) { lock.withLock { (approvals, cancellations) } }
        func snapshot() async throws -> HistoryTransferSnapshotFfi {
            if let pause { await pause.pause() }
            return .init(
                revision: 7, importedRecords: 0, complete: false, groupIdHex: "0102",
                sourceDevice: Data(repeating: 1, count: 32), recipientDevice: Data(repeating: 2, count: 32),
                snapshotTimestampCeiling: 100, recordCount: lock.withLock { altered ? 4 : 3 }, encodedBytes: 8192,
                fragmentCount: 2)
        }
        func approve(revision: UInt64) async throws {
            lock.withLock { approvals.append(revision) }
            if failApproval { throw MarmotKitError.HistoryTransferRuntimeUnavailable }
        }
        func cancel() { lock.withLock { cancellations += 1 } }
    }

    @MainActor struct NativeHistoryConsentScopeTests {
        @Test func refreshRetainsExactReviewWithoutImplicitApproval() async throws {
            let original = HistoryConsentOriginal()
            let scope = NativeHistoryConsentScope(original: original)
            let review = try await scope.refresh()
            #expect(review == original.snapshotValue)
            #expect(scope.review == review)
            #expect(original.captured.0.isEmpty)
        }
        @Test func explicitApprovalForwardsDisplayedRevisionToOriginal() async throws {
            let original = HistoryConsentOriginal()
            let scope = NativeHistoryConsentScope(original: original)
            _ = try await scope.refresh()
            try await scope.approve(displayedRevision: 7)
            #expect(original.captured.0 == [7])
        }
        @Test func sdkApprovalErrorIsPreserved() async throws {
            let original = HistoryConsentOriginal(failApproval: true)
            let scope = NativeHistoryConsentScope(original: original)
            _ = try await scope.refresh()
            await #expect(throws: MarmotKitError.HistoryTransferRuntimeUnavailable) {
                try await scope.approve(displayedRevision: 7)
            }
            #expect(original.captured.0 == [7])
        }
        @Test func cancelledOriginalCannotApproveAgain() async throws {
            let original = HistoryConsentOriginal()
            let scope = NativeHistoryConsentScope(original: original)
            scope.cancel()
            await #expect(throws: MarmotKitError.HistoryTransferClosed) {
                try await scope.approve(displayedRevision: 7)
            }
            #expect(!scope.isActive)
            #expect(original.captured.1 == 1)
            #expect(original.captured.0.isEmpty)
        }
        @Test func staleDisplayedRevisionNeverCallsOriginalApprove() async throws {
            let original = HistoryConsentOriginal()
            let scope = NativeHistoryConsentScope(original: original)
            _ = try await scope.refresh()
            await #expect(throws: MarmotKitError.HistoryTransferStaleRevision) {
                try await scope.approve(displayedRevision: 6)
            }
            #expect(original.captured.0.isEmpty)
        }
        @Test func changedAuthenticatedReviewClearsDisplayAndCancelsOriginal() async throws {
            let original = HistoryConsentOriginal()
            let scope = NativeHistoryConsentScope(original: original)
            _ = try await scope.refresh()
            original.alterReview()
            await #expect(throws: MarmotKitError.HistoryTransferNotReady) { _ = try await scope.refresh() }
            #expect(scope.review == nil)
            #expect(!scope.isActive)
            #expect(original.captured.1 == 1)
        }
        @Test func lateSnapshotCannotRestoreCancelledReview() async throws {
            let pause = HistoryConsentPause()
            let original = HistoryConsentOriginal(pause: pause)
            let scope = NativeHistoryConsentScope(original: original)
            let loading = Task { try await scope.refresh() }
            await pause.waitUntilEntered()
            scope.cancel()
            await pause.release()
            await #expect(throws: MarmotKitError.HistoryTransferClosed) { _ = try await loading.value }
            #expect(scope.review == nil)
            #expect(original.captured.1 == 1)
        }
        @Test func actualAccountAtoBtoAFencesIgnoredFactoryUntilExactLateCleanup() async throws {
            try await withApp { app in
                let pause = HistoryConsentPause()
                let original = HistoryConsentOriginal()
                let pending = Task {
                    try await app.adoptHistoryConsentBatch { _, _ in
                        await pause.pause()
                        return [original]
                    }
                }
                await pause.waitUntilEntered()
                app.activeAccountRef = "bob"
                app.activeAccountRef = "alice"
                var invoked = false
                await #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                    _ = try await app.adoptHistoryConsentBatch { _, _ in
                        invoked = true
                        return []
                    }
                }
                #expect(!invoked)
                await pause.release()
                await #expect(throws: MarmotKitError.HistoryTransferClosed) { _ = try await pending.value }
                #expect(original.captured.1 == 1)
                #expect(original.captured.0.isEmpty)
                let fresh = try await app.adoptHistoryConsentBatch { _, _ in [HistoryConsentOriginal()] }
                #expect(fresh.count == 1)
                #expect(fresh.first?.isActive == true)
            }
        }
        @Test func actualSuspensionClosesRuntimeButKeepsNegativeLateFactoryFence() async throws {
            try await withApp { app in
                let pause = HistoryConsentPause()
                let original = HistoryConsentOriginal()
                let oldClient = app.client
                let pending = Task {
                    try await app.adoptHistoryConsentBatch { _, _ in
                        await pause.pause()
                        return [original]
                    }
                }
                await pause.waitUntilEntered()
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                #expect(app.client == nil)
                app.setAppSceneActive(true)
                await app.bootstrap()
                app.activeAccountRef = "alice"
                #expect(app.client !== oldClient)
                var invoked = false
                await #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                    _ = try await app.adoptHistoryConsentBatch { _, _ in
                        invoked = true
                        return []
                    }
                }
                #expect(!invoked)
                await pause.release()
                await #expect(throws: MarmotKitError.HistoryTransferClosed) { _ = try await pending.value }
                #expect(original.captured.1 == 1)
                #expect(original.captured.0.isEmpty)
            }
        }
        @Test(arguments: [0, 1, 2])
        func pendingOriginalFencesDestructiveAccountExit(exit: Int) async throws {
            try await withApp { app in
                app.setPhase(.ready)
                let oldClient = try #require(app.client)
                let pause = HistoryConsentPause()
                let original = HistoryConsentOriginal()
                let pending = Task {
                    try await app.adoptHistoryConsentBatch { _, _ in
                        await pause.pause()
                        return [original]
                    }
                }
                await pause.waitUntilEntered()
                var reachedCoreExit = false
                app.afterAccountExitClientCapturedForTesting = { reachedCoreExit = true }
                if exit == 0 {
                    #expect(await app.signOut() == false)
                } else if exit == 1 {
                    #expect(await app.signOutAndWipeActiveAccount() == false)
                } else {
                    await #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                        try await app.runtimeLifecycle.closeForAppErasure()
                    }
                }
                #expect(!reachedCoreExit)
                #expect(app.client === oldClient)
                #expect(app.activeAccountRef == "alice")
                #expect(!app.isAccountExitInProgress)
                await pause.release()
                await #expect(throws: MarmotKitError.HistoryTransferClosed) { _ = try await pending.value }
                #expect(original.captured.1 == 1)
                try await app.accountStore.prepareHistoryConsentAcquisition()
                #expect(try oldClient.marmot.listAccounts().isEmpty)
            }
        }
        @Test func fullBoundedBatchRetainsEveryOriginalWithoutApprovalOrSelection() async throws {
            try await withApp { app in
                let originals = (0..<128).map { _ in HistoryConsentOriginal() }
                let scopes = try await app.adoptHistoryConsentBatch { _, _ in originals }
                #expect(scopes.count == 128)
                #expect(Set(scopes.map(\.id)).count == 128)
                #expect(originals.allSatisfy { $0.captured.0.isEmpty && $0.captured.1 == 0 })
                app.activeAccountRef = "bob"
                #expect(scopes.allSatisfy { !$0.isActive })
                #expect(originals.allSatisfy { $0.captured.1 == 1 })
            }
        }
        @Test func sdkMissingAccountRemainsTypedAndCreatesNoAccount() async throws {
            try await withApp { app in
                let client = try #require(app.client)
                await #expect(throws: MarmotKitError.HistoryTransferRuntimeUnavailable) {
                    _ = try await client.pendingHistoryRequests(accountRef: "missing")
                }
                #expect(try client.marmot.listAccounts().isEmpty)
            }
        }
        private func withApp(_ body: (AppState) async throws -> Void) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryCustody-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = try MarmotClient(rootPath: directory.path, relayUrls: ["wss://relay.example.invalid"])
            let defaults = try #require(UserDefaults(suiteName: "HistoryCustody-\(UUID())"))
            let app = AppState.test(client: client, accountDefaults: defaults)
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "alice"
            do { try await body(app) } catch {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                throw error
            }
            app.setAppSceneActive(false)
            await app.startRuntimeSuspension().value
        }
        @Test func actualAccountFactoryRetainsBatchAndReusesOriginalRows() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryCustody-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = try MarmotClient(rootPath: directory.path, relayUrls: ["wss://relay.example.invalid"])
            let defaults = try #require(UserDefaults(suiteName: "HistoryCustody-\(UUID())"))
            let app = AppState.test(client: client, accountDefaults: defaults)
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "alice"
            let original = HistoryConsentOriginal()
            var calls = 0
            do {
                let first = try await app.adoptHistoryConsentBatch { runtime, account in
                    #expect(runtime === client)
                    #expect(account == "alice")
                    calls += 1
                    return [original]
                }
                let second = try await app.adoptHistoryConsentBatch { _, _ in
                    calls += 1
                    return []
                }
                #expect(first.count == 1)
                #expect(first.first === second.first)
                #expect(calls == 1)
                app.activeAccountRef = "bob"
                #expect(first.first?.isActive == false)
                #expect(original.captured.1 == 1)
            } catch {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                throw error
            }
            app.setAppSceneActive(false)
            await app.startRuntimeSuspension().value
        }
    }

    private extension HistoryConsentOriginal {
        var snapshotValue: HistoryTransferSnapshotFfi {
            .init(
                revision: 7, importedRecords: 0, complete: false, groupIdHex: "0102",
                sourceDevice: Data(repeating: 1, count: 32), recipientDevice: Data(repeating: 2, count: 32),
                snapshotTimestampCeiling: 100, recordCount: 3, encodedBytes: 8192, fragmentCount: 2)
        }
    }
#endif
