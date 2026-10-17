import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    private actor SelectedChatPause {
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        func pause() async {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
                entered = true
                enteredWaiter?.resume()
                enteredWaiter = nil
            }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }
        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }
    // These original-handle controls use a lock because SDK protocols cross actor boundaries.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class CopyOriginal: SelectedChatCopyProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var revisions: [UInt64] = []
        private var packets: [Data] = []
        private var cancellations = 0
        private let pause: SelectedChatPause?
        private let failFirstCancel: Bool
        private let staleAction: Bool
        init(pause: SelectedChatPause? = nil, failFirstCancel: Bool = false, staleAction: Bool = false) {
            self.pause = pause
            self.failFirstCancel = failFirstCancel
            self.staleAction = staleAction
        }
        var captured: ([UInt64], [Data], Int) { lock.withLock { (revisions, packets, cancellations) } }
        func snapshot() async throws -> SelectedChatCopySnapshotFfi {
            .init(
                revision: 19, phase: .awaitingSiblingConsent, siblingCount: 2, consentingSiblingCount: 0,
                offeredSiblingCount: 0)
        }
        func requestPacket(revision: UInt64) async throws -> Data {
            lock.withLock { revisions.append(revision) }
            if staleAction { throw MarmotKitError.SelectedChatCopyStaleRevision }
            if let pause { await pause.pause() }
            return Data([7, 8, 9])
        }
        func receiveConsentPacket(revision: UInt64, packet: Data) async throws {
            lock.withLock {
                revisions.append(revision)
                packets.append(packet)
            }
        }
        func receiveOfferPacket(revision: UInt64, packet: Data) async throws {
            lock.withLock {
                revisions.append(revision)
                packets.append(packet)
            }
        }
        func continueCopy(revision: UInt64) async throws { lock.withLock { revisions.append(revision) } }
        func cancel() async throws {
            let attempt = lock.withLock {
                cancellations += 1
                return cancellations
            }
            if failFirstCancel && attempt == 1 { throw MarmotKitError.SelectedChatCopyBusy }
        }
    }
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class ConsentOriginal: SelectedChatConsentProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var revisions: [UInt64] = []
        private var approvals = 0
        private var cancellations = 0
        private let pause: SelectedChatPause?
        private let failFirstCancel: Bool
        private let staleAction: Bool
        init(pause: SelectedChatPause? = nil, failFirstCancel: Bool = false, staleAction: Bool = false) {
            self.pause = pause
            self.failFirstCancel = failFirstCancel
            self.staleAction = staleAction
        }
        var captured: ([UInt64], Int, Int) { lock.withLock { (revisions, approvals, cancellations) } }
        func snapshot() async throws -> SelectedChatConsentSnapshotFfi {
            .init(revision: 23, phase: .awaitingApproval, chatSelector: Data(repeating: 4, count: 32))
        }
        func approve(revision: UInt64) async throws {
            lock.withLock {
                revisions.append(revision)
                approvals += 1
            }
            if staleAction { throw MarmotKitError.SelectedChatCopyStaleRevision }
        }
        func responsePacket(revision: UInt64) async throws -> Data {
            lock.withLock { revisions.append(revision) }
            if let pause { await pause.pause() }
            return Data([11, 12])
        }
        func offerPacket(revision: UInt64) async throws -> Data {
            lock.withLock { revisions.append(revision) }
            return Data([13, 14])
        }
        func cancel() async throws {
            let attempt = lock.withLock {
                cancellations += 1
                return cancellations
            }
            if failFirstCancel && attempt == 1 { throw MarmotKitError.SelectedChatCopyBusy }
        }
    }
    @MainActor @Suite struct SelectedChatScopeTests {
        @Test func requestForwardsExactOriginalRevisionAndOpaquePackets() async throws {
            let original = CopyOriginal()
            let held = SelectedChatCopyScope(accountRef: "isolated", original: original)
            #expect(try await held.snapshot().revision == 19)
            #expect(try await held.requestPacket(displayedRevision: 19) == Data([7, 8, 9]))
            try await held.receiveConsentPacket(displayedRevision: 19, packet: Data([1, 2]))
            try await held.receiveOfferPacket(displayedRevision: 19, packet: Data([3, 4]))
            try await held.continueCopy(displayedRevision: 19)
            #expect(original.captured.0 == [19, 19, 19, 19])
            #expect(original.captured.1 == [Data([1, 2]), Data([3, 4])])
            try await held.cancel()
            #expect(original.captured.2 == 1)
        }
        @Test func recipientReadDoesNotApproveAndExplicitActionUsesOriginalRevision() async throws {
            let original = ConsentOriginal()
            let held = SelectedChatConsentScope(accountRef: "isolated", original: original)
            let review = try await held.snapshot()
            #expect(review.chatSelector == Data(repeating: 4, count: 32))
            #expect(original.captured.1 == 0)
            try await held.approve(displayedRevision: review.revision)
            #expect(try await held.responsePacket(displayedRevision: 23) == Data([11, 12]))
            #expect(try await held.offerPacket(displayedRevision: 23) == Data([13, 14]))
            #expect(original.captured.0 == [23, 23, 23])
            #expect(original.captured.1 == 1)
            try await held.cancel()
            #expect(original.captured.2 == 1)
        }
        @Test func invalidatedRequestBlocksAllNewActions() async throws {
            let original = CopyOriginal()
            let scope = SelectedChatCopyScope(accountRef: "isolated", original: original)
            scope.invalidate()
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await scope.snapshot() }
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                _ = try await scope.requestPacket(displayedRevision: 19)
            }
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                try await scope.receiveConsentPacket(displayedRevision: 19, packet: Data([1]))
            }
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                try await scope.receiveOfferPacket(displayedRevision: 19, packet: Data([2]))
            }
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                try await scope.continueCopy(displayedRevision: 19)
            }
            #expect(original.captured.0.isEmpty)
            #expect(original.captured.1.isEmpty)
        }
        @Test func invalidatedConsentBlocksAllNewActions() async throws {
            let original = ConsentOriginal()
            let scope = SelectedChatConsentScope(accountRef: "isolated", original: original)
            scope.invalidate()
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await scope.snapshot() }
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                try await scope.approve(displayedRevision: 23)
            }
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                _ = try await scope.responsePacket(displayedRevision: 23)
            }
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                _ = try await scope.offerPacket(displayedRevision: 23)
            }
            #expect(original.captured.0.isEmpty)
            #expect(original.captured.1 == 0)
        }
        @Test func delayedRequestPacketCannotEscapeRetirement() async throws {
            let pause = SelectedChatPause()
            let original = CopyOriginal(pause: pause)
            let scope = SelectedChatCopyScope(accountRef: "isolated", original: original)
            let action = Task { try await scope.requestPacket(displayedRevision: 19) }
            await pause.waitUntilEntered()
            scope.invalidate()
            await pause.release()
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await action.value }
            #expect(original.captured.0 == [19])
        }
        @Test func delayedConsentPacketCannotEscapeCancellation() async throws {
            let pause = SelectedChatPause()
            let original = ConsentOriginal(pause: pause)
            let scope = SelectedChatConsentScope(accountRef: "isolated", original: original)
            let action = Task { try await scope.responsePacket(displayedRevision: 23) }
            await pause.waitUntilEntered()
            try await scope.cancel()
            await pause.release()
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await action.value }
            #expect(original.captured.0 == [23])
            #expect(original.captured.2 == 1)
        }
        @Test func requestFailedCleanupRetriesSameOriginalOnce() async throws {
            let original = CopyOriginal(failFirstCancel: true)
            let scope = SelectedChatCopyScope(accountRef: "isolated", original: original)
            await #expect(throws: MarmotKitError.SelectedChatCopyBusy) { try await scope.cancel() }
            #expect(!scope.isActive)
            #expect(scope.cleanupError != nil)
            #expect(original.captured.2 == 1)
            try await scope.cancel()
            try await scope.cancel()
            #expect(scope.cleanupError == nil)
            #expect(original.captured.2 == 2)
        }
        @Test func consentFailedCleanupRetriesSameOriginalOnce() async throws {
            let original = ConsentOriginal(failFirstCancel: true)
            let scope = SelectedChatConsentScope(accountRef: "isolated", original: original)
            await #expect(throws: MarmotKitError.SelectedChatCopyBusy) { try await scope.cancel() }
            #expect(!scope.isActive)
            #expect(scope.cleanupError != nil)
            #expect(original.captured.2 == 1)
            try await scope.cancel()
            try await scope.cancel()
            #expect(scope.cleanupError == nil)
            #expect(original.captured.2 == 2)
        }
        @Test func staleDisplayedRevisionPassesThroughWithoutImplicitRefreshOrApproval() async throws {
            let request = CopyOriginal(staleAction: true)
            let copy = SelectedChatCopyScope(accountRef: "isolated", original: request)
            await #expect(throws: MarmotKitError.SelectedChatCopyStaleRevision) {
                _ = try await copy.requestPacket(displayedRevision: 17)
            }
            #expect(request.captured.0 == [17])
            let recipient = ConsentOriginal(staleAction: true)
            let consent = SelectedChatConsentScope(accountRef: "isolated", original: recipient)
            await #expect(throws: MarmotKitError.SelectedChatCopyStaleRevision) {
                try await consent.approve(displayedRevision: 21)
            }
            #expect(recipient.captured.0 == [21])
            #expect(recipient.captured.1 == 1)
        }
        private func withApp(_ operation: (AppState) async throws -> Void) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SelectedChatOwner-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try MarmotClient(rootPath: root.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(
                client: client, accountDefaults: IsolatedAccountDefaults.make(),
                runtimeClientFactory: { _, _, cursorPersistence, telemetryConfig in
                    try MarmotClient(
                        rootPath: root.path, relayUrls: ["wss://relay.example.invalid"],
                        cursorPersistence: cursorPersistence, telemetryConfig: telemetryConfig)
                })
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
        @Test func actualAccountReplacementRetiresOriginalCopyAcrossReturn() async throws {
            try await withApp { app in
                let original = CopyOriginal()
                let held = try await app.adoptSelectedChatCopyFactory { actual, ref in
                    #expect(actual === app.client)
                    #expect(ref == "A")
                    return original
                }
                #expect(held.accountRef == "A")
                #expect(try await held.requestPacket(displayedRevision: 19) == Data([7, 8, 9]))
                app.activeAccountRef = "B"
                app.activeAccountRef = "A"
                #expect(!held.isActive)
                try await app.accountStore.retrySelectedChatCleanup()
                #expect(original.captured.2 == 1)
                await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await held.snapshot() }
            }
        }
        @Test func actualRuntimeSuspensionRetiresOriginalConsentBeforeRestart() async throws {
            try await withApp { app in
                let original = ConsentOriginal()
                let oldClient = app.client
                let held = try await app.adoptSelectedChatConsentFactory { actual, ref in
                    #expect(actual === oldClient)
                    #expect(ref == "A")
                    return original
                }
                app.setAppSceneActive(false)
                #expect(!held.isActive)
                await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                    try await held.approve(displayedRevision: 23)
                }
                #expect(original.captured.1 == 0)
                await app.startRuntimeSuspension().value
                #expect(!held.isActive)
                #expect(original.captured.2 == 1)
                #expect(original.captured.1 == 0)
                #expect(app.client == nil)
                app.setAppSceneActive(true)
                await app.bootstrap()
                app.activeAccountRef = "A"
                #expect(app.client !== oldClient)
                await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                    try await held.approve(displayedRevision: 23)
                }
            }
        }
        @Test func lateCopyFactoryCannotAttachAcrossActualAccountReturn() async throws {
            try await withApp { app in
                let pause = SelectedChatPause()
                let original = CopyOriginal()
                let pending = Task {
                    try await app.adoptSelectedChatCopyFactory { _, _ in
                        await pause.pause()
                        return original
                    }
                }
                await pause.waitUntilEntered()
                app.activeAccountRef = "B"
                app.activeAccountRef = "A"
                var invoked = false
                await #expect(throws: MarmotKitError.SelectedChatCopyBusy) {
                    _ = try await app.adoptSelectedChatCopyFactory { _, _ in
                        invoked = true
                        return CopyOriginal()
                    }
                }
                #expect(!invoked)
                await pause.release()
                await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await pending.value }
                #expect(original.captured.2 == 1)
                try await app.accountStore.retrySelectedChatCleanup()
                let fresh = CopyOriginal()
                let held = try await app.adoptSelectedChatCopyFactory { _, _ in fresh }
                #expect(held.isActive)
                try await held.cancel()
            }
        }
        @Test func ignoredPendingFactoryDoesNotBlockRuntimeCloseAndNeverAdoptsAfterRestart() async throws {
            try await withApp { app in
                let pause = SelectedChatPause()
                let original = ConsentOriginal()
                let oldClient = app.client
                let pending = Task {
                    try await app.adoptSelectedChatConsentFactory { _, _ in
                        await pause.pause()
                        return original
                    }
                }
                await pause.waitUntilEntered()
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                #expect(app.client == nil)
                app.setAppSceneActive(true)
                await app.bootstrap()
                app.activeAccountRef = "A"
                #expect(app.client !== oldClient)
                var invoked = false
                await #expect(throws: MarmotKitError.SelectedChatCopyBusy) {
                    _ = try await app.adoptSelectedChatConsentFactory { _, _ in
                        invoked = true
                        return ConsentOriginal()
                    }
                }
                #expect(!invoked)
                await pause.release()
                await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await pending.value }
                #expect(original.captured.2 == 1)
                #expect(original.captured.1 == 0)
                try await app.accountStore.retrySelectedChatCleanup()
            }
        }
        @Test func cancelledCallerLateFailedCleanupFinishesBeforeNextActualFactory() async throws {
            try await withApp { app in
                let pause = SelectedChatPause()
                let original = CopyOriginal(failFirstCancel: true)
                let pending = Task {
                    try await app.adoptSelectedChatCopyFactory { _, _ in
                        await pause.pause()
                        return original
                    }
                }
                await pause.waitUntilEntered()
                pending.cancel()
                await pause.release()
                await #expect(throws: MarmotKitError.SelectedChatCopyBusy) { _ = try await pending.value }
                #expect(original.captured.2 == 1)
                let fresh = CopyOriginal()
                let held = try await app.adoptSelectedChatCopyFactory { _, _ in
                    #expect(original.captured.2 == 2)
                    return fresh
                }
                #expect(held.isActive)
                try await held.cancel()
                #expect(fresh.captured.2 == 1)
            }
        }
        @Test func failedCleanupAttemptsBothOriginalChatOwnersIndependently() async throws {
            try await withApp { app in
                let copy = CopyOriginal(failFirstCancel: true)
                let consent = ConsentOriginal(failFirstCancel: true)
                let heldCopy = try await app.adoptSelectedChatCopyFactory { _, _ in copy }
                let heldConsent = try await app.adoptSelectedChatConsentFactory { _, _ in consent }
                app.activeAccountRef = "B"
                #expect(!heldCopy.isActive)
                #expect(!heldConsent.isActive)
                await #expect(throws: MarmotKitError.SelectedChatCopyBusy) {
                    try await app.accountStore.retrySelectedChatCleanup()
                }
                #expect(copy.captured.2 == 1)
                #expect(consent.captured.2 == 1)
                try await app.accountStore.retrySelectedChatCleanup()
                #expect(copy.captured.2 == 2)
                #expect(consent.captured.2 == 2)
            }
        }
        @Test(arguments: [0, 1, 2])
        func ignoredFactoryFencesActualSignOutWipeAndExplicitCoreClose(exit: Int) async throws {
            try await withApp { app in
                app.setPhase(.ready)
                let originalClient = try #require(app.client)
                let pause = SelectedChatPause()
                let original = CopyOriginal()
                let pending = Task {
                    try await app.adoptSelectedChatCopyFactory { _, _ in
                        await pause.pause()
                        return original
                    }
                }
                await pause.waitUntilEntered()
                var reachedCoreAccountExit = false
                app.afterAccountExitClientCapturedForTesting = { reachedCoreAccountExit = true }
                if exit == 0 {
                    #expect(await app.signOut() == false)
                } else if exit == 1 {
                    #expect(await app.signOutAndWipeActiveAccount() == false)
                } else {
                    await #expect(throws: MarmotKitError.SelectedChatCopyBusy) {
                        try await app.runtimeLifecycle.closeForAppErasure()
                    }
                }
                #expect(!reachedCoreAccountExit)
                #expect(!app.isAccountExitInProgress)
                #expect(app.client === originalClient)
                #expect(app.activeAccountRef == "A")
                #expect(try originalClient.marmot.listAccounts().isEmpty)
                await pause.release()
                await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await pending.value }
                #expect(original.captured.2 == 1)
                try await app.accountStore.retrySelectedChatCleanup()
                #expect(try originalClient.marmot.listAccounts().isEmpty)
            }
        }
        private func withClient(_ body: (MarmotClient) async throws -> Void) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "wn-selected-client-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try MarmotClient(rootPath: root.path, relayUrls: ["wss://relay.example.invalid"])
            do {
                try await body(client)
                #expect(try client.marmot.listAccounts().isEmpty)
                try await client.marmot.shutdownAndClose()
            } catch {
                try? await client.marmot.shutdownAndClose()
                throw error
            }
        }
        @Test func requestFactoryPreservesMissingAccountWithoutCreatingIdentity() async throws {
            try await withClient { client in
                await #expect(throws: MarmotKitError.SelectedChatCopyRuntimeUnavailable) {
                    _ = try await client.beginSelectedChatCopy(
                        accountRef: "missing", groupIdHex: "11", linkedRosterSelector: Data([2]))
                }
            }
        }
        @Test func recipientFactoryPreservesMissingAccountWithoutCreatingIdentity() async throws {
            try await withClient { client in
                await #expect(throws: MarmotKitError.SelectedChatCopyRuntimeUnavailable) {
                    _ = try await client.receiveSelectedChatCopyRequest(accountRef: "missing", packet: Data([1]))
                }
            }
        }
    }
#endif
