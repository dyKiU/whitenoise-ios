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
                    try await self.accountStore.cancelDeviceLinking(preservingConversationState: true)
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
                verificationSupported: client?.deviceLinkingCapabilities().verificationSupported ?? false,
                enrollmentSupported: client?.deviceLinkingCapabilities().enrollmentSupported ?? false,
                enrollment: { [weak self] in
                    guard let self, current() else { throw MarmotKitError.DeviceLinkingClosed }
                    return try self.makeDeviceEnrollmentModel()
                },
                enrollmentApproval: { [weak self] in
                    guard let self, current() else { throw MarmotKitError.DeviceLinkingClosed }
                    return try await self.makeDeviceEnrollmentApprovalModel()
                }
            )
        }

        func makeDeviceEnrollmentModel() throws -> DeviceEnrollmentViewModel {
            guard let client, let accountRef = activeAccountRef, let generation = runtimeEventsGeneration,
                isAppSceneActive, !isAccountExitInProgress, !isErasingAppData,
                let original = accountStore.deviceLinkingScope
            else { throw MarmotKitError.DeviceLinkingNotReady }
            let ticket = accountStore.deviceLinkingOwnershipIdentity
            let current: @MainActor () -> Bool = { [weak self, weak client, weak original] in
                guard let self, let client, let original else { return false }
                return self.client === client && self.runtimeEventsGeneration == generation
                    && self.activeAccountRef == accountRef && self.isAppSceneActive
                    && !self.isAccountExitInProgress && !self.isErasingAppData
                    && self.accountStore.deviceLinkingOwnershipIdentity == ticket
                    && self.accountStore.deviceLinkingScope === original
            }
            if let held = accountStore.deviceEnrollmentModel, held.isActive { return held }
            let model = DeviceEnrollmentViewModel(
                original: original, isCurrent: current,
                cancel: { [weak self] in
                    guard let self else { throw MarmotKitError.DeviceLinkingClosed }
                    if current() {
                        try await self.accountStore.cancelDeviceLinking(preservingConversationState: true)
                    } else {
                        try await self.accountStore.retryDeviceLinkingCleanup(for: original)
                    }
                }, enrollmentSupported: client.deviceLinkingCapabilities().enrollmentSupported
            )
            accountStore.installDeviceEnrollment(model)
            return model
        }

        func makeDeviceEnrollmentApprovalModel() async throws -> DeviceEnrollmentApprovalViewModel {
            guard let client, let accountRef = activeAccountRef, let generation = runtimeEventsGeneration,
                isAppSceneActive, !isAccountExitInProgress, !isErasingAppData
            else { throw MarmotKitError.DeviceLinkingClosed }
            let ticket = accountStore.deviceLinkingOwnershipIdentity
            let original = try await pendingOwnedDeviceLinkingApproval()
            let current: @MainActor () -> Bool = { [weak self, weak client, weak original] in
                guard let self, let client, let original else { return false }
                return self.client === client && self.runtimeEventsGeneration == generation
                    && self.activeAccountRef == accountRef && self.isAppSceneActive
                    && !self.isAccountExitInProgress && !self.isErasingAppData
                    && self.accountStore.deviceLinkingOwnershipIdentity == ticket
                    && self.accountStore.deviceLinkingApprovalScope === original
            }
            guard current(), !Task.isCancelled else { throw MarmotKitError.DeviceLinkingClosed }
            if let held = accountStore.deviceEnrollmentApprovalModel, held.isActive { return held }
            let model = DeviceEnrollmentApprovalViewModel(original: original, isCurrent: current) { [weak self] in
                guard let self else { throw MarmotKitError.DeviceLinkingClosed }
                if current() {
                    try await self.accountStore.cancelDeviceLinking(preservingConversationState: true)
                } else {
                    try await self.accountStore.retryDeviceLinkingCleanup(for: original)
                }
            }
            accountStore.installDeviceEnrollmentApproval(model)
            return model
        }

        func beginOwnedDeviceLinkingSession() async throws -> DeviceLinkingAccountScope {
            let owner = try await adoptDeviceLinkingFactory { client, accountRef in
                try await client.beginDeviceLinkingSession(accountRef: accountRef)
            }
            do {
                try await owner.activateAutomaticPairing(displayBootstrap: true)
                return owner
            } catch {
                // Clear this adopted owner on activation failure; a retired
                // result must never cancel a different current account scope.
                if accountStore.deviceLinkingScope === owner {
                    try await accountStore.cancelDeviceLinking(preservingConversationState: true)
                } else {
                    try await owner.cancel()
                }
                throw error
            }
        }

        func approveOwnedDeviceLinkingSession(request: Data, target: Data?) async throws -> DeviceLinkingAccountScope {
            let owner = try await adoptDeviceLinkingFactory { client, accountRef in
                try await client.approveDeviceLinkingSession(accountRef: accountRef, request: request, target: target)
            }
            do {
                try await owner.activateAutomaticPairing(displayBootstrap: false)
                return owner
            } catch {
                // Clear this adopted owner on activation failure; a retired
                // result must never cancel a different current account scope.
                if accountStore.deviceLinkingScope === owner {
                    try await accountStore.cancelDeviceLinking(preservingConversationState: true)
                } else {
                    try await owner.cancel()
                }
                throw error
            }
        }

        func pendingOwnedDeviceLinkingApproval() async throws -> DeviceLinkingApprovalScope {
            guard let client, let accountRef = activeAccountRef, let generation = runtimeEventsGeneration,
                isAppSceneActive, !isAccountExitInProgress, !isErasingAppData
            else { throw CancellationError() }
            return try await accountStore.adoptDeviceLinkingApprovalBatch(
                accountRef: accountRef,
                isRuntimeCurrent: {
                    self.client === client && self.runtimeEventsGeneration == generation
                        && self.isAppSceneActive && !self.isAccountExitInProgress && !self.isErasingAppData
                },
                factory: { try await client.pendingDeviceLinkingApprovals(accountRef: accountRef) }
            )
        }

        /// Approval acquisition is separate from verification/session ownership.
        func adoptDeviceLinkingApprovalFactory(
            _ factory: @escaping @MainActor (MarmotClient, String) async throws -> any DeviceLinkingApprovalProtocol
        ) async throws -> DeviceLinkingApprovalScope {
            guard let client, let accountRef = activeAccountRef, let generation = runtimeEventsGeneration,
                isAppSceneActive, !isAccountExitInProgress, !isErasingAppData
            else { throw CancellationError() }
            return try await accountStore.adoptDeviceLinkingApprovalFactory(
                accountRef: accountRef,
                isRuntimeCurrent: {
                    self.client === client && self.runtimeEventsGeneration == generation
                        && self.isAppSceneActive && !self.isAccountExitInProgress && !self.isErasingAppData
                },
                factory: { try await factory(client, accountRef) }
            )
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
