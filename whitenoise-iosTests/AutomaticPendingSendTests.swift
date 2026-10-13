import Foundation
import MarmotKit
import Synchronization
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    nonisolated private final class PendingSendState: Sendable {
        nonisolated private struct State: Sendable {
            var value: LocalSendStatusFfi = .queued
            var calls = 0
            var blocked = false
            var entered = false
            var admission: CheckedContinuation<Void, Never>?
            var holdAdmission = false
        }
        private let state = Mutex(State())
        private let release = DispatchSemaphore(value: 0)
        let eventId = String(repeating: "a", count: 64)
        var callCount: Int { state.withLock { $0.calls } }
        var isWaiting: Bool { state.withLock { $0.entered } }
        var admissionIsWaiting: Bool { state.withLock { $0.admission != nil } }
        func holdNextAdmission() { state.withLock { $0.holdAdmission = true } }
        func releaseAdmission() {
            let continuation = state.withLock { state in
                state.holdAdmission = false
                let continuation = state.admission
                state.admission = nil
                return continuation
            }
            continuation?.resume()
        }
        func waitForAdmission() async {
            await withCheckedContinuation { continuation in
                let held = state.withLock { state in
                    if !state.holdAdmission { return false }
                    state.admission = continuation
                    return true
                }
                if !held { continuation.resume() }
            }
        }
        func reject() { state.withLock { $0.value = .rejected } }
        func holdNextStatus() { state.withLock { $0.blocked = true } }
        func finishStatus() { release.signal() }
        func status() throws -> LocalSendStatusFfi {
            let held = state.withLock { state in
                state.calls += 1
                state.entered = state.blocked
                return state.blocked
            }
            if held, release.wait(timeout: .now() + 5) != .success { throw CancellationError() }
            return state.withLock { $0.value }
        }
    }

    nonisolated private final class PendingConversation: AccountConversationObserving, Sendable {
        nonisolated private struct State: Sendable {
            var pending: CheckedContinuation<AccountConversationWindowSnapshotFfi?, Error>?
            var queue: [AccountConversationWindowSnapshotFfi] = []
            var cancelled = false
        }
        private let state = Mutex(State())
        private let initial: AccountConversationWindowSnapshotFfi
        init(_ initial: AccountConversationWindowSnapshotFfi) { self.initial = initial }
        func snapshot() -> AccountConversationWindowSnapshotFfi? { initial }
        func next() async throws -> AccountConversationWindowSnapshotFfi? {
            try await withCheckedThrowingContinuation { reply in
                let ready = state.withLock { state -> (Bool, AccountConversationWindowSnapshotFfi?) in
                    if state.cancelled { return (true, nil) }
                    if !state.queue.isEmpty { return (true, state.queue.removeFirst()) }
                    state.pending = reply
                    return (false, nil)
                }
                if ready.0 { reply.resume(returning: ready.1) }
            }
        }
        func emit(_ value: AccountConversationWindowSnapshotFfi) {
            let reply = state.withLock { state in
                let reply = state.pending
                state.pending = nil
                if reply == nil { state.queue.append(value) }
                return reply
            }
            reply?.resume(returning: value)
        }
        func olderPage(sequence: UInt64, before: PairedChatMessageCursorFfi?) async throws
            -> AccountConversationWindowSnapshotFfi
        { throw CancellationError() }
        func cancel() {
            let reply = state.withLock { state in
                state.cancelled = true
                let reply = state.pending
                state.pending = nil
                return reply
            }
            reply?.resume(returning: nil)
        }
    }

    nonisolated private struct PendingFactory: AccountChatObserving {
        let original: PendingConversation
        func openAccountChatList(accountRef: String, initialRows: UInt32) async throws -> any AccountChatListObserving {
            throw CancellationError()
        }
        func openAccountConversation(accountRef: String, groupIdHex: String, initialRows: UInt32) async throws
            -> any AccountConversationObserving { original }
    }

    nonisolated private struct PendingSender: AccountChatSending {
        let state: PendingSendState
        func sendTextWithClientToken(accountRef: String, groupIdHex: String, text: String, clientToken: String)
            async throws -> LocalSendAcceptanceFfi {
            let acceptance = LocalSendAcceptanceFfi(clientToken: clientToken, messageIdHex: state.eventId)
            await state.waitForAdmission()
            return acceptance
        }
        func replyWithClientToken(accountRef: String, groupIdHex: String, targetMessageId: String,
                                  text: String, clientToken: String) async throws -> LocalSendAcceptanceFfi {
            .init(clientToken: clientToken, messageIdHex: state.eventId)
        }
        func localSendStatus(accountRef: String, groupIdHex: String, clientToken: String)
            async throws -> LocalSendStatusFfi? { try await Task.detached { try state.status() }.value }
    }

    @MainActor @Suite struct AutomaticPendingSendTests {
        private let group = "0102"
        private func snapshot(sequence: UInt64, eventId: String? = nil) -> AccountConversationWindowSnapshotFfi {
            let source = PairedChatSourceFfi(
                deviceHex: String(repeating: "b", count: 64), policyDigestHex: String(repeating: "c", count: 64),
                protectedGeneration: 1, sourceEpoch: 1, sourceSequence: sequence,
                sourceDigestHex: String(repeating: "d", count: 64))
            let header = PairedChatSummaryFfi(groupIdHex: group, name: "Synthetic", description: "", source: source)
            let rows: [AccountConversationRowFfi] = eventId.map { id in
                [.pairedSource(row: PairedChatMessageFfi(
                    kind: 9, canonicalChat: true, messageIdHex: id, authorHex: String(repeating: "e", count: 64),
                    createdAt: 1, expiresAt: nil, deleted: false, content: "Synthetic message",
                    contentTokens: MarkdownDocumentFfi(blocks: [], truncated: false, blankLinesBefore: Data()),
                    tags: [], mediaAttachments: [], source: source))]
            } ?? []
            return AccountConversationWindowSnapshotFfi(
                generation: "synthetic-generation", sequence: sequence, header: .pairedSource(header: header),
                rows: rows, nextBefore: nil)
        }
        private func waitFor(_ predicate: () -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(3))
            while clock.now < deadline {
                if predicate() { return true }
                do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
            }
            return predicate()
        }
        private func ready() async throws -> (AccountConversationViewModel, PendingConversation, PendingSendState) {
            let original = PendingConversation(snapshot(sequence: 1))
            let state = PendingSendState()
            let runtime = PendingSender(state: state)
            let model = AccountConversationViewModel(accountRef: "synthetic-account", groupIdHex: group, runtime: runtime,
                observations: PendingFactory(original: original), isCurrent: { true })
            model.start()
            #expect(await waitFor { model.snapshot != nil })
            return (model, original, state)
        }

        @Test func observedCanonicalRowBeforeAdmissionReturnsDoesNotLeaveDuplicatePendingBubble() async throws {
            let original = PendingConversation(snapshot(sequence: 1))
            let state = PendingSendState()
            state.holdNextAdmission()
            let model = AccountConversationViewModel(
                accountRef: "synthetic-account", groupIdHex: group, runtime: PendingSender(state: state),
                observations: PendingFactory(original: original), isCurrent: { true })
            model.start()
            defer {
                state.releaseAdmission()
                model.invalidate()
            }
            #expect(await waitFor { model.snapshot != nil })
            let sending = Task { try await model.sendText("Synthetic message") }
            #expect(await waitFor { state.admissionIsWaiting })
            let token = try #require(model.pendingTexts.keys.first)
            #expect(model.pendingTexts[token]?.acceptedMessageIdHex == nil)
            original.emit(snapshot(sequence: 2, eventId: state.eventId))
            #expect(await waitFor { model.snapshot?.sequence == 2 })
            #expect(model.pairedMessages.map(\.messageIdHex) == [state.eventId])
            state.releaseAdmission()
            let acceptance = try await sending.value
            #expect(acceptance.clientToken == token)
            #expect(acceptance.messageIdHex == state.eventId)
            await model.refreshPendingStatus()
            #expect(model.pendingTexts.isEmpty)
            #expect(model.pairedMessages.map(\.messageIdHex) == [acceptance.messageIdHex])
        }

        @Test func knownCanonicalImportReplacesQueuedBubbleWithoutClaimingSentBeforeReceipt() async throws {
            let (model, original, state) = try await ready()
            defer { model.invalidate() }
            let acceptance = try await model.sendText("Synthetic message")
            #expect(acceptance.messageIdHex == state.eventId)
            await model.refreshPendingStatus()
            #expect(model.pendingTexts.count == 1)
            if case .queued? = model.pendingTexts.values.first?.status {} else { Issue.record("Expected queued") }
            original.emit(snapshot(sequence: 2, eventId: state.eventId))
            #expect(await waitFor { model.snapshot?.sequence == 2 })
            #expect(model.pendingTexts.isEmpty)
            #expect(model.pairedMessages.map(\.messageIdHex) == [state.eventId])
        }

        @Test func newerOriginalWindowRefreshesRejectedTokenWithoutManualStatusAction() async throws {
            let (model, original, state) = try await ready()
            defer { model.invalidate() }
            _ = try await model.sendText("Synthetic message")
            await model.refreshPendingStatus()
            let calls = state.callCount
            state.reject()
            original.emit(snapshot(sequence: 2))
            #expect(await waitFor { model.snapshot?.sequence == 2 })
            #expect(await waitFor { state.callCount > calls })
            #expect(await waitFor {
                if case .rejected? = model.pendingTexts.values.first?.status { return true }
                return false
            })
            #expect(model.pairedMessages.isEmpty)
        }

        @Test func lateStatusCannotRepopulateRetiredAccountOwner() async throws {
            let (model, _, state) = try await ready()
            _ = try await model.sendText("Synthetic message")
            state.holdNextStatus()
            let refresh = Task { await model.refreshPendingStatus() }
            #expect(await waitFor { state.isWaiting })
            model.invalidate()
            state.reject()
            state.finishStatus()
            await refresh.value
            #expect(model.snapshot == nil)
            #expect(model.pendingTexts.isEmpty)
            #expect(model.error == nil)
        }
    }
#endif
