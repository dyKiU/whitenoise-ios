import Foundation
import MarmotKit
import Synchronization
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    nonisolated private final class PagingList: AccountChatListObserving, Sendable {
        nonisolated private struct Call: Sendable {
            let sequence: UInt64
            let cursor: String?
        }
        nonisolated private struct State: Sendable {
            var calls: [Call] = []
            var page: CheckedContinuation<AccountChatListWindowSnapshotFfi, Error>?
            var update: CheckedContinuation<AccountChatListWindowSnapshotFfi?, Error>?
            var cancelled = false
        }
        private let state = Mutex(State())
        private let initial: AccountChatListWindowSnapshotFfi
        init(_ initial: AccountChatListWindowSnapshotFfi) { self.initial = initial }
        var callCount: Int { state.withLock { $0.calls.count } }
        var lastSequence: UInt64? { state.withLock { $0.calls.last?.sequence } }
        var lastCursor: String? { state.withLock { $0.calls.last?.cursor } }
        var hasUpdateWaiter: Bool { state.withLock { $0.update != nil } }
        func snapshot() -> AccountChatListWindowSnapshotFfi? { initial }
        func next() async throws -> AccountChatListWindowSnapshotFfi? {
            try await withCheckedThrowingContinuation { reply in
                let cancelled = state.withLock { state in
                    if state.cancelled { return true }
                    state.update = reply
                    return false
                }
                if cancelled { reply.resume(returning: nil) }
            }
        }
        func pairedPage(sequence: UInt64, afterGroupIdHex: String?) async throws -> AccountChatListWindowSnapshotFfi {
            try await withCheckedThrowingContinuation { reply in
                state.withLock {
                    $0.calls.append(Call(sequence: sequence, cursor: afterGroupIdHex))
                    $0.page = reply
                }
            }
        }
        func finishPage(_ snapshot: AccountChatListWindowSnapshotFfi) {
            let reply = state.withLock { state in
                let reply = state.page
                state.page = nil
                return reply
            }
            reply?.resume(returning: snapshot)
        }
        func emit(_ snapshot: AccountChatListWindowSnapshotFfi) {
            let reply = state.withLock { state in
                let reply = state.update
                state.update = nil
                return reply
            }
            reply?.resume(returning: snapshot)
        }
        func cancel() {
            let reply = state.withLock { state in
                state.cancelled = true
                let reply = state.update
                state.update = nil
                return reply
            }
            reply?.resume(returning: nil)
        }
    }
    nonisolated private struct PagingFactory: AccountChatObserving {
        let original: PagingList
        func openAccountChatList(accountRef: String, initialRows: UInt32) async throws -> any AccountChatListObserving {
            original
        }
        func openAccountConversation(accountRef: String, groupIdHex: String, initialRows: UInt32) async throws
            -> any AccountConversationObserving
        { throw CancellationError() }
    }
    @MainActor @Suite struct IOSAutomaticPairedListPagingTests {
        private func page(sequence: UInt64, start: Int, cursor: String?) -> AccountChatListWindowSnapshotFfi {
            let source = PairedChatSourceFfi(
                deviceHex: String(repeating: "b", count: 64), policyDigestHex: String(repeating: "c", count: 64),
                protectedGeneration: 1, sourceEpoch: 1, sourceSequence: sequence,
                sourceDigestHex: String(repeating: "d", count: 64))
            let rows = (start..<(start + 64)).map { index in
                AccountChatRowFfi.pairedSource(
                    row: PairedChatSummaryFfi(
                        groupIdHex: String(format: "%04x", index), name: "Synthetic", description: "", source: source))
            }
            return AccountChatListWindowSnapshotFfi(
                generation: "synthetic-generation", sequence: sequence,
                local: ChatListWindowSnapshotFfi(
                    subscriptionGeneration: "local", sequence: sequence, view: .chats,
                    rows: [], hasMoreBefore: false, hasMoreAfter: false, anchor: .top),
                rows: rows, nextPairedGroupIdHex: cursor)
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
        private func ready() async -> (AccountChatListViewModel, PagingList) {
            let original = PagingList(page(sequence: 1, start: 0, cursor: "003f"))
            let model = AccountChatListViewModel(
                accountRef: "synthetic-account", runtime: PagingFactory(original: original))
            model.start()
            #expect(await waitFor { model.snapshot != nil && original.hasUpdateWaiter })
            return (model, original)
        }

        @Test func viewportEdgeRequestsOneBoundedPageWithoutDrainingEveryLaterChat() async {
            let (model, original) = await ready()
            defer { model.invalidate() }
            await model.pairedBoundaryVisibilityChanged(false)
            #expect(original.callCount == 0)
            await model.pairedBoundaryVisibilityChanged(true)
            #expect(original.callCount == 0)
            await model.pairedBoundaryVisibilityChanged(false)
            await model.pairedUserScrollChanged(true)
            let loading = Task { await model.pairedBoundaryVisibilityChanged(true) }
            #expect(await waitFor { original.callCount == 1 })
            await model.pairedBoundaryVisibilityChanged(true)
            #expect(original.callCount == 1)
            #expect(original.lastSequence == 1)
            #expect(original.lastCursor == "003f")
            original.finishPage(page(sequence: 2, start: 64, cursor: "007f"))
            await loading.value
            #expect(model.pairedRows.count == 64)
            #expect(model.pairedRows.first?.groupIdHex == "0040")
            #expect(model.pairedRows.last?.groupIdHex == "007f")
            await model.pairedBoundaryVisibilityChanged(true)
            #expect(original.callCount == 1)
            await model.pairedBoundaryVisibilityChanged(false)
            await model.pairedBoundaryVisibilityChanged(true)
            #expect(original.callCount == 1)
            await model.pairedBoundaryVisibilityChanged(false)
            await model.pairedUserScrollChanged(true)
            let next = Task { await model.pairedBoundaryVisibilityChanged(true) }
            #expect(await waitFor { original.callCount == 2 })
            #expect(original.lastSequence == 2)
            #expect(original.lastCursor == "007f")
            original.finishPage(page(sequence: 3, start: 128, cursor: nil))
            await next.value
            #expect(model.pairedRows.count == 64)
            #expect(model.pairedRows.first?.groupIdHex == "0080")
            let previous = Task { await model.loadPreviousPaired() }
            #expect(await waitFor { original.callCount == 3 })
            #expect(original.lastCursor == "003f")
            original.finishPage(page(sequence: 4, start: 64, cursor: "007f"))
            await previous.value
            #expect(model.pairedRows.first?.groupIdHex == "0040")
            let first = Task { await model.loadPreviousPaired() }
            #expect(await waitFor { original.callCount == 4 })
            #expect(original.lastCursor == nil)
            original.finishPage(page(sequence: 5, start: 0, cursor: "003f"))
            await first.value
            #expect(model.pairedRows.first?.groupIdHex == "0000")
            #expect(!model.hasPreviousPairedPage)
        }

        @Test func endedWindowRetainsKnownRowsWhileAReplacementLoads() async {
            let (model, original) = await ready()
            defer { model.invalidate() }
            let loadedRows = model.pairedRows
            original.cancel()
            #expect(await waitFor { model.error == .unavailable })
            #expect(model.pairedRows == loadedRows)
            #expect(model.snapshot != nil)
        }

        @Test func backgroundHandoffKeepsListUntilFreshWindowAndAccountSwitchClearsIt() async throws {
            let suite = "automatic-list-background-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = AccountStore(defaults: defaults)
            store.activeAccountRef = "synthetic-account"
            let (model, _) = await ready()
            try store.holdAutomaticChatList(model)
            let knownRows = model.pairedRows
            try await store.cancelDeviceLinking(preservingConversationState: true)
            #expect(model.retired)
            #expect(store.automaticChatListModel == nil)
            #expect(model.pairedRows == knownRows)
            let retained = try store.automaticListContinuity()
            #expect(retained === model.continuity)
            var fresh = page(sequence: 1, start: 64, cursor: nil)
            fresh.generation = "fresh-list-generation"
            let replacement = AccountChatListViewModel(
                accountRef: "synthetic-account", runtime: PagingFactory(original: PagingList(fresh)),
                continuity: retained)
            try store.holdAutomaticChatList(replacement)
            #expect(replacement.pairedRows == knownRows)
            replacement.start()
            #expect(!replacement.isLoading)
            #expect(await waitFor { replacement.snapshot?.generation == fresh.generation })
            #expect(replacement.pairedRows.first?.groupIdHex == "0040")
            store.activeAccountRef = "another-account"
            store.activeAccountRef = "synthetic-account"
            #expect(model.pairedRows.isEmpty)
            #expect(replacement.pairedRows.isEmpty)
            #expect(retained.retired)
            #expect(try store.automaticListContinuity() !== retained)
        }

        @Test func inactiveListObserverCannotBeReusedAfterForegroundReturns() async {
            let current = MainActorTestFlag(true)
            let original = PagingList(page(sequence: 1, start: 0, cursor: nil))
            let model = AccountChatListViewModel(
                accountRef: "synthetic-account", runtime: PagingFactory(original: original),
                isPresentationCurrent: { true }, isCurrent: { current.value })
            model.start()
            defer { model.invalidate() }
            #expect(await waitFor { original.hasUpdateWaiter })
            current.value = false
            original.cancel()
            #expect(await waitFor { model.retired })
            current.value = true
            #expect(!model.isCurrentOwner)
            #expect(model.pairedRows.count == 64)
        }

        @Test func pagePublishedByOriginalStreamBeforeReplyStillRetainsBackCursor() async {
            let (model, original) = await ready()
            defer { model.invalidate() }
            let loading = Task { await model.loadMorePaired() }
            #expect(await waitFor { original.callCount == 1 })
            let replacement = page(sequence: 2, start: 64, cursor: "007f")
            original.emit(replacement)
            #expect(await waitFor { model.snapshot?.sequence == 2 })
            original.finishPage(replacement)
            await loading.value
            #expect(model.hasPreviousPairedPage)
            let back = Task { await model.loadPreviousPaired() }
            #expect(await waitFor { original.callCount == 2 })
            #expect(original.lastCursor == nil)
            original.finishPage(page(sequence: 3, start: 0, cursor: "003f"))
            await back.value
            #expect(model.pairedRows.first?.groupIdHex == "0000")
        }

        @Test func latePageCannotRestoreRetiredAccount() async {
            let (model, original) = await ready()
            await model.pairedUserScrollChanged(true)
            let loading = Task { await model.pairedBoundaryVisibilityChanged(true) }
            #expect(await waitFor { original.callCount == 1 })
            model.invalidate()
            original.finishPage(page(sequence: 2, start: 64, cursor: "007f"))
            await loading.value
            #expect(model.snapshot == nil)
            #expect(model.pairedRows.isEmpty)
            await model.pairedBoundaryVisibilityChanged(false)
            await model.pairedBoundaryVisibilityChanged(true)
            #expect(original.callCount == 1)
        }

        @Test func earlierPageReplyCannotDiscardNewerOriginalObservation() async {
            let (model, original) = await ready()
            defer { model.invalidate() }
            await model.pairedUserScrollChanged(true)
            let loading = Task { await model.pairedBoundaryVisibilityChanged(true) }
            #expect(await waitFor { original.callCount == 1 })
            original.emit(page(sequence: 3, start: 192, cursor: nil))
            #expect(await waitFor { model.snapshot?.sequence == 3 })
            original.finishPage(page(sequence: 2, start: 64, cursor: "007f"))
            await loading.value
            #expect(model.snapshot?.sequence == 3)
            #expect(model.pairedRows.first?.groupIdHex == "00c0")
            #expect(model.error == nil)
        }
    }
#endif
