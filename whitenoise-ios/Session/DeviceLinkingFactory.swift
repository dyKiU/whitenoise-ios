#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit

    @MainActor
    extension AppState {
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
