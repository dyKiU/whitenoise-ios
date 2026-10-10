import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    private actor HistoryReviewPause {
        private var entered = false
        private var entry: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        func pause() async {
            await withCheckedContinuation { value in
                releaseWaiter = value
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
    // Only isolated original-call counters cross actor boundaries.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class ReviewConsentOriginal: HistoryConsentProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var approvals: [UInt64] = []
        private var cancellations = 0
        private var snapshotPause: HistoryReviewPause?
        private var malformed = false
        private let failApproval: Bool
        init(failApproval: Bool = false) { self.failApproval = failApproval }
        func pauseNextSnapshot(_ gate: HistoryReviewPause) { lock.withLock { snapshotPause = gate } }
        func corruptReview() { lock.withLock { malformed = true } }
        var captured: ([UInt64], Int) { lock.withLock { (approvals, cancellations) } }
        func snapshot() async throws -> HistoryTransferSnapshotFfi {
            let gate = lock.withLock {
                let value = snapshotPause
                snapshotPause = nil
                return value
            }
            if let gate { await gate.pause() }
            return .init(
                revision: 19, importedRecords: 0, complete: false, groupIdHex: "0102",
                sourceDevice: Data(repeating: 1, count: lock.withLock { malformed ? 31 : 32 }),
                recipientDevice: Data(repeating: 2, count: 32),
                snapshotTimestampCeiling: 100, recordCount: 3, encodedBytes: 8192, fragmentCount: 2)
        }
        func approve(revision: UInt64) async throws {
            lock.withLock { approvals.append(revision) }
            if failApproval { throw MarmotKitError.HistoryTransferRuntimeUnavailable }
        }
        func cancel() { lock.withLock { cancellations += 1 } }
    }
    @MainActor struct HistoryConsentReviewModelTests {
        @Test func explicitReviewAndDisplayedRevisionUseHeldOriginalWithoutAutomaticApproval() async throws {
            let original = ReviewConsentOriginal()
            let scope = NativeHistoryConsentScope(original: original)
            let model = HistoryConsentReviewModel(loadOriginals: { [scope] }, isCurrent: { true })
            try await model.loadPending()
            #expect(model.scopes.first === scope)
            #expect(model.review == nil)
            try await model.select(id: scope.id)
            let review = try #require(model.review)
            #expect(review.sourceDevice == Data(repeating: 1, count: 32))
            #expect(review.recipientDevice == Data(repeating: 2, count: 32))
            #expect(original.captured.0.isEmpty)
            try await model.approve(displayedRevision: review.revision)
            #expect(original.captured.0 == [19])
        }
        @Test func cancelledRowClearsReviewAndCannotApproveAgain() async throws {
            let original = ReviewConsentOriginal()
            let scope = NativeHistoryConsentScope(original: original)
            let model = HistoryConsentReviewModel(loadOriginals: { [scope] }, isCurrent: { true })
            try await model.loadPending()
            try await model.select(id: scope.id)
            model.cancelSelected()
            #expect(model.review == nil)
            #expect(model.selected == nil)
            #expect(original.captured.1 == 1)
            await #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                try await model.approve(displayedRevision: 19)
            }
            #expect(original.captured.0.isEmpty)
        }
        @Test func staleDisplayedRevisionAndForeignRowCannotApproveOriginal() async throws {
            let original = ReviewConsentOriginal()
            let scope = NativeHistoryConsentScope(original: original)
            let model = HistoryConsentReviewModel(loadOriginals: { [scope] }, isCurrent: { true })
            try await model.loadPending()
            try await model.select(id: scope.id)
            await #expect(throws: MarmotKitError.HistoryTransferStaleRevision) {
                try await model.approve(displayedRevision: 18)
            }
            #expect(original.captured.0.isEmpty)
            await #expect(throws: MarmotKitError.HistoryTransferNotReady) { try await model.select(id: UUID()) }
            #expect(model.review == nil)
            #expect(model.selected == nil)
        }
        @Test func sdkFailureClearsPriorReviewButRetainsExactCancelAction() async throws {
            let original = ReviewConsentOriginal(failApproval: true)
            let scope = NativeHistoryConsentScope(original: original)
            let model = HistoryConsentReviewModel(loadOriginals: { [scope] }, isCurrent: { true })
            try await model.loadPending()
            try await model.select(id: scope.id)
            await #expect(throws: MarmotKitError.HistoryTransferRuntimeUnavailable) {
                try await model.approve(displayedRevision: 19)
            }
            #expect(model.review == nil)
            #expect(model.selected === scope)
            #expect(model.failed)
            model.cancelSelected()
            #expect(original.captured.1 == 1)
        }
        @Test func malformedRowCannotHideOtherHeldOriginalsOrAutoApproveThem() async throws {
            let malformed = ReviewConsentOriginal()
            malformed.corruptReview()
            let valid = ReviewConsentOriginal()
            let bad = NativeHistoryConsentScope(original: malformed)
            let good = NativeHistoryConsentScope(original: valid)
            let model = HistoryConsentReviewModel(loadOriginals: { [bad, good] }, isCurrent: { true })
            try await model.loadPending()
            #expect(model.scopes.count == 2)
            #expect(model.failed)
            #expect(bad.review == nil)
            #expect(malformed.captured.1 == 1)
            #expect(valid.captured.0.isEmpty)
            try await model.select(id: good.id)
            try await model.approve(displayedRevision: 19)
            #expect(valid.captured.0 == [19])
        }
        @Test func cancelledDelayedSelectionCannotRestoreOldReview() async throws {
            let gate = HistoryReviewPause()
            let original = ReviewConsentOriginal()
            let scope = NativeHistoryConsentScope(original: original)
            let model = HistoryConsentReviewModel(loadOriginals: { [scope] }, isCurrent: { true })
            try await model.loadPending()
            original.pauseNextSnapshot(gate)
            let selecting = Task { try await model.select(id: scope.id) }
            await gate.waitUntilEntered()
            model.cancelSelected()
            await gate.release()
            await #expect(throws: MarmotKitError.HistoryTransferClosed) { try await selecting.value }
            #expect(model.review == nil)
            #expect(model.selected == nil)
            #expect(original.captured.0.isEmpty)
            #expect(original.captured.1 == 1)
        }
        @Test func actualAccountReplacementRetiresExactModelAndClearsOldDisplay() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryReview-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try MarmotClient(rootPath: root.path, relayUrls: ["wss://relay.example.invalid"])
            let defaults = try #require(UserDefaults(suiteName: "HistoryReview-\(UUID())"))
            let app = AppState.test(client: client, accountDefaults: defaults)
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "alice"
            do {
                let scope = NativeHistoryConsentScope(original: ReviewConsentOriginal())
                let model = try app.makeHistoryConsentReviewModel(readPending: { [scope] })
                try await model.loadPending()
                try await model.select(id: scope.id)
                app.activeAccountRef = "bob"
                app.activeAccountRef = "alice"
                #expect(!model.isActive)
                #expect(model.review == nil)
                #expect(model.scopes.isEmpty)
                await #expect(throws: MarmotKitError.HistoryTransferClosed) { try await model.loadPending() }
            } catch {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                throw error
            }
            app.setAppSceneActive(false)
            await app.startRuntimeSuspension().value
        }
    }
#endif
