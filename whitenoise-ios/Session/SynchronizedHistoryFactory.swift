#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation

    @MainActor extension AppState {
        func makeSynchronizedHistoryModel(
            groupIdHex: String, read: SynchronizedHistoryViewModel.Reader? = nil
        ) throws -> SynchronizedHistoryViewModel {
            guard let client, let account = activeAccountRef, let generation = runtimeEventsGeneration,
                isAppSceneActive, !isAccountExitInProgress, !isErasingAppData
            else { throw SynchronizedHistoryReadError.unavailable }
            let epoch = accountStore.deviceLinkingOwnershipIdentity
            let current: @MainActor () -> Bool = { [weak self, weak client] in
                guard let self, let client else { return false }
                return self.client === client && self.runtimeEventsGeneration == generation
                    && self.activeAccountRef == account && self.accountStore.deviceLinkingOwnershipIdentity == epoch
                    && self.isAppSceneActive && !self.isAccountExitInProgress && !self.isErasingAppData
            }
            if let held = accountStore.synchronizedHistoryModels[groupIdHex], held.isCurrentOwner { return held }
            let model = SynchronizedHistoryViewModel(
                accountRef: account, groupIdHex: groupIdHex, isCurrent: current,
                read: read ?? { [client] account, group, cursor, limit in
                    try await client.synchronizedHistoryPage(
                        accountRef: account, groupIdHex: group, afterMessageIdHex: cursor, limit: limit)
                })
            accountStore.holdSynchronizedHistory(model, groupIdHex: groupIdHex)
            return model
        }

        func releaseSynchronizedHistoryModel(_ model: SynchronizedHistoryViewModel, groupIdHex: String) {
            accountStore.releaseSynchronizedHistory(model, groupIdHex: groupIdHex)
        }
    }
#endif
