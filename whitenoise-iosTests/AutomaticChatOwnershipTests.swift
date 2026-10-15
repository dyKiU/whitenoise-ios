import Foundation
import MarmotKit
import Synchronization
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    nonisolated private final class DelayedAccountChatFactory: AccountChatObserving, Sendable {
        nonisolated private struct State: Sendable {
            var pending: CheckedContinuation<any AccountChatListObserving, Error>?
        }
        private let state = Mutex(State())
        var isWaiting: Bool { state.withLock { $0.pending != nil } }
        func openAccountChatList(accountRef: String, initialRows: UInt32) async throws -> any AccountChatListObserving {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.pending = continuation }
            }
        }
        func openAccountConversation(accountRef: String, groupIdHex: String, initialRows: UInt32) async throws
            -> any AccountConversationObserving
        { throw CancellationError() }
        func finish(_ original: any AccountChatListObserving) {
            let pending = state.withLock { value in
                let pending = value.pending
                value.pending = nil
                return pending
            }
            pending?.resume(returning: original)
        }
    }

    nonisolated private final class HeldAccountChatList: AccountChatListObserving, Sendable {
        private let cancels = Mutex(0)
        var cancelCount: Int { cancels.withLock { $0 } }
        func snapshot() -> AccountChatListWindowSnapshotFfi? { nil }
        func next() async throws -> AccountChatListWindowSnapshotFfi? { nil }
        func pairedPage(sequence: UInt64, afterGroupIdHex: String?) async throws -> AccountChatListWindowSnapshotFfi {
            throw CancellationError()
        }
        func cancel() { cancels.withLock { $0 += 1 } }
    }

    @MainActor @Suite struct IOSAutomaticChatOwnershipTests {
        private func waitFor(_ predicate: () -> Bool) async -> Bool {
            for _ in 0..<200 {
                if predicate() { return true }
                await Task.yield()
            }
            return predicate()
        }

        @Test func cancelledFactoryRetiresExactLateOriginalWithoutPublishing() async {
            let factory = DelayedAccountChatFactory()
            let model = AccountChatListViewModel(accountRef: "synthetic-account", runtime: factory)
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
            let old = AccountChatListViewModel(accountRef: "synthetic-account", runtime: oldFactory)
            old.start()
            #expect(await waitFor { oldFactory.isWaiting })
            old.invalidate()
            let replacementFactory = DelayedAccountChatFactory()
            let replacement = AccountChatListViewModel(accountRef: "synthetic-account", runtime: replacementFactory)
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

        @Test func accountStoreRetiresAutomaticReadersBeforeAnotherProfileCanUseThem() async throws {
            let name = "automatic-chat-owner-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let store = AccountStore(defaults: defaults)
            store.activeAccountRef = "synthetic-account"
            let factory = DelayedAccountChatFactory()
            let model = AccountChatListViewModel(accountRef: "synthetic-account", runtime: factory)
            store.holdAutomaticChatList(model)
            model.start()
            #expect(await waitFor { factory.isWaiting })
            store.activeAccountRef = "another-account"
            #expect(store.automaticChatListModel == nil)
            #expect(!model.isCurrentOwner)
            let original = HeldAccountChatList()
            factory.finish(original)
            #expect(await waitFor { original.cancelCount == 1 })
            #expect(model.snapshot == nil)
        }

        @Test func expiredRuntimeTicketCannotAdoptALateWindow() async {
            var current = true
            let factory = DelayedAccountChatFactory()
            let model = AccountChatListViewModel(
                accountRef: "synthetic-account", runtime: factory,
                isCurrent: { current })
            model.start()
            #expect(await waitFor { factory.isWaiting })
            current = false
            let original = HeldAccountChatList()
            factory.finish(original)
            #expect(await waitFor { original.cancelCount == 1 })
            #expect(!model.isCurrentOwner)
            #expect(model.pairedRows.isEmpty)
            model.invalidate()
        }

        @Test func inactiveRuntimeCannotStartAnotherNativeRead() async {
            let factory = DelayedAccountChatFactory()
            let model = AccountChatListViewModel(
                accountRef: "synthetic-account", runtime: factory,
                isCurrent: { false })
            model.start()
            #expect(!factory.isWaiting)
            #expect(!model.isLoading)
            #expect(model.snapshot == nil)
        }

    }
#endif
