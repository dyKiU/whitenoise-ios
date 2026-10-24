#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit

    @MainActor extension AppState {
        func makeAccountChatSharingModel() throws -> AccountChatSharingViewModel {
            guard let client, let account = activeAccountRef, let generation = runtimeEventsGeneration,
                isAppSceneActive, !isAccountExitInProgress, !isErasingAppData
            else { throw MarmotKitError.AccountSharingClosed }
            let epoch = accountStore.deviceLinkingOwnershipIdentity
            let current: @MainActor () -> Bool = { [weak self, weak client] in
                guard let self, let client else { return false }
                return self.client === client && self.runtimeEventsGeneration == generation
                    && self.activeAccountRef == account && self.accountStore.deviceLinkingOwnershipIdentity == epoch
                    && self.isAppSceneActive && !self.isAccountExitInProgress && !self.isErasingAppData
            }
            if let held = accountStore.accountChatSharingModel, held.isActive { return held }
            let model = AccountChatSharingViewModel(
                readTargets: { try await client.accountChatSharingTargets(accountRef: account) },
                begin: { [weak self] device in
                    guard let self, current() else { throw MarmotKitError.AccountSharingClosed }
                    try await self.accountStore.prepareHistoryConsentAcquisition()
                    let owner = try self.accountStore.accountSharingLifetime.currentOwner(isCurrent: current)
                    let values = try await owner.acquire(reuseHeld: false) {
                        [try await client.beginAccountChatSharing(accountRef: account, recipientDevice: device)]
                    }
                    guard let value = values.first, values.count == 1 else {
                        throw MarmotKitError.AccountSharingNotReady
                    }
                    return value
                },
                readPending: { [weak self] in
                    guard let self, current() else { throw MarmotKitError.AccountSharingClosed }
                    try await self.accountStore.prepareHistoryConsentAcquisition()
                    let owner = try self.accountStore.accountSharingLifetime.currentOwner(isCurrent: current)
                    return try await owner.acquire {
                        try await client.pendingAccountChatSharing(accountRef: account)
                    }
                }, isCurrent: current)
            accountStore.holdAccountChatSharing(model)
            return model
        }
    }
#endif
