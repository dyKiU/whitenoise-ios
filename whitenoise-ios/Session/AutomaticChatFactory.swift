#if WN_EXPERIMENTAL_DEVICE_SYNC
    import MarmotKit

    @MainActor extension AppState {
        /// Captures account epoch and runtime generation; neither account strings nor rows are authority.
        func automaticChatOwner() -> AutomaticChatAccountOwner? {
            guard let client, let account = activeAccountRef, let generation = runtimeEventsGeneration,
                isAppSceneActive, !isAccountExitInProgress, !isErasingAppData
            else { return nil }
            if let held = accountStore.automaticChats, held.isLive { return held }
            let epoch = accountStore.deviceLinkingOwnershipIdentity
            let current: @MainActor () -> Bool = { [weak self, weak client] in
                guard let self, let client else { return false }
                return self.client === client && self.runtimeEventsGeneration == generation
                    && self.activeAccountRef == account && self.accountStore.deviceLinkingOwnershipIdentity == epoch
                    && self.isAppSceneActive && !self.isAccountExitInProgress && !self.isErasingAppData
            }
            let owner = AutomaticChatAccountOwner(accountRef: account, client: client, isCurrent: current)
            accountStore.holdAutomaticChats(owner)
            owner.start()
            return owner
        }
    }
#endif
