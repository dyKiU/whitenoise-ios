#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit

    @MainActor extension AppState {
        func makeHistoryConsentReviewModel(
            readPending: (@MainActor () async throws -> [NativeHistoryConsentScope])? = nil
        ) throws -> HistoryConsentReviewModel {
            guard let client, let account = activeAccountRef, let generation = runtimeEventsGeneration,
                isAppSceneActive, !isAccountExitInProgress, !isErasingAppData
            else { throw MarmotKitError.HistoryTransferClosed }
            let epoch = accountStore.deviceLinkingOwnershipIdentity
            let current: @MainActor () -> Bool = { [weak self, weak client] in
                guard let self, let client else { return false }
                return self.client === client && self.runtimeEventsGeneration == generation
                    && self.activeAccountRef == account && self.accountStore.deviceLinkingOwnershipIdentity == epoch
                    && self.isAppSceneActive && !self.isAccountExitInProgress && !self.isErasingAppData
            }
            if let held = accountStore.historyConsentReviewModel, held.isActive { return held }
            let model = HistoryConsentReviewModel(
                loadOriginals: { [weak self] in
                    guard let self, current() else { throw MarmotKitError.HistoryTransferClosed }
                    if let readPending { return try await readPending() }
                    return try await self.pendingOwnedHistoryConsents()
                }, isCurrent: current)
            accountStore.holdHistoryConsentReview(model)
            return model
        }

        func pendingOwnedHistoryConsents() async throws -> [NativeHistoryConsentScope] {
            try await adoptHistoryConsentBatch { client, account in
                try await client.pendingHistoryRequests(accountRef: account)
            }
        }
        /// Only actual returned originals enter custody; injected factories support lifetime tests.
        func adoptHistoryConsentBatch(
            _ factory: @escaping @MainActor (MarmotClient, String) async throws -> [any HistoryConsentProtocol]
        ) async throws -> [NativeHistoryConsentScope] {
            guard let client, let account = activeAccountRef, let generation = runtimeEventsGeneration,
                isAppSceneActive, !isAccountExitInProgress, !isErasingAppData
            else { throw MarmotKitError.HistoryTransferClosed }
            let epoch = accountStore.deviceLinkingOwnershipIdentity
            let current: @MainActor () -> Bool = { [weak self, weak client] in
                guard let self, let client else { return false }
                return self.client === client && self.runtimeEventsGeneration == generation
                    && self.activeAccountRef == account && self.accountStore.deviceLinkingOwnershipIdentity == epoch
                    && self.isAppSceneActive && !self.isAccountExitInProgress && !self.isErasingAppData
            }
            try await accountStore.prepareHistoryConsentAcquisition()
            let owner = try accountStore.historyConsentLifetime.currentOwner(
                accountRef: account, client: client, isCurrent: current)
            return try await owner.pendingConsents(factory)
        }
    }
#endif
