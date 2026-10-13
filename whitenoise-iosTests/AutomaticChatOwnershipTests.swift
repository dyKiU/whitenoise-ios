import Foundation
import MarmotKit
import Synchronization
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    nonisolated private final class DelayedAccountChatFactory: AccountChatObserving, Sendable {
        private let state = Mutex(State())
        nonisolated private struct State: Sendable {
            var pending: CheckedContinuation<any AccountChatListObserving, Error>?
        }
        var isWaiting: Bool { state.withLock { $0.pending != nil } }
        func openAccountChatList(accountRef: String, initialRows: UInt32) async throws -> any AccountChatListObserving {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.pending = continuation }
            }
        }
        func openAccountConversation(accountRef: String, groupIdHex: String, initialRows: UInt32) async throws
            -> any AccountConversationObserving
        {
            throw CancellationError()
        }
        func finish(_ original: any AccountChatListObserving) {
            let pending = state.withLock { state in
                let value = state.pending
                state.pending = nil
                return value
            }
            pending?.resume(returning: original)
        }
    }

    nonisolated private final class HeldAccountChatList: AccountChatListObserving, Sendable {
        private let state = Mutex(State())
        nonisolated private struct State: Sendable {
            var cancels = 0
        }
        var cancelCount: Int { state.withLock { $0.cancels } }
        func snapshot() -> AccountChatListWindowSnapshotFfi? { nil }
        func next() async throws -> AccountChatListWindowSnapshotFfi? { nil }
        func pairedPage(sequence: UInt64, afterGroupIdHex: String?) async throws -> AccountChatListWindowSnapshotFfi {
            throw CancellationError()
        }
        func cancel() { state.withLock { $0.cancels += 1 } }
    }

    @MainActor @Suite struct AutomaticChatOwnershipTests {
        private func waitFor(_ predicate: () -> Bool) async -> Bool {
            for _ in 0..<200 {
                if predicate() { return true }
                await Task.yield()
            }
            return predicate()
        }

        @Test func cancelledFactoryRetiresExactLateOriginalWithoutPublishing() async {
            let factory = DelayedAccountChatFactory()
            let model = AccountChatListViewModel(accountRef: "synthetic-account", runtime: factory, isCurrent: { true })
            model.start()
            #expect(await waitFor { factory.isWaiting })
            model.invalidate()
            let original = HeldAccountChatList()
            factory.finish(original)
            #expect(await waitFor { original.cancelCount == 1 })
            #expect(model.snapshot == nil)
            #expect(model.pairedRows.isEmpty)
            #expect(!model.isLoading)
        }

        @Test func sameAccountReplacementCannotReceiveOldFactoryResult() async {
            let oldFactory = DelayedAccountChatFactory()
            let old = AccountChatListViewModel(
                accountRef: "synthetic-account", runtime: oldFactory, isCurrent: { true })
            old.start()
            #expect(await waitFor { oldFactory.isWaiting })
            old.invalidate()
            let replacementFactory = DelayedAccountChatFactory()
            let replacement = AccountChatListViewModel(
                accountRef: "synthetic-account", runtime: replacementFactory, isCurrent: { true })
            replacement.start()
            #expect(await waitFor { replacementFactory.isWaiting })
            let original = HeldAccountChatList()
            oldFactory.finish(original)
            #expect(await waitFor { original.cancelCount == 1 })
            #expect(old.snapshot == nil)
            #expect(replacement.snapshot == nil)
            replacement.invalidate()
            let lateReplacement = HeldAccountChatList()
            replacementFactory.finish(lateReplacement)
            #expect(await waitFor { lateReplacement.cancelCount == 1 })
        }
    }
#endif
