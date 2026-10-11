import Foundation
import MarmotKit
import Observation

#if WN_EXPERIMENTAL_DEVICE_SYNC
    @MainActor
    @Observable
    final class AutomaticChatAccountOwner {
        let accountRef: String
        let list: AccountChatListViewModel
        private(set) var selectedConversation: AccountConversationViewModel?
        @ObservationIgnored private let client: MarmotClient
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        @ObservationIgnored private var retired = false

        init(accountRef: String, client: MarmotClient, isCurrent: @escaping @MainActor () -> Bool) {
            self.accountRef = accountRef
            self.client = client
            self.isCurrent = isCurrent
            self.list = AccountChatListViewModel(accountRef: accountRef, runtime: client, isCurrent: isCurrent)
        }

        var isLive: Bool { !retired && isCurrent() }

        func start() {
            guard !retired, isCurrent() else { return }
            list.start()
        }

        func selectConversation(groupIdHex: String) -> AccountConversationViewModel? {
            guard !retired, isCurrent() else { return nil }
            if let selectedConversation, selectedConversation.groupIdHex == groupIdHex {
                return selectedConversation
            }
            releaseConversation()
            let model = AccountConversationViewModel(
                accountRef: accountRef, groupIdHex: groupIdHex, runtime: client, observations: client,
                isCurrent: isCurrent)
            selectedConversation = model
            model.start()
            return model
        }

        func releaseConversation() {
            selectedConversation?.invalidate()
            selectedConversation = nil
        }

        func releaseConversation(_ model: AccountConversationViewModel) {
            guard selectedConversation === model else { return }
            releaseConversation()
        }

        func invalidate() {
            retired = true
            list.invalidate()
            releaseConversation()
        }
    }
#endif
