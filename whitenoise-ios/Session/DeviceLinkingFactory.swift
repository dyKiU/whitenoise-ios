#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit

    @MainActor
    extension AppState {
        func makeDeviceVerificationViewModel() -> DeviceVerificationViewModel {
            let client = self.client
            let generation = runtimeEventsGeneration
            let accountRef = activeAccountRef
            let ticket = accountStore.deviceLinkingOwnershipIdentity
            let current: @MainActor () -> Bool = { [weak self, weak client] in
                guard let self, let client, generation != nil, accountRef != nil else { return false }
                return self.client === client && self.runtimeEventsGeneration == generation
                    && self.accountStore.deviceLinkingOwnershipIdentity == ticket
                    && self.activeAccountRef == accountRef && self.isAppSceneActive
                    && !self.isAccountExitInProgress && !self.isErasingAppData
            }
            return DeviceVerificationViewModel(
                owner: accountStore.deviceLinkingScope,
                isCurrent: current,
                begin: { [weak self] in
                    guard let self, current() else { throw CancellationError() }
                    return try await self.beginOwnedDeviceLinkingSession()
                },
                cancel: { [weak self] in
                    guard let self, current() else { throw CancellationError() }
                    try await self.accountStore.cancelDeviceLinking()
                },
                cleanupFailure: { [weak self] in self?.accountStore.retiringDeviceLinkingScope?.cleanupError != nil },
                approve: { [weak self] request, target in
                    guard let self, current() else { throw CancellationError() }
                    return try await self.approveOwnedDeviceLinkingSession(request: request, target: target)
                },
                targets: { [weak client] in
                    guard let client, let accountRef, current() else { throw CancellationError() }
                    return try await client.deviceLinkingTargets(accountRef: accountRef)
                },
                verificationSupported: client?.deviceLinkingCapabilities().verificationSupported ?? false
            )
        }

        func beginOwnedDeviceLinkingSession() async throws -> DeviceLinkingAccountScope {
            try await adoptDeviceLinkingFactory { client, accountRef in
                try await client.beginDeviceLinkingSession(accountRef: accountRef)
            }
        }

        func approveOwnedDeviceLinkingSession(request: Data, target: Data?) async throws -> DeviceLinkingAccountScope {
            try await adoptDeviceLinkingFactory { client, accountRef in
                try await client.approveDeviceLinkingSession(accountRef: accountRef, request: request, target: target)
            }
        }

        /// Internal factory seam keeps the actual SDK object; test factories only delay its return.
        func adoptDeviceLinkingFactory(
            _ factory: @escaping @MainActor (MarmotClient, String) async throws -> any DeviceLinkingSessionProtocol
        ) async throws -> DeviceLinkingAccountScope {
            guard let client, let accountRef = activeAccountRef, let generation = runtimeEventsGeneration,
                isAppSceneActive, !isAccountExitInProgress, !isErasingAppData
            else { throw CancellationError() }
            return try await accountStore.adoptDeviceLinkingFactory(
                accountRef: accountRef,
                isRuntimeCurrent: {
                    self.client === client && self.runtimeEventsGeneration == generation
                        && self.isAppSceneActive && !self.isAccountExitInProgress && !self.isErasingAppData
                },
                factory: { try await factory(client, accountRef) }
            )
        }
    }
#endif
