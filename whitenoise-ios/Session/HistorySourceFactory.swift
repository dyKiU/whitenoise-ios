#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit

    @MainActor extension AppState {
        func releaseHistorySourcePickerModel(_ model: HistorySourcePickerModel) {
            accountStore.historyConsentLifetime.releaseSourcePicker(model)
        }
        /// Current conversation context selects observations; a fresh SDK factory decides authority.
        func makeHistorySourcePickerModel(
            groupIdHex: String,
            readRecipients: (@MainActor () async throws -> [HistoryTransferRecipientFfi])? = nil,
            beginOriginal: (@MainActor (Data) async throws -> any HistoryTransferProtocol)? = nil
        ) async throws -> HistorySourcePickerModel {
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
            guard current() else { throw MarmotKitError.HistoryTransferClosed }
            let owner = try accountStore.historyConsentLifetime.currentOwner(
                accountRef: account, client: client, isCurrent: current)
            return try owner.sourcePicker(
                groupIdHex: groupIdHex,
                readRecipients: {
                    guard current() else { throw MarmotKitError.HistoryTransferClosed }
                    if let readRecipients { return try await readRecipients() }
                    return try await client.historyTransferRecipients(accountRef: account, groupIdHex: groupIdHex)
                },
                beginOriginal: { device in
                    guard current() else { throw MarmotKitError.HistoryTransferClosed }
                    if let beginOriginal { return try await beginOriginal(device) }
                    return try await client.beginHistoryTransfer(
                        accountRef: account, groupIdHex: groupIdHex, recipientDevice: device)
                })
        }
    }
#endif
