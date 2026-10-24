#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit

    @MainActor extension AppState {
        func beginOwnedSelectedChatCopy(groupIdHex: String, linkedRosterSelector: Data) async throws
            -> SelectedChatCopyScope
        {
            try await adoptSelectedChatCopyFactory { client, ref in
                try await client.beginSelectedChatCopy(
                    accountRef: ref, groupIdHex: groupIdHex, linkedRosterSelector: linkedRosterSelector)
            }
        }
        func receiveOwnedSelectedChatCopyRequest(packet: Data) async throws -> SelectedChatConsentScope {
            try await adoptSelectedChatConsentFactory { client, ref in
                try await client.receiveSelectedChatCopyRequest(accountRef: ref, packet: packet)
            }
        }
        func makeSelectedChatTransferViewModel() throws -> SelectedChatTransferViewModel {
            guard let client, let ref = activeAccountRef, let generation = runtimeEventsGeneration,
                isAppSceneActive, !isAccountExitInProgress, !isErasingAppData
            else { throw MarmotKitError.SelectedChatCopyClosed }
            let epoch = accountStore.deviceLinkingOwnershipIdentity
            let current: @MainActor () -> Bool = { [weak self, weak client] in
                guard let self, let client else { return false }
                return self.client === client && self.runtimeEventsGeneration == generation
                    && self.activeAccountRef == ref && self.accountStore.deviceLinkingOwnershipIdentity == epoch
                    && self.isAppSceneActive && !self.isAccountExitInProgress && !self.isErasingAppData
            }
            if let held = accountStore.selectedChatTransferModel, held.isActive { return held }
            let model = SelectedChatTransferViewModel(
                begin: { [weak self] group, target in
                    guard let self, current() else { throw MarmotKitError.SelectedChatCopyClosed }
                    return try await self.beginSelectedChatCopyPresentation(
                        groupIdHex: group, linkedRosterSelector: target)
                },
                receive: { [weak self] packet in
                    guard let self, current() else { throw MarmotKitError.SelectedChatCopyClosed }
                    return try await self.receiveSelectedChatConsentPresentation(packet: packet)
                },
                targets: { [weak client] in
                    guard let client, current() else { throw MarmotKitError.SelectedChatCopyClosed }
                    return try await client.deviceLinkingTargets(accountRef: ref)
                }, isCurrent: current)
            accountStore.selectedChatTransferModel = model
            return model
        }
        func beginSelectedChatCopyPresentation(groupIdHex: String, linkedRosterSelector: Data) async throws
            -> SelectedChatCopyViewModel
        {
            let scope = try await beginOwnedSelectedChatCopy(
                groupIdHex: groupIdHex, linkedRosterSelector: linkedRosterSelector)
            return SelectedChatCopyViewModel(original: scope, isCurrent: { scope.isActive })
        }
        func receiveSelectedChatConsentPresentation(packet: Data) async throws -> SelectedChatConsentViewModel {
            let scope = try await receiveOwnedSelectedChatCopyRequest(packet: packet)
            return SelectedChatConsentViewModel(original: scope, isCurrent: { scope.isActive })
        }
        private func selectedChatOwner() async throws -> SelectedChatAccountOwner {
            guard let client, let ref = activeAccountRef, let generation = runtimeEventsGeneration,
                isAppSceneActive, !isAccountExitInProgress, !isErasingAppData
            else {
                throw MarmotKitError.SelectedChatCopyClosed
            }
            let epoch = accountStore.deviceLinkingOwnershipIdentity
            let current: @MainActor () -> Bool = { [weak self, weak client] in
                guard let self, let client else { return false }
                return self.client === client && self.runtimeEventsGeneration == generation
                    && self.activeAccountRef == ref && self.accountStore.deviceLinkingOwnershipIdentity == epoch
                    && self.isAppSceneActive && !self.isAccountExitInProgress && !self.isErasingAppData
            }
            try await accountStore.prepareSelectedChatAcquisition()
            return try accountStore.selectedChatLifetime.currentOwner(
                accountRef: ref, client: client, isCurrent: current)
        }
        /// The factory returns one exact original SDK handle; no display selector can adopt it.
        func adoptSelectedChatCopyFactory(
            _ factory: @escaping @MainActor (MarmotClient, String) async throws -> any SelectedChatCopyProtocol
        ) async throws -> SelectedChatCopyScope {
            let owner = try await selectedChatOwner()
            return try await owner.adoptCopy(factory)
        }
        func adoptSelectedChatConsentFactory(
            _ factory: @escaping @MainActor (MarmotClient, String) async throws -> any SelectedChatConsentProtocol
        ) async throws -> SelectedChatConsentScope {
            let owner = try await selectedChatOwner()
            return try await owner.adoptConsent(factory)
        }
    }
#endif
