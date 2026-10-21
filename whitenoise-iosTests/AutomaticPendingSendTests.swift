import Foundation
import MarmotKit
import Synchronization
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    nonisolated private final class PendingSendState: Sendable {
        nonisolated private struct State: Sendable {
            var value: LocalSendStatusFfi? = .queued
            var calls = 0
            var blocked = false
            var entered = false
        }
        private let state = Mutex(State())
        private let release = DispatchSemaphore(value: 0)
        let eventId = String(repeating: "a", count: 64)
        var callCount: Int { state.withLock { $0.calls } }
        var isWaiting: Bool { state.withLock { $0.entered } }
        func reject() { state.withLock { $0.value = .rejected } }
        func forgetStatus() { state.withLock { $0.value = nil } }
        func holdNextStatus() { state.withLock { $0.blocked = true } }
        func finishStatus() { release.signal() }
        func status() throws -> LocalSendStatusFfi? {
            let held = state.withLock { value in
                value.calls += 1
                value.entered = value.blocked
                return value.blocked
            }
            if held, release.wait(timeout: .now() + 5) != .success { throw CancellationError() }
            return state.withLock { $0.value }
        }
    }

    nonisolated private final class PendingSender: PairedConversationSending {
        nonisolated private struct Gate: Sendable {
            var enabled = false
            var reached = false
            var waiter: CheckedContinuation<Void, Never>?
            var failuresRemaining = 0
            var tokens: [String] = []
        }
        private let gate = Mutex(Gate())
        private let state: PendingSendState
        init(state: PendingSendState) { self.state = state }
        var messageActionGateEnabled: Bool {
            get { gate.withLock { $0.enabled } }
            set { gate.withLock { $0.enabled = newValue } }
        }
        var didReachMessageActionGate: Bool { gate.withLock { $0.reached } }
        var submittedTokens: [String] { gate.withLock { $0.tokens } }
        func interruptNextAdmission() { gate.withLock { $0.failuresRemaining = 1 } }
        func releaseMessageActionGate() {
            let waiter = gate.withLock { value in
                value.enabled = false
                let waiter = value.waiter
                value.waiter = nil
                return waiter
            }
            waiter?.resume()
        }
        func sendTextWithClientToken(accountRef: String, groupIdHex: String, text: String, clientToken: String)
            async throws -> LocalSendAcceptanceFfi
        {
            gate.withLock { $0.tokens.append(clientToken) }
            await withCheckedContinuation { reply in
                let immediate = gate.withLock { value in
                    guard value.enabled else { return true }
                    value.reached = true
                    value.waiter = reply
                    return false
                }
                if immediate { reply.resume() }
            }
            let interrupted = gate.withLock { value in
                guard value.failuresRemaining > 0 else { return false }
                value.failuresRemaining -= 1
                return true
            }
            if interrupted { throw CancellationError() }
            return .init(clientToken: clientToken, messageIdHex: state.eventId)
        }
        func replyWithClientToken(
            accountRef: String, groupIdHex: String, targetMessageId: String,
            text: String, clientToken: String
        ) async throws -> LocalSendAcceptanceFfi {
            try await sendTextWithClientToken(
                accountRef: accountRef, groupIdHex: groupIdHex,
                text: text, clientToken: clientToken)
        }
        func localSendStatus(accountRef: String, groupIdHex: String, clientToken: String) async throws
            -> LocalSendStatusFfi?
        {
            try await Task.detached { [state] in try state.status() }.value
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
                let immediate = state.withLock { value -> (Bool, AccountConversationWindowSnapshotFfi?) in
                    if value.cancelled { return (true, nil) }
                    if !value.queue.isEmpty { return (true, value.queue.removeFirst()) }
                    value.pending = reply
                    return (false, nil)
                }
                if immediate.0 { reply.resume(returning: immediate.1) }
            }
        }
        func emit(_ replacement: AccountConversationWindowSnapshotFfi) {
            let reply: CheckedContinuation<AccountConversationWindowSnapshotFfi?, Error>? = state.withLock { value in
                guard !value.cancelled else { return nil }
                let reply = value.pending
                value.pending = nil
                if reply == nil { value.queue.append(replacement) }
                return reply
            }
            reply?.resume(returning: replacement)
        }
        func olderPage(sequence: UInt64, before: PairedChatMessageCursorFfi?) async throws
            -> AccountConversationWindowSnapshotFfi
        { throw CancellationError() }
        func cancel() {
            let reply = state.withLock { value in
                value.cancelled = true
                value.queue = []
                let reply = value.pending
                value.pending = nil
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
            -> any AccountConversationObserving
        { original }
    }

    @MainActor @Suite struct IOSAutomaticPendingSendTests {
        private let group = "0102"
        private func snapshot(sequence: UInt64, eventId: String? = nil) -> AccountConversationWindowSnapshotFfi {
            let source = PairedChatSourceFfi(
                deviceHex: String(repeating: "b", count: 64), policyDigestHex: String(repeating: "c", count: 64),
                protectedGeneration: 1, sourceEpoch: 1, sourceSequence: sequence,
                sourceDigestHex: String(repeating: "d", count: 64))
            let header = PairedChatSummaryFfi(groupIdHex: group, name: "Synthetic", description: "", source: source)
            let rows: [AccountConversationRowFfi] =
                eventId.map { id in
                    [
                        .pairedSource(
                            row: PairedChatMessageFfi(
                                kind: 9, canonicalChat: true, messageIdHex: id,
                                authorHex: String(repeating: "e", count: 64),
                                createdAt: 1, expiresAt: nil, deleted: false, content: "Synthetic message",
                                contentTokens: MarkdownDocumentFfi(
                                    blocks: [], truncated: false, blankLinesBefore: Data()),
                                tags: [], mediaAttachments: [], source: source))
                    ]
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
            let model = AccountConversationViewModel(
                accountRef: "synthetic-account", groupIdHex: group, runtime: runtime,
                observations: PendingFactory(original: original))
            model.start()
            #expect(await waitFor { model.snapshot != nil })
            return (model, original, state)
        }

        @Test func nativeMarkdownProjectionClearsOnDeletionAndAccountRetirement() async throws {
            let (model, original, state) = try await ready()
            defer { model.invalidate() }
            var replacement = snapshot(sequence: 2, eventId: state.eventId)
            guard case .pairedSource(var message) = replacement.rows[0] else {
                Issue.record("Expected source-attested synthetic row")
                return
            }
            message.contentTokens = .init(
                blocks: [.paragraph(inlines: [.text(content: "Synthetic rendered text")])],
                truncated: false, blankLinesBefore: Data())
            replacement.rows = [.pairedSource(row: message)]
            original.emit(replacement)
            #expect(await waitFor { model.markdownByMessageId[state.eventId] != nil })
            replacement.sequence = 3
            message.deleted = true
            replacement.rows = [.pairedSource(row: message)]
            original.emit(replacement)
            #expect(await waitFor { model.snapshot?.sequence == 3 })
            #expect(model.markdownByMessageId.isEmpty)
            replacement.sequence = 4
            message.deleted = false
            replacement.rows = [.pairedSource(row: message)]
            original.emit(replacement)
            #expect(await waitFor { model.markdownByMessageId[state.eventId] != nil })
            model.invalidate()
            #expect(model.markdownByMessageId.isEmpty)
        }

        @Test func observedCanonicalRowBeforeAdmissionReturnsDoesNotLeaveDuplicatePendingBubble() async throws {
            let original = PendingConversation(snapshot(sequence: 1))
            let state = PendingSendState()
            let runtime = PendingSender(state: state)
            runtime.messageActionGateEnabled = true
            let model = AccountConversationViewModel(
                accountRef: "synthetic-account", groupIdHex: group, runtime: runtime,
                observations: PendingFactory(original: original))
            model.start()
            defer {
                runtime.releaseMessageActionGate()
                model.invalidate()
            }
            #expect(await waitFor { model.snapshot != nil })
            let sending = Task { try await model.sendText("Synthetic message") }
            #expect(await waitFor { runtime.didReachMessageActionGate })
            let token = try #require(model.pendingTexts.keys.first)
            #expect(model.pendingTexts[token]?.acceptedMessageIdHex == nil)
            original.emit(snapshot(sequence: 2, eventId: state.eventId))
            #expect(await waitFor { model.snapshot?.sequence == 2 })
            #expect(model.pairedMessages.map(\.messageIdHex) == [state.eventId])
            runtime.releaseMessageActionGate()
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

        @Test func windowEndKeepsAcceptedPendingTokenForReconciliation() async throws {
            let (model, original, state) = try await ready()
            defer { model.invalidate() }
            let accepted = try await model.sendText("Synthetic pending message")
            original.cancel()
            #expect(await waitFor { model.error == .unavailable })
            #expect(model.pendingTexts[accepted.clientToken]?.acceptedMessageIdHex == state.eventId)
            #expect(model.pendingTexts[accepted.clientToken]?.text == "Synthetic pending message")
        }

        @Test func backgroundHandoffKeepsTranscriptDraftAndPendingWithoutKeepingNativeOwner() async throws {
            let suite = "automatic-background-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = AccountStore(defaults: defaults)
            store.activeAccountRef = "synthetic-account"
            let (model, original, state) = try await ready()
            try store.holdAutomaticConversation(model, groupIdHex: group)
            let accepted = try await model.sendText("Synthetic pending message")
            model.continuity.draft = "An unsent draft"
            original.emit(snapshot(sequence: 2, eventId: "previous-message"))
            #expect(await waitFor { model.snapshot?.sequence == 2 })
            try await store.cancelDeviceLinking(preservingConversationState: true)
            #expect(!model.isCurrentOwner)
            #expect(store.automaticConversationModels.isEmpty)
            let retained = try store.automaticConversationContinuity(groupIdHex: group)
            #expect(retained === model.continuity)
            #expect(retained.draft == "An unsent draft")
            #expect(retained.pendingTexts[accepted.clientToken]?.acceptedMessageIdHex == state.eventId)
            #expect(retained.snapshot?.sequence == 2)

            var fresh = snapshot(sequence: 1, eventId: state.eventId)
            fresh.generation = "new-runtime-generation"
            let replacement = AccountConversationViewModel(
                accountRef: "synthetic-account", groupIdHex: group, runtime: PendingSender(state: state),
                observations: PendingFactory(original: PendingConversation(fresh)), continuity: retained)
            try store.holdAutomaticConversation(replacement, groupIdHex: group)
            #expect(replacement.snapshot?.sequence == 2)
            replacement.start()
            #expect(await waitFor { replacement.snapshot?.generation == fresh.generation })
            #expect(replacement.pendingTexts.isEmpty)
            #expect(replacement.continuity.draft == "An unsent draft")
            replacement.invalidate()
        }

        @Test func inactiveObservationRetiresWithoutClearingAcceptedSendOrDraft() async throws {
            var current = true
            let state = PendingSendState()
            let sender = PendingSender(state: state)
            let original = PendingConversation(snapshot(sequence: 1))
            let model = AccountConversationViewModel(
                accountRef: "synthetic-account", groupIdHex: group, runtime: sender,
                observations: PendingFactory(original: original), isPresentationCurrent: { true },
                isCurrent: { current })
            model.start()
            defer { model.invalidate() }
            #expect(await waitFor { model.snapshot != nil })
            let accepted = try await model.sendText("Synthetic pending message")
            model.continuity.draft = "Unsent draft"
            current = false
            original.cancel()
            #expect(await waitFor { model.retired })
            current = true
            #expect(!model.isCurrentOwner)
            #expect(model.pairedHeader != nil)
            #expect(model.continuity.draft == "Unsent draft")
            #expect(model.pendingTexts[accepted.clientToken]?.acceptedMessageIdHex == state.eventId)

            let replacement = AccountConversationViewModel(
                accountRef: "synthetic-account", groupIdHex: group, runtime: sender,
                observations: PendingFactory(original: PendingConversation(snapshot(sequence: 1))),
                continuity: model.continuity)
            let statusCallsBeforeResume = state.callCount
            replacement.start()
            defer { replacement.suspend() }
            #expect(await waitFor { state.callCount > statusCallsBeforeResume })
            #expect(sender.submittedTokens == [accepted.clientToken])
            #expect(replacement.pendingTexts[accepted.clientToken] != nil)
        }

        @Test func lateAdmissionAfterBackgroundKeepsOriginalTokenAndCannotResurrectSwitchedAccount() async throws {
            for switchesAccount in [false, true] {
                let suite = "automatic-late-background-" + UUID().uuidString
                let defaults = try #require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let store = AccountStore(defaults: defaults)
                store.activeAccountRef = "synthetic-account"
                let original = PendingConversation(snapshot(sequence: 1))
                let state = PendingSendState()
                let sender = PendingSender(state: state)
                sender.messageActionGateEnabled = true
                let model = AccountConversationViewModel(
                    accountRef: "synthetic-account", groupIdHex: group, runtime: sender,
                    observations: PendingFactory(original: original))
                try store.holdAutomaticConversation(model, groupIdHex: group)
                model.start()
                #expect(await waitFor { model.snapshot != nil })
                let send = Task { try await model.sendText("Synthetic pending message") }
                #expect(await waitFor { sender.didReachMessageActionGate })
                let token = try #require(model.pendingTexts.keys.first)
                try await store.cancelDeviceLinking(preservingConversationState: true)
                if switchesAccount { store.activeAccountRef = "different-account" }
                sender.releaseMessageActionGate()
                let result = await send.result
                if switchesAccount {
                    if case .success = result { Issue.record("Retired account accepted a late result") }
                    #expect(model.pendingTexts.isEmpty)
                    #expect(model.snapshot == nil)
                } else {
                    #expect(try result.get().clientToken == token)
                    #expect(model.pendingTexts[token]?.acceptedMessageIdHex == state.eventId)
                }
                model.invalidate()
            }
        }

        @Test func interruptedUnacceptedAdmissionResumesWithOriginalTokenAfterFreshWindow() async throws {
            let suite = "automatic-reconcile-background-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = AccountStore(defaults: defaults)
            store.activeAccountRef = "synthetic-account"
            let state = PendingSendState()
            state.forgetStatus()
            let sender = PendingSender(state: state)
            sender.messageActionGateEnabled = true
            sender.interruptNextAdmission()
            let model = AccountConversationViewModel(
                accountRef: "synthetic-account", groupIdHex: group, runtime: sender,
                observations: PendingFactory(original: PendingConversation(snapshot(sequence: 1))))
            try store.holdAutomaticConversation(model, groupIdHex: group)
            model.start()
            #expect(await waitFor { model.snapshot != nil })
            let send = Task { try await model.sendText("Synthetic interrupted message") }
            #expect(await waitFor { sender.didReachMessageActionGate })
            let token = try #require(model.pendingTexts.keys.first)
            try await store.cancelDeviceLinking(preservingConversationState: true)
            sender.releaseMessageActionGate()
            if case .success = await send.result { Issue.record("Expected interrupted native admission") }
            let retained = try store.automaticConversationContinuity(groupIdHex: group)
            #expect(retained.pendingTexts[token]?.needsAdmissionReconciliation == true)
            var fresh = snapshot(sequence: 1)
            fresh.generation = "fresh-reconciliation-generation"
            let replacement = AccountConversationViewModel(
                accountRef: "synthetic-account", groupIdHex: group, runtime: sender,
                observations: PendingFactory(original: PendingConversation(fresh)), continuity: retained)
            try store.holdAutomaticConversation(replacement, groupIdHex: group)
            replacement.start()
            defer { replacement.invalidate() }
            #expect(await waitFor { replacement.pendingTexts[token]?.acceptedMessageIdHex == state.eventId })
            #expect(sender.submittedTokens == [token, token])
            #expect(replacement.pendingTexts.count == 1)
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
            #expect(
                await waitFor {
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

        @Test func accountSwitchClearsQueuedTextAndTheOldConversationWindow() async throws {
            let name = "automatic-conversation-owner-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let store = AccountStore(defaults: defaults)
            store.activeAccountRef = "synthetic-account"
            let (model, original, state) = try await ready()
            try store.holdAutomaticConversation(model, groupIdHex: group)
            _ = try await model.sendText("Synthetic message")
            #expect(!model.pendingTexts.isEmpty)
            store.activeAccountRef = "another-account"
            #expect(store.automaticConversationModels.isEmpty)
            #expect(!model.isCurrentOwner)
            #expect(model.snapshot == nil)
            #expect(model.pendingTexts.isEmpty)
            original.emit(snapshot(sequence: 2, eventId: state.eventId))
            await Task.yield()
            #expect(model.pairedMessages.isEmpty)
        }

        @Test func pairedConversationResolvesWithoutOpeningAnAccountChatList() async throws {
            // This factory refuses every list read; direct navigation must use the exact native group window.
            let (model, _, _) = try await ready()
            defer { model.invalidate() }
            #expect(model.pairedHeader?.groupIdHex == group)
            #expect(model.isCurrentOwner)
        }

        @Test func releasingAnOldNavigationOwnerCannotRetireItsReplacement() async throws {
            let name = "automatic-navigation-replacement-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let store = AccountStore(defaults: defaults)
            store.activeAccountRef = "synthetic-account"
            let (old, _, _) = try await ready()
            try store.holdAutomaticConversation(old, groupIdHex: group)
            let (replacement, _, _) = try await ready()
            defer { replacement.invalidate() }
            try store.holdAutomaticConversation(replacement, groupIdHex: group)
            store.releaseAutomaticConversation(old, groupIdHex: group)
            #expect(!old.isCurrentOwner)
            #expect(store.automaticConversationModels[group] === replacement)
            #expect(replacement.isCurrentOwner)
            #expect(replacement.pairedHeader?.groupIdHex == group)
        }

    }
#endif
