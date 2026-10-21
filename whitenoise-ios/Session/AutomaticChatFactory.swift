#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation

    struct AutomaticChatOwner: Hashable {
        let accountRef: String?
        let generation: Int
        let epoch: UUID
        let ready: Bool
    }

    @MainActor extension AppState {
        var automaticChatOwner: AutomaticChatOwner {
            AutomaticChatOwner(
                accountRef: activeAccountRef, generation: runtimeGeneration,
                epoch: accountStore.deviceLinkingOwnershipIdentity,
                ready: runtimeEventsGeneration != nil && canUseRuntimeForForegroundWork && isAppSceneActive
                    && !isAccountExitInProgress && !isErasingAppData)
        }

        func makeAutomaticChatListModel() throws -> AccountChatListViewModel {
            let (client, account, current) = try automaticChatContext()
            if let held = accountStore.automaticChatListModel, held.isCurrentOwner { return held }
            let model = AccountChatListViewModel(accountRef: account, runtime: client, isCurrent: current)
            accountStore.holdAutomaticChatList(model)
            return model
        }

        func makeAutomaticConversationModel(groupIdHex: String) throws -> AccountConversationViewModel {
            let (client, account, current) = try automaticChatContext()
            if let held = accountStore.automaticConversationModels[groupIdHex], held.isCurrentOwner { return held }
            let continuity = try accountStore.automaticConversationContinuity(groupIdHex: groupIdHex)
            let model = AccountConversationViewModel(
                accountRef: account, groupIdHex: groupIdHex,
                runtime: client, observations: client, continuity: continuity,
                isPresentationCurrent: { [weak self] in
                    self?.activeAccountRef == account && self?.isAccountExitInProgress == false
                        && self?.isErasingAppData == false
                }, isCurrent: current)
            do { try accountStore.holdAutomaticConversation(model, groupIdHex: groupIdHex) } catch {
                model.suspend()
                throw error
            }
            return model
        }

        func releaseAutomaticConversationModel(_ model: AccountConversationViewModel, groupIdHex: String) {
            accountStore.releaseAutomaticConversation(model, groupIdHex: groupIdHex)
        }

        private func automaticChatContext() throws -> (MarmotClient, String, @MainActor () -> Bool) {
            guard let client, let account = activeAccountRef, let generation = runtimeEventsGeneration,
                canUseRuntimeForForegroundWork, isAppSceneActive, !isAccountExitInProgress, !isErasingAppData
            else { throw AutomaticChatPresentationError.unavailable }
            let epoch = accountStore.deviceLinkingOwnershipIdentity
            let current: @MainActor () -> Bool = { [weak self, weak client] in
                guard let self, let client else { return false }
                return self.client === client && self.runtimeEventsGeneration == generation
                    && self.activeAccountRef == account && self.accountStore.deviceLinkingOwnershipIdentity == epoch
                    && self.canUseRuntimeForForegroundWork && self.isAppSceneActive
                    && !self.isAccountExitInProgress && !self.isErasingAppData
            }
            return (client, account, current)
        }
    }
#endif
