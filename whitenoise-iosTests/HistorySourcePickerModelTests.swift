import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    private actor HistorySourcePause {
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
    // Only this isolated generated-protocol test double uses lock-protected mutable state.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class HistorySourceOriginal: HistoryTransferProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var revisions: [UInt64] = []
        private var cancellations = 0
        private var value = HistoryTransferSnapshotFfi(
            revision: 7, importedRecords: 0, complete: false, groupIdHex: "ab",
            sourceDevice: Data(repeating: 1, count: 32), recipientDevice: Data(repeating: 2, count: 32),
            snapshotTimestampCeiling: 50, recordCount: 1, encodedBytes: 9000, fragmentCount: 1)
        let failContinue: Bool
        let pause: HistorySourcePause?
        init(failContinue: Bool = false, pause: HistorySourcePause? = nil) {
            self.failContinue = failContinue
            self.pause = pause
        }
        var captured: ([UInt64], Int) { lock.withLock { (revisions, cancellations) } }
        func cancel() { lock.withLock { cancellations += 1 } }
        func snapshot() async throws -> HistoryTransferSnapshotFfi {
            if let pause { await pause.pause() }
            return lock.withLock { value }
        }
        func continueTransfer(revision: UInt64) async throws {
            lock.withLock { revisions.append(revision) }
            if failContinue { throw MarmotKitError.HistoryTransferStaleRevision }
            lock.withLock { value.revision += 1 }
        }
        func changeRecipient() { lock.withLock { value.recipientDevice = Data(repeating: 3, count: 32) } }
    }

    @Suite @MainActor
    struct HistorySourcePickerModelTests {
        private let device = Data(repeating: 2, count: 32)
        private var choice: HistoryTransferRecipientFfi { .init(leafIndex: 4, device: device) }
        private func model(_ original: HistorySourceOriginal) -> HistorySourcePickerModel {
            HistorySourcePickerModel(
                groupIdHex: "ab", readRecipients: { [choice] in [choice] },
                beginOriginal: { [device] selected in
                    #expect(selected == device)
                    return original
                }, isCurrent: { true })
        }
        @Test func selectionRequiresSuccessfulCurrentReadAndNeverFallsBackFromFailure() async throws {
            var begins = 0
            let model = HistorySourcePickerModel(
                groupIdHex: "ab", readRecipients: { throw MarmotKitError.HistoryTransferRuntimeUnavailable },
                beginOriginal: { _ in
                    begins += 1
                    return HistorySourceOriginal()
                }, isCurrent: { true })
            #expect(throws: MarmotKitError.HistoryTransferNotReady) { try model.select(device: device) }
            await #expect(throws: MarmotKitError.HistoryTransferRuntimeUnavailable) { try await model.loadRecipients() }
            await #expect(throws: MarmotKitError.HistoryTransferNotReady) { try await model.begin() }
            #expect(model.recipients.isEmpty)
            #expect(begins == 0)
        }
        @Test func exactChoiceFreshOriginalAndDisplayedRevisionRemainSeparate() async throws {
            let original = HistorySourceOriginal()
            let model = model(original)
            try await model.loadRecipients()
            #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                try model.select(device: Data(repeating: 9, count: 32))
            }
            try model.select(device: device)
            try await model.begin()
            #expect(model.review?.revision == 7)
            await #expect(throws: MarmotKitError.HistoryTransferStaleRevision) {
                try await model.continueTransfer(displayedRevision: 6)
            }
            #expect(original.captured.0.isEmpty)
            try await model.continueTransfer(displayedRevision: 7)
            #expect(original.captured.0 == [7])
            #expect(model.review?.revision == 8)
            model.cancel()
            #expect(original.captured.1 == 1)
            #expect(model.review == nil && !model.isActive)
        }
        @Test func nativeContinueErrorClearsDisplayedReviewWithoutRecreatingOriginal() async throws {
            let original = HistorySourceOriginal(failContinue: true)
            let model = model(original)
            try await model.loadRecipients()
            try model.select(device: device)
            try await model.begin()
            await #expect(throws: MarmotKitError.HistoryTransferStaleRevision) {
                try await model.continueTransfer(displayedRevision: 7)
            }
            #expect(model.review == nil)
            #expect(original.captured.0 == [7])
            model.cancel()
            #expect(original.captured.1 == 1)
        }
        @Test func changedImmutableReviewCancelsExactOriginalAndClearsDisplay() async throws {
            let original = HistorySourceOriginal()
            let model = model(original)
            try await model.loadRecipients()
            try model.select(device: device)
            try await model.begin()
            original.changeRecipient()
            await #expect(throws: MarmotKitError.HistoryTransferNotReady) { try await model.refresh() }
            #expect(!model.isActive && model.review == nil)
            #expect(original.captured.1 == 1)
        }
        @Test func lateOriginalSnapshotCannotRepopulateExplicitlyCancelledDisplay() async throws {
            let pause = HistorySourcePause()
            let original = HistorySourceOriginal(pause: pause)
            let model = model(original)
            try await model.loadRecipients()
            try model.select(device: device)
            let begin = Task { try await model.begin() }
            await pause.waitUntilEntered()
            model.cancel()
            await pause.release()
            await #expect(throws: MarmotKitError.HistoryTransferClosed) { try await begin.value }
            #expect(model.review == nil && model.recipients.isEmpty && !model.isActive)
            #expect(original.captured.1 == 1 && original.captured.0.isEmpty)
            model.cancel()
            #expect(original.captured.1 == 1)
        }
        @Test func duplicateOrMalformedObservedChoicesNeverReachFreshFactory() async throws {
            let values: [[HistoryTransferRecipientFfi]] = [
                [choice, choice], [.init(leafIndex: 4, device: Data([2]))],
                [choice, .init(leafIndex: 4, device: Data(repeating: 3, count: 32))],
            ]
            for choices in values {
                var begins = 0
                let model = HistorySourcePickerModel(
                    groupIdHex: "ab", readRecipients: { choices },
                    beginOriginal: { _ in
                        begins += 1
                        return HistorySourceOriginal()
                    }, isCurrent: { true })
                await #expect(throws: MarmotKitError.HistoryTransferNotReady) { try await model.loadRecipients() }
                #expect(model.recipients.isEmpty && begins == 0)
            }
        }
        @Test func observedChoiceNeverBypassesActualSDKFreshFactoryRefusal() async throws {
            try await withApp { app in
                let model = try await app.makeHistorySourcePickerModel(
                    groupIdHex: String(repeating: "ab", count: 16), readRecipients: { [choice] in [choice] })
                try await model.loadRecipients()
                try model.select(device: device)
                await #expect(throws: MarmotKitError.HistoryTransferRuntimeUnavailable) { try await model.begin() }
                #expect(model.review == nil && model.failed)
                let client = try #require(app.client)
                let accounts = try client.marmot.listAccounts()
                #expect(accounts.isEmpty)
            }
        }
        @Test func actualAccountReplacementRejectsLateQueryEvenForSameAccountAgain() async throws {
            try await withApp { app in
                let pause = HistorySourcePause()
                let model = try await app.makeHistorySourcePickerModel(
                    groupIdHex: "ab",
                    readRecipients: { [choice] in
                        await pause.pause()
                        return [choice]
                    })
                let loading = Task { try await model.loadRecipients() }
                await pause.waitUntilEntered()
                app.activeAccountRef = "bob"
                app.activeAccountRef = "alice"
                await pause.release()
                await #expect(throws: MarmotKitError.HistoryTransferClosed) { try await loading.value }
                #expect(model.recipients.isEmpty && !model.isActive)
            }
        }
        @Test func ignoredFactoryCancellationBlocksBothOwnersUntilLateOriginalRetired() async throws {
            try await withApp { app in
                let pause = HistorySourcePause()
                let original = HistorySourceOriginal()
                let model = try await app.makeHistorySourcePickerModel(
                    groupIdHex: "ab", readRecipients: { [choice] in [choice] },
                    beginOriginal: { _ in
                        await pause.pause()
                        return original
                    })
                try await model.loadRecipients()
                try model.select(device: device)
                let begin = Task { try await model.begin() }
                await pause.waitUntilEntered()
                app.activeAccountRef = "bob"
                app.activeAccountRef = "alice"
                var recipientFactoryCalled = false
                await #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                    _ = try await app.adoptHistoryConsentBatch { _, _ in
                        recipientFactoryCalled = true
                        return []
                    }
                }
                await #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                    _ = try await app.makeHistorySourcePickerModel(groupIdHex: "cd")
                }
                #expect(!recipientFactoryCalled)
                await pause.release()
                await #expect(throws: MarmotKitError.HistoryTransferClosed) { try await begin.value }
                #expect(original.captured.1 == 1 && original.captured.0.isEmpty)
                let fresh = try await app.makeHistorySourcePickerModel(groupIdHex: "cd")
                #expect(fresh.isActive)
            }
        }
        @Test func sameChatReusesHeldModelAndChatReplacementCancelsOriginal() async throws {
            try await withApp { app in
                let original = HistorySourceOriginal()
                let model = try await app.makeHistorySourcePickerModel(
                    groupIdHex: "ab", readRecipients: { [choice] in [choice] }, beginOriginal: { _ in original })
                let same = try await app.makeHistorySourcePickerModel(groupIdHex: "ab")
                #expect(model === same)
                try await model.loadRecipients()
                try model.select(device: device)
                try await model.begin()
                let next = try await app.makeHistorySourcePickerModel(groupIdHex: "cd")
                #expect(next !== model && next.isActive)
                #expect(!model.isActive && original.captured.1 == 1)
                app.releaseHistorySourcePickerModel(model)
                #expect(next.isActive)
                app.releaseHistorySourcePickerModel(next)
                #expect(!next.isActive)
            }
        }
        @Test func actualSuspensionAndRuntimeRestartCannotAdoptLateOriginal() async throws {
            try await withApp { app in
                let oldClient = app.client
                let pause = HistorySourcePause()
                let original = HistorySourceOriginal()
                let model = try await app.makeHistorySourcePickerModel(
                    groupIdHex: "ab", readRecipients: { [choice] in [choice] },
                    beginOriginal: { _ in
                        await pause.pause()
                        return original
                    })
                try await model.loadRecipients()
                try model.select(device: device)
                let begin = Task { try await model.begin() }
                await pause.waitUntilEntered()
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                #expect(app.client == nil)
                app.setAppSceneActive(true)
                await app.bootstrap()
                app.activeAccountRef = "alice"
                #expect(app.client !== oldClient)
                await #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                    _ = try await app.makeHistorySourcePickerModel(groupIdHex: "ab")
                }
                await pause.release()
                await #expect(throws: MarmotKitError.HistoryTransferClosed) { try await begin.value }
                #expect(!model.isActive && model.review == nil && original.captured.1 == 1)
                let fresh = try await app.makeHistorySourcePickerModel(groupIdHex: "ab")
                #expect(fresh !== model && fresh.isActive)
            }
        }
        @Test(arguments: [0, 1, 2])
        func pendingSourceFactoryBlocksActualDestructiveExit(exit: Int) async throws {
            try await withApp { app in
                app.setPhase(.ready)
                let oldClient = try #require(app.client)
                let pause = HistorySourcePause()
                let original = HistorySourceOriginal()
                let model = try await app.makeHistorySourcePickerModel(
                    groupIdHex: "ab", readRecipients: { [choice] in [choice] },
                    beginOriginal: { _ in
                        await pause.pause()
                        return original
                    })
                try await model.loadRecipients()
                try model.select(device: device)
                let begin = Task { try await model.begin() }
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
                #expect(!reachedCoreExit && app.client === oldClient)
                await pause.release()
                await #expect(throws: MarmotKitError.HistoryTransferClosed) { try await begin.value }
                #expect(original.captured.1 == 1)
                try await app.accountStore.prepareHistoryConsentAcquisition()
            }
        }
        private func withApp(_ body: (AppState) async throws -> Void) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistorySource-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try MarmotClient(rootPath: root.path, relayUrls: ["wss://relay.example.invalid"])
            let defaults = try #require(UserDefaults(suiteName: "HistorySource-\(UUID())"))
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
    }
#endif
