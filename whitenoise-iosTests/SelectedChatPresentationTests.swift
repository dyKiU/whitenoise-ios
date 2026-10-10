import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    private actor PresentationPause {
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
    @MainActor private final class PresentationAccount { var isCurrent = true }
    // SDK originals cross actor boundaries; locks protect only test control state.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class PresentationCopy: SelectedChatCopyProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var revisions: [UInt64] = []
        private var incoming: [(UInt64, Data)] = []
        private var continued: [UInt64] = []
        private var cancelled = 0
        var invalidSnapshot = false
        var snapshotFails = false
        var requestBytes = Data([7, 8, 9])
        var cancelFails = false
        var afterRequest: (@Sendable () async -> Void)?
        var received: [(UInt64, Data)] { lock.withLock { incoming } }
        var continuations: [UInt64] { lock.withLock { continued } }
        var cancellations: Int { lock.withLock { cancelled } }
        var requested: [UInt64] { lock.withLock { revisions } }
        func snapshot() async throws -> SelectedChatCopySnapshotFfi {
            if snapshotFails { throw MarmotKitError.SelectedChatCopyBusy }
            return .init(
                revision: 19, phase: .awaitingSiblingConsent, siblingCount: invalidSnapshot ? 129 : 2,
                consentingSiblingCount: 0,
                offeredSiblingCount: 0)
        }
        func requestPacket(revision: UInt64) async throws -> Data {
            lock.withLock { revisions.append(revision) }
            await afterRequest?()
            return requestBytes
        }
        func receiveConsentPacket(revision: UInt64, packet: Data) async throws {
            lock.withLock { incoming.append((revision, packet)) }
        }
        func receiveOfferPacket(revision: UInt64, packet: Data) async throws {
            lock.withLock { incoming.append((revision, packet)) }
        }
        func continueCopy(revision: UInt64) async throws { lock.withLock { continued.append(revision) } }
        func cancel() async throws {
            lock.withLock { cancelled += 1 }
            if cancelFails { throw MarmotKitError.SelectedChatCopyBusy }
        }
    }
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class PresentationConsent: SelectedChatConsentProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var revisions: [UInt64] = []
        var invalidSnapshot = false
        var snapshotFails = false
        private var packetRevisions: [UInt64] = []
        private var terminalPhase: SelectedChatConsentPhaseFfi?
        func endWithoutRevisionChange(_ phase: SelectedChatConsentPhaseFfi) { lock.withLock { terminalPhase = phase } }
        var exported: [UInt64] { lock.withLock { packetRevisions } }
        var approved: [UInt64] { lock.withLock { revisions } }
        func snapshot() async throws -> SelectedChatConsentSnapshotFfi {
            if snapshotFails { throw MarmotKitError.SelectedChatCopyBusy }
            return lock.withLock {
                .init(
                    revision: revisions.isEmpty ? 23 : 24,
                    phase: terminalPhase ?? (revisions.isEmpty ? .awaitingApproval : .approved),
                    chatSelector: invalidSnapshot ? Data() : Data(repeating: 4, count: 32))
            }
        }
        func approve(revision: UInt64) async throws { lock.withLock { revisions.append(revision) } }
        func responsePacket(revision: UInt64) async throws -> Data {
            lock.withLock { packetRevisions.append(revision) }
            return Data([11, 12])
        }
        func offerPacket(revision: UInt64) async throws -> Data {
            lock.withLock { packetRevisions.append(revision) }
            return Data([13, 14])
        }
        func cancel() async throws {}
    }
    @MainActor @Suite struct SelectedChatPresentationTests {
        @Test func requestDisplayExportsOnlyExplicitOriginalRevision() async throws {
            let original = PresentationCopy()
            let scope = SelectedChatCopyScope(accountRef: "isolated", original: original)
            let model = SelectedChatCopyViewModel(original: scope, isCurrent: { true })
            try await model.refresh()
            #expect(model.snapshot?.revision == 19)
            #expect(original.requested.isEmpty)
            #expect(model.outgoingPacket == nil)
            try await model.exportRequest(displayedRevision: 19)
            #expect(original.requested == [19])
            #expect(model.outgoingPacket == Data([7, 8, 9]).base64EncodedString())
            try await scope.cancel()
        }
        @Test func consentDisplayDoesNotApproveAndActionUsesDisplayedOriginalRevision() async throws {
            let original = PresentationConsent()
            let scope = SelectedChatConsentScope(accountRef: "isolated", original: original)
            let model = SelectedChatConsentViewModel(original: scope, isCurrent: { true })
            try await model.refresh()
            #expect(model.snapshot?.chatSelector == Data(repeating: 4, count: 32))
            #expect(original.approved.isEmpty)
            try await model.approveReviewed(displayedRevision: 23)
            #expect(original.approved == [23])
            try await scope.cancel()
        }

        @Test func incomingPacketsAndContinuationUseExactOriginalRevision() async throws {
            let original = PresentationCopy()
            let model = SelectedChatCopyViewModel(
                original: SelectedChatCopyScope(accountRef: "isolated", original: original), isCurrent: { true })
            try await model.refresh()
            let packet = Data([0, 255, 13, 10])
            try await model.perform(.consent, displayedRevision: 19, input: " \n" + packet.base64EncodedString() + "\n")
            try await model.perform(.offer, displayedRevision: 19, input: packet.base64EncodedString())
            try await model.perform(.continueCopy, displayedRevision: 19)
            #expect(original.received.map { $0.0 } == [19, 19])
            #expect(original.received.map { $0.1 } == [packet, packet])
            #expect(original.continuations == [19])
            try await model.cancel()
        }
        @Test(arguments: ["", "%%%%", "AB==", Data(repeating: 1, count: 16_385).base64EncodedString()])
        func invalidInputNeverReachesOriginal(input: String) async throws {
            let original = PresentationCopy()
            let model = SelectedChatCopyViewModel(
                original: SelectedChatCopyScope(accountRef: "isolated", original: original), isCurrent: { true })
            try await model.refresh()
            await #expect(throws: MarmotKitError.SelectedChatCopyInvalidPacket) {
                try await model.perform(.consent, displayedRevision: 19, input: input)
            }
            #expect(original.received.isEmpty)
            #expect(model.actionError != nil)
            try await model.cancel()
        }
        @Test func staleDisplayedRevisionNeverExports() async throws {
            let original = PresentationCopy()
            let model = SelectedChatCopyViewModel(
                original: SelectedChatCopyScope(accountRef: "isolated", original: original), isCurrent: { true })
            try await model.refresh()
            await #expect(throws: MarmotKitError.SelectedChatCopyStaleRevision) {
                try await model.exportRequest(displayedRevision: 18)
            }
            #expect(original.requested.isEmpty)
            try await model.cancel()
        }
        @Test func malformedCopySnapshotClearsPreviouslyDisplayedPacket() async throws {
            let original = PresentationCopy()
            let model = SelectedChatCopyViewModel(
                original: SelectedChatCopyScope(accountRef: "isolated", original: original), isCurrent: { true })
            try await model.refresh()
            try await model.exportRequest(displayedRevision: 19)
            original.invalidSnapshot = true
            await #expect(throws: MarmotKitError.SelectedChatCopyNotReady) { try await model.refresh() }
            #expect(model.snapshot == nil)
            #expect(model.outgoingPacket == nil)
            try await model.cancel()
        }
        @Test func malformedConsentSnapshotClearsPreviouslyExportedPacket() async throws {
            let original = PresentationConsent()
            let model = SelectedChatConsentViewModel(
                original: SelectedChatConsentScope(accountRef: "isolated", original: original),
                isCurrent: { true })
            try await model.refresh()
            try await model.approveReviewed(displayedRevision: 23)
            try await model.perform(.response, displayedRevision: 24)
            original.invalidSnapshot = true
            await #expect(throws: MarmotKitError.SelectedChatCopyNotReady) { try await model.refresh() }
            #expect(model.snapshot == nil)
            #expect(model.outgoingPacket == nil)
            try await model.cancel()
        }
        @Test func consentPacketsRequireExplicitApprovalAndNewDisplayedRevision() async throws {
            let original = PresentationConsent()
            let model = SelectedChatConsentViewModel(
                original: SelectedChatConsentScope(accountRef: "isolated", original: original),
                isCurrent: { true })
            try await model.refresh()
            await #expect(throws: MarmotKitError.SelectedChatCopyStaleRevision) {
                try await model.perform(.response, displayedRevision: 23)
            }
            #expect(original.exported.isEmpty)
            try await model.approveReviewed(displayedRevision: 23)
            #expect(model.snapshot?.revision == 24)
            await #expect(throws: MarmotKitError.SelectedChatCopyStaleRevision) {
                try await model.perform(.offer, displayedRevision: 23)
            }
            try await model.perform(.response, displayedRevision: 24)
            #expect(model.outgoingPacket == Data([11, 12]).base64EncodedString())
            try await model.perform(.offer, displayedRevision: 24)
            #expect(model.outgoingPacket == Data([13, 14]).base64EncodedString())
            #expect(original.exported == [24, 24])
            #expect(original.approved == [23])
            try await model.cancel()
        }
        @Test(arguments: [Data(), Data(repeating: 1, count: 16_385)])
        func oversizedOrEmptyOriginalPacketNeverDisplays(packet: Data) async throws {
            let original = PresentationCopy()
            original.requestBytes = packet
            let model = SelectedChatCopyViewModel(
                original: SelectedChatCopyScope(accountRef: "isolated", original: original), isCurrent: { true })
            try await model.refresh()
            await #expect(throws: MarmotKitError.SelectedChatCopyInvalidPacket) {
                try await model.exportRequest(displayedRevision: 19)
            }
            #expect(model.outgoingPacket == nil)
            try await model.cancel()
        }
        @Test func failedCleanupRetriesSameOriginalAndHidesDisplayImmediately() async throws {
            let original = PresentationCopy()
            let model = SelectedChatCopyViewModel(
                original: SelectedChatCopyScope(accountRef: "isolated", original: original), isCurrent: { true })
            try await model.refresh()
            try await model.exportRequest(displayedRevision: 19)
            original.cancelFails = true
            await #expect(throws: MarmotKitError.SelectedChatCopyBusy) { try await model.cancel() }
            #expect(model.snapshot == nil)
            #expect(model.outgoingPacket == nil)
            #expect(model.cleanupError != nil)
            original.cancelFails = false
            try await model.cancel()
            try await model.cancel()
            #expect(original.cancellations == 2)
            #expect(model.cleanupError == nil)
        }
        @Test func latePacketCannotEscapeRetiredAccountAndOverlappingActionIsBusy() async throws {
            let pause = PresentationPause()
            let account = PresentationAccount()
            let original = PresentationCopy()
            original.afterRequest = { await pause.pause() }
            let model = SelectedChatCopyViewModel(
                original: SelectedChatCopyScope(accountRef: "isolated", original: original),
                isCurrent: { account.isCurrent })
            try await model.refresh()
            let request = Task { try await model.exportRequest(displayedRevision: 19) }
            await pause.waitUntilEntered()
            await #expect(throws: MarmotKitError.SelectedChatCopyBusy) {
                try await model.exportRequest(displayedRevision: 19)
            }
            account.isCurrent = false
            await pause.release()
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { try await request.value }
            #expect(model.outgoingPacket == nil)
            #expect(model.snapshot == nil)
            #expect(original.requested == [19])
            #expect(!model.isWorking)
            try await model.cancel()
            #expect(original.cancellations == 1)
        }

        @Test(arguments: [SelectedChatConsentPhaseFfi.cancelled, .expired, .closed])
        func terminalConsentPhaseClearsPacketAtUnchangedRevision(phase: SelectedChatConsentPhaseFfi) async throws {
            let original = PresentationConsent()
            let model = SelectedChatConsentViewModel(
                original: SelectedChatConsentScope(accountRef: "isolated", original: original), isCurrent: { true })
            try await model.refresh()
            try await model.approveReviewed(displayedRevision: 23)
            try await model.perform(.response, displayedRevision: 24)
            #expect(model.outgoingPacket != nil)
            original.endWithoutRevisionChange(phase)
            try await model.refresh()
            #expect(model.snapshot?.revision == 24)
            #expect(model.snapshot?.phase == phase)
            #expect(model.outgoingPacket == nil)
            await #expect(throws: MarmotKitError.SelectedChatCopyStaleRevision) {
                try await model.perform(.offer, displayedRevision: 24)
            }
            #expect(original.approved == [23])
            #expect(original.exported == [24])
            try await model.cancel()
        }
        @Test(arguments: [false, true])
        func originalSnapshotErrorClearsPreviousPacket(consent: Bool) async throws {
            if consent {
                let original = PresentationConsent()
                let model = SelectedChatConsentViewModel(
                    original: SelectedChatConsentScope(accountRef: "isolated", original: original), isCurrent: { true })
                try await model.refresh()
                try await model.approveReviewed(displayedRevision: 23)
                try await model.perform(.response, displayedRevision: 24)
                #expect(model.outgoingPacket != nil)
                original.snapshotFails = true
                await #expect(throws: MarmotKitError.SelectedChatCopyBusy) { try await model.refresh() }
                #expect(model.snapshot == nil)
                #expect(model.outgoingPacket == nil)
                try await model.cancel()
            } else {
                let original = PresentationCopy()
                let model = SelectedChatCopyViewModel(
                    original: SelectedChatCopyScope(accountRef: "isolated", original: original), isCurrent: { true })
                try await model.refresh()
                try await model.exportRequest(displayedRevision: 19)
                #expect(model.outgoingPacket != nil)
                original.snapshotFails = true
                await #expect(throws: MarmotKitError.SelectedChatCopyBusy) { try await model.refresh() }
                #expect(model.snapshot == nil)
                #expect(model.outgoingPacket == nil)
                try await model.cancel()
            }
        }
        @Test func actualAccountReplacementHidesOriginalPresentationAcrossReturn() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SelectedChatDisplay-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try MarmotClient(rootPath: root.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(client: client, accountDefaults: IsolatedAccountDefaults.make())
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "A"
            do {
                let original = PresentationCopy()
                let scope = try await app.adoptSelectedChatCopyFactory { _, ref in
                    #expect(ref == "A")
                    return original
                }
                let model = SelectedChatCopyViewModel(original: scope, isCurrent: { scope.isActive })
                try await model.refresh()
                try await model.exportRequest(displayedRevision: 19)
                app.activeAccountRef = "B"
                app.activeAccountRef = "A"
                #expect(model.snapshot == nil)
                #expect(model.outgoingPacket == nil)
                await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { try await model.refresh() }
                try await app.accountStore.retrySelectedChatCleanup()
                #expect(original.cancellations == 1)
            } catch {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                throw error
            }
            app.setAppSceneActive(false)
            await app.startRuntimeSuspension().value
        }
        @Test func transferUsesExactSelectedChatAndTargetWithoutImplicitExport() async throws {
            let original = PresentationCopy()
            let copy = SelectedChatCopyViewModel(
                original: SelectedChatCopyScope(accountRef: "isolated", original: original), isCurrent: { true })
            let selector = Data([32, 31, 30])
            let group = String(repeating: "ab", count: 32)
            var receivedGroup: String?
            var receivedTarget: Data?
            let transfer = SelectedChatTransferViewModel(
                begin: { value, target in
                    receivedGroup = value
                    receivedTarget = target
                    return copy
                },
                receive: { _ in throw MarmotKitError.SelectedChatCopyUnsupported },
                targets: { [.init(selector: selector, deviceCount: 2)] }, isCurrent: { true })
            await #expect(throws: MarmotKitError.SelectedChatCopyNotReady) {
                try await transfer.begin(groupIdHex: group, linkedRosterSelector: selector)
            }
            #expect(receivedGroup == nil)
            try await transfer.loadTargets()
            try await transfer.begin(groupIdHex: group, linkedRosterSelector: selector)
            #expect(receivedGroup == group)
            #expect(receivedTarget == selector)
            #expect(transfer.copyGroupIdHex == group)
            #expect(transfer.copy === copy)
            #expect(original.requested.isEmpty)
            try await copy.cancel()
        }
        @Test func transferReceivesCanonicalOpaqueRequestWithoutApproving() async throws {
            let original = PresentationConsent()
            let consent = SelectedChatConsentViewModel(
                original: SelectedChatConsentScope(accountRef: "isolated", original: original), isCurrent: { true })
            var received: Data?
            let transfer = SelectedChatTransferViewModel(
                begin: { _, _ in throw MarmotKitError.SelectedChatCopyUnsupported },
                receive: { packet in
                    received = packet
                    return consent
                }, targets: { [] }, isCurrent: { true })
            await #expect(throws: MarmotKitError.SelectedChatCopyInvalidPacket) {
                try await transfer.receive(input: "AB==")
            }
            #expect(received == nil)
            let packet = Data([128, 0, 255])
            try await transfer.receive(input: packet.base64EncodedString())
            #expect(received == packet)
            #expect(transfer.consent === consent)
            #expect(consent.snapshot?.chatSelector == Data(repeating: 4, count: 32))
            #expect(original.approved.isEmpty)
            try await consent.cancel()
        }
        @Test func failedTargetReadNeverFallsBackToPreviousSelection() async throws {
            var readFails = false
            var invoked = false
            let selector = Data([32])
            let transfer = SelectedChatTransferViewModel(
                begin: { _, _ in
                    invoked = true
                    throw MarmotKitError.SelectedChatCopyUnsupported
                },
                receive: { _ in throw MarmotKitError.SelectedChatCopyUnsupported },
                targets: {
                    if readFails { throw MarmotKitError.SelectedChatCopyBusy }
                    return [.init(selector: selector, deviceCount: 2)]
                }, isCurrent: { true })
            try await transfer.loadTargets()
            readFails = true
            await #expect(throws: MarmotKitError.SelectedChatCopyBusy) { try await transfer.loadTargets() }
            #expect(transfer.targets.isEmpty)
            await #expect(throws: MarmotKitError.SelectedChatCopyNotReady) {
                try await transfer.begin(groupIdHex: String(repeating: "ab", count: 32), linkedRosterSelector: selector)
            }
            #expect(!invoked)
        }
        @Test func actualAccountCompositionOwnsAndRetiresTransferAcrossReturn() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SelectedChatPane-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try MarmotClient(rootPath: root.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(client: client, accountDefaults: IsolatedAccountDefaults.make())
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "A"
            do {
                let first = try app.makeSelectedChatTransferViewModel()
                #expect(first.isActive)
                #expect(try app.makeSelectedChatTransferViewModel() === first)
                await #expect(throws: MarmotKitError.SelectedChatCopyRuntimeUnavailable) {
                    try await first.receive(input: Data([1]).base64EncodedString())
                }
                #expect(first.consent == nil)
                app.activeAccountRef = "B"
                app.activeAccountRef = "A"
                #expect(!first.isActive)
                #expect(first.targets.isEmpty)
                await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                    try await first.receive(input: Data([1]).base64EncodedString())
                }
                let second = try app.makeSelectedChatTransferViewModel()
                #expect(second !== first)
                app.setAppSceneActive(false)
                #expect(!second.isActive)
                await app.startRuntimeSuspension().value
                #expect(!second.isActive)
            } catch {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                throw error
            }
        }
    }
#endif
