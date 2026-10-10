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
