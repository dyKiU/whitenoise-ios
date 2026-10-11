import MarmotKit

#if WN_EXPERIMENTAL_DEVICE_SYNC
    /// Observation owners only. Neither a row nor this adapter grants MLS or media authority.
    nonisolated protocol AccountChatListObserving: AnyObject, Sendable {
        func snapshot() -> AccountChatListWindowSnapshotFfi?
        func next() async throws -> AccountChatListWindowSnapshotFfi?
        func pairedPage(sequence: UInt64, afterGroupIdHex: String?) async throws -> AccountChatListWindowSnapshotFfi
        func cancel()
    }

    nonisolated protocol AccountConversationObserving: AnyObject, Sendable {
        func snapshot() -> AccountConversationWindowSnapshotFfi?
        func next() async throws -> AccountConversationWindowSnapshotFfi?
        func olderPage(sequence: UInt64, before: PairedChatMessageCursorFfi?) async throws
            -> AccountConversationWindowSnapshotFfi
        func cancel()
    }

    nonisolated protocol AccountChatObserving: Sendable {
        func openAccountChatList(accountRef: String, initialRows: UInt32) async throws -> any AccountChatListObserving
        func openAccountConversation(accountRef: String, groupIdHex: String, initialRows: UInt32) async throws
            -> any AccountConversationObserving
    }

    nonisolated protocol AccountChatSending: Sendable {
        func sendTextWithClientToken(accountRef: String, groupIdHex: String, text: String, clientToken: String)
            async throws -> LocalSendAcceptanceFfi
        func replyWithClientToken(
            accountRef: String, groupIdHex: String, targetMessageId: String,
            text: String, clientToken: String
        ) async throws -> LocalSendAcceptanceFfi
        func localSendStatus(accountRef: String, groupIdHex: String, clientToken: String)
            async throws -> LocalSendStatusFfi?
    }

    extension MarmotClient: AccountChatSending {}

    /// Retains the exact generated native owner. The host never recreates it from metadata.
    private final class NativeAccountChatList: AccountChatListObserving {
        private let original: AccountChatListWindowSubscription
        init(_ original: AccountChatListWindowSubscription) { self.original = original }
        func snapshot() -> AccountChatListWindowSnapshotFfi? { original.snapshot() }
        func next() async throws -> AccountChatListWindowSnapshotFfi? { try await original.next() }
        func pairedPage(sequence: UInt64, afterGroupIdHex: String?) async throws -> AccountChatListWindowSnapshotFfi {
            try await original.pairedPage(sequence: sequence, afterGroupIdHex: afterGroupIdHex)
        }
        func cancel() { original.cancel() }
    }

    private final class NativeAccountConversation: AccountConversationObserving {
        private let original: AccountConversationWindowSubscription
        init(_ original: AccountConversationWindowSubscription) { self.original = original }
        func snapshot() -> AccountConversationWindowSnapshotFfi? { original.snapshot() }
        func next() async throws -> AccountConversationWindowSnapshotFfi? { try await original.next() }
        func olderPage(sequence: UInt64, before: PairedChatMessageCursorFfi?) async throws
            -> AccountConversationWindowSnapshotFfi
        {
            try await original.olderPage(sequence: sequence, before: before)
        }
        func cancel() { original.cancel() }
    }

    extension MarmotClient: AccountChatObserving {
        func openAccountChatList(accountRef: String, initialRows: UInt32) async throws -> any AccountChatListObserving {
            NativeAccountChatList(
                try await marmot.openAccountChatListWindow(accountRef: accountRef, initialRows: initialRows))
        }
        func openAccountConversation(accountRef: String, groupIdHex: String, initialRows: UInt32) async throws
            -> any AccountConversationObserving
        {
            NativeAccountConversation(
                try await marmot.openAccountConversationWindow(
                    accountRef: accountRef, groupIdHex: groupIdHex, initialRows: initialRows))
        }
    }
#endif
