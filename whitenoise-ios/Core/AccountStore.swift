import Foundation
import MarmotKit

/// Owns the local account list and the active-account selection. A self-contained
/// observable data store: `activeAccountRef` persists to UserDefaults via its own
/// `didSet`, and `activeAccount` resolves purely from the list — so the store
/// needs no `AppState` back-reference. AppState performs the Marmot fetch that
/// refreshes `accounts` (client access is its domain) and orchestrates the
/// identity lifecycle (create / import / sign-out).
@MainActor
@Observable
final class AccountStore {
    static let activeAccountKey = "marmot.activeAccountRef"
    private static let profileSelectionKey = "marmot.chooseProfileAfterSignOut"
    private(set) var prefersProfileSelection: Bool
    private(set) var returnsToSettingsAfterSelection = false

    @ObservationIgnored private let defaults: UserDefaults

    /// All accounts known to marmot-app, refreshed after every account-changing call.
    var accounts: [AccountSummaryFfi] = []

    /// The account whose chats / messages are currently displayed.
    /// `nil` during onboarding or while choosing a profile. Restored from and
    /// persisted to UserDefaults so the selection survives relaunch.
    var activeAccountRef: String? {
        didSet {
            #if WN_EXPERIMENTAL_DEVICE_SYNC
                if oldValue != activeAccountRef { retireDeviceLinkingScope() }
            #endif
            if let ref = activeAccountRef {
                returnsToSettingsAfterSelection = false
                prefersProfileSelection = false
                defaults.removeObject(forKey: Self.profileSelectionKey)
                defaults.set(ref, forKey: Self.activeAccountKey)
            } else {
                // Clearing the ref (e.g. signing out of the only account) must
                // remove the persisted value, otherwise the next launch
                // resurrects the signed-out account from UserDefaults.
                defaults.removeObject(forKey: Self.activeAccountKey)
            }
        }
    }

    #if WN_EXPERIMENTAL_DEVICE_SYNC
        private(set) var synchronizedHistoryModels: [String: SynchronizedHistoryViewModel] = [:]

        func holdSynchronizedHistory(_ model: SynchronizedHistoryViewModel, groupIdHex: String) {
            synchronizedHistoryModels[groupIdHex]?.invalidate()
            synchronizedHistoryModels[groupIdHex] = model
        }

        func releaseSynchronizedHistory(_ model: SynchronizedHistoryViewModel, groupIdHex: String) {
            guard synchronizedHistoryModels[groupIdHex] === model else { return }
            model.invalidate()
            synchronizedHistoryModels.removeValue(forKey: groupIdHex)
        }

        let selectedChatLifetime = SelectedChatAccountLifetime()
        var selectedChatTransferModel: SelectedChatTransferViewModel?

        private(set) var deviceLinkingScope: DeviceLinkingAccountScope?
        private(set) var retiringDeviceLinkingScope: DeviceLinkingAccountScope?
        @ObservationIgnored private var deviceLinkingRetirement: Task<Void, Error>?
        // Observable negative identity resets display across A→B→A and runtime retirement.
        private var deviceLinkingOwnerEpoch = UUID()
        var deviceLinkingOwnershipIdentity: UUID { deviceLinkingOwnerEpoch }
        @ObservationIgnored private var pendingDeviceLinkingFactory:
            (
                id: UUID, task: Task<any DeviceLinkingSessionProtocol, Error>
            )?

        private(set) var deviceLinkingApprovalScope: DeviceLinkingApprovalScope?
        private var retiringApprovalScopes: [DeviceLinkingApprovalScope] = []
        var retiringDeviceLinkingApprovalScope: DeviceLinkingApprovalScope? { retiringApprovalScopes.first }
        // SDK e6 returns at most128 original handles. Refusal must not Drop/cancel a batch.
        private var unselectedApprovalScopes: [DeviceLinkingApprovalScope] = []
        @ObservationIgnored private var pendingApprovalFactory:
            (id: UUID, task: Task<[any DeviceLinkingApprovalProtocol], Error>)?
        @ObservationIgnored private var approvalRetirement: Task<Void, Error>?

        private(set) var deviceEnrollmentModel: DeviceEnrollmentViewModel?
        private(set) var deviceEnrollmentApprovalModel: DeviceEnrollmentApprovalViewModel?
        func installDeviceEnrollment(_ model: DeviceEnrollmentViewModel) {
            deviceEnrollmentModel?.invalidate()
            deviceEnrollmentModel = model
        }
        func installDeviceEnrollmentApproval(_ model: DeviceEnrollmentApprovalViewModel) {
            deviceEnrollmentApprovalModel?.invalidate()
            deviceEnrollmentApprovalModel = model
        }

        func adoptDeviceLinkingApprovalFactory(
            accountRef: String,
            isRuntimeCurrent: @MainActor () -> Bool,
            factory: @escaping @MainActor () async throws -> any DeviceLinkingApprovalProtocol
        ) async throws -> DeviceLinkingApprovalScope {
            try await adoptDeviceLinkingApprovalBatch(
                accountRef: accountRef, isRuntimeCurrent: isRuntimeCurrent,
                factory: { [try await factory()] }
            )
        }

        func adoptDeviceLinkingApprovalBatch(
            accountRef: String,
            isRuntimeCurrent: @MainActor () -> Bool,
            factory: @escaping @MainActor () async throws -> [any DeviceLinkingApprovalProtocol]
        ) async throws -> DeviceLinkingApprovalScope {
            guard activeAccountRef == accountRef, isRuntimeCurrent(), pendingApprovalFactory == nil else {
                throw CancellationError()
            }
            let epoch = deviceLinkingOwnerEpoch
            try await retryDeviceLinkingCleanup()
            guard !Task.isCancelled, epoch == deviceLinkingOwnerEpoch, activeAccountRef == accountRef,
                isRuntimeCurrent(), pendingApprovalFactory == nil
            else { throw CancellationError() }
            if let held = deviceLinkingApprovalScope {
                let snapshot = try await held.snapshot()
                guard epoch == deviceLinkingOwnerEpoch, deviceLinkingApprovalScope === held, isRuntimeCurrent() else {
                    throw CancellationError()
                }
                switch snapshot.phase {
                case .awaitingApproval, .approvedAwaitingPacket, .awaitingSettlement: return held
                case .settled, .cancelled, .expired: throw MarmotKitError.DeviceLinkingClosed
                }
            }
            guard unselectedApprovalScopes.isEmpty else { throw MarmotKitError.DeviceLinkingNotReady }
            let id = UUID()
            let task = Task {
                try Task.checkCancellation()
                return try await factory()
            }
            pendingApprovalFactory = (id, task)
            defer { if pendingApprovalFactory?.id == id { pendingApprovalFactory = nil } }
            let originals = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            let scopes = originals.map { DeviceLinkingApprovalScope(accountRef: accountRef, approval: $0) }
            guard !Task.isCancelled, epoch == deviceLinkingOwnerEpoch, activeAccountRef == accountRef,
                isRuntimeCurrent()
            else {
                for scope in scopes { scope.invalidate() }
                retiringApprovalScopes.append(contentsOf: scopes)
                try await cancelRetiringApprovalScopes()
                throw CancellationError()
            }
            guard scopes.count == 1, let scope = scopes.first else {
                // Do not choose among or silently Drop the SDK's bounded original batch.
                unselectedApprovalScopes = scopes
                throw MarmotKitError.DeviceLinkingNotReady
            }
            deviceLinkingApprovalScope = scope
            return scope
        }

        private func retireDeviceLinkingApprovalScopes() {
            pendingApprovalFactory?.task.cancel()
            var scopes = unselectedApprovalScopes
            unselectedApprovalScopes = []
            if let scope = deviceLinkingApprovalScope { scopes.append(scope) }
            deviceLinkingApprovalScope = nil
            for scope in scopes { scope.invalidate() }
            retiringApprovalScopes.append(contentsOf: scopes)
            if !scopes.isEmpty {
                approvalRetirement = Task { try await self.cancelRetiringApprovalScopes() }
            }
        }

        private func retryApprovalCleanup() async throws {
            do {
                if let retirement = approvalRetirement {
                    try await retirement.value
                } else {
                    try await cancelRetiringApprovalScopes()
                }
                approvalRetirement = nil
            } catch {
                approvalRetirement = nil
                throw error
            }
        }

        private func cancelRetiringApprovalScopes() async throws {
            var firstError: Error?
            for scope in retiringApprovalScopes {
                do {
                    try await scope.cancel()
                    retiringApprovalScopes.removeAll { $0 === scope }
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            if let firstError { throw firstError }
        }

        func adoptDeviceLinkingFactory(
            accountRef: String,
            isRuntimeCurrent: @MainActor () -> Bool,
            factory: @escaping @MainActor () async throws -> any DeviceLinkingSessionProtocol
        ) async throws -> DeviceLinkingAccountScope {
            guard activeAccountRef == accountRef, isRuntimeCurrent(), pendingDeviceLinkingFactory == nil,
                deviceLinkingScope == nil
            else { throw CancellationError() }
            let ownerEpoch = deviceLinkingOwnerEpoch
            try await retryDeviceLinkingCleanup()
            guard !Task.isCancelled, activeAccountRef == accountRef, ownerEpoch == deviceLinkingOwnerEpoch,
                isRuntimeCurrent(), pendingDeviceLinkingFactory == nil, deviceLinkingScope == nil
            else { throw CancellationError() }
            let id = UUID()
            let task = Task {
                try Task.checkCancellation()
                return try await factory()
            }
            pendingDeviceLinkingFactory = (id, task)
            defer {
                if pendingDeviceLinkingFactory?.id == id { pendingDeviceLinkingFactory = nil }
            }
            let session = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            let scope = DeviceLinkingAccountScope(accountRef: accountRef, session: session)
            guard !Task.isCancelled, ownerEpoch == deviceLinkingOwnerEpoch, activeAccountRef == accountRef,
                isRuntimeCurrent()
            else {
                // Never adopt a late original result. Keep failed exact cleanup retryable.
                scope.invalidate()
                retiringDeviceLinkingScope = scope
                deviceLinkingRetirement = Task { try await scope.cancel() }
                try await cancelRetiringDeviceLinkingScope()
                throw CancellationError()
            }
            deviceLinkingScope = scope
            return scope
        }

        func holdDeviceLinkingSession(
            _ session: any DeviceLinkingSessionProtocol, accountRef: String
        ) async throws -> DeviceLinkingAccountScope {
            guard activeAccountRef == accountRef, pendingDeviceLinkingFactory == nil else { throw CancellationError() }
            try await retryDeviceLinkingCleanup()
            guard !Task.isCancelled, activeAccountRef == accountRef, deviceLinkingScope == nil,
                pendingDeviceLinkingFactory == nil
            else {
                throw CancellationError()
            }
            let scope = DeviceLinkingAccountScope(accountRef: accountRef, session: session)
            deviceLinkingScope = scope
            return scope
        }

        private func retireDeviceLinkingScope() {
            // Synchronous negative epoch also fences A→B→A and factories not yet returned.
            deviceLinkingOwnerEpoch = UUID()
            for reader in synchronizedHistoryModels.values { reader.invalidate() }
            synchronizedHistoryModels.removeAll()
            selectedChatLifetime.invalidate()
            selectedChatTransferModel?.invalidate()
            selectedChatTransferModel = nil
            deviceEnrollmentModel?.invalidate()
            deviceEnrollmentModel = nil
            deviceEnrollmentApprovalModel?.invalidate()
            deviceEnrollmentApprovalModel = nil
            pendingDeviceLinkingFactory?.task.cancel()
            retireDeviceLinkingApprovalScopes()
            guard let scope = deviceLinkingScope else { return }
            scope.invalidate()
            deviceLinkingScope = nil
            retiringDeviceLinkingScope = scope
            deviceLinkingRetirement = Task { try await scope.cancel() }
        }

        func cancelDeviceLinking() async throws {
            retireDeviceLinkingScope()
            try await retryDeviceLinkingCleanup()
        }

        func retryDeviceLinkingCleanup(for original: DeviceLinkingAccountScope) async throws {
            guard retiringDeviceLinkingScope === original else { throw MarmotKitError.DeviceLinkingClosed }
            try await retryDeviceLinkingCleanup()
        }

        func retryDeviceLinkingCleanup(for original: DeviceLinkingApprovalScope) async throws {
            guard retiringApprovalScopes.contains(where: { $0 === original }) else {
                throw MarmotKitError.DeviceLinkingClosed
            }
            try await retryDeviceLinkingCleanup()
        }

        private func retryDeviceLinkingCleanup() async throws {
            // Every original owner is attempted; a failed owner blocks either factory.
            var firstError: Error?
            do { try await cancelRetiringDeviceLinkingScope() } catch { firstError = error }
            do { try await retryApprovalCleanup() } catch {
                if firstError == nil { firstError = error }
            }
            do { try await selectedChatLifetime.retryCleanup() } catch {
                if firstError == nil { firstError = error }
            }
            if let firstError { throw firstError }
        }

        func prepareSelectedChatAcquisition() async throws { try await retryDeviceLinkingCleanup() }
        func retrySelectedChatCleanup() async throws { try await selectedChatLifetime.retryCleanup() }

        private func cancelRetiringDeviceLinkingScope() async throws {
            guard let scope = retiringDeviceLinkingScope else { return }
            do {
                if let retirement = deviceLinkingRetirement {
                    try await retirement.value
                } else {
                    try await scope.cancel()
                }
                if retiringDeviceLinkingScope === scope {
                    retiringDeviceLinkingScope = nil
                    deviceLinkingRetirement = nil
                }
            } catch {
                if retiringDeviceLinkingScope === scope { deviceLinkingRetirement = nil }
                throw error
            }
        }
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.prefersProfileSelection = defaults.bool(forKey: Self.profileSelectionKey)
        self.activeAccountRef = defaults.string(forKey: Self.activeAccountKey)
    }

    func requestProfileSelection() {
        returnsToSettingsAfterSelection = true
        prefersProfileSelection = true
        defaults.set(true, forKey: Self.profileSelectionKey)
        activeAccountRef = nil
    }

    func resetSelection() {
        returnsToSettingsAfterSelection = false
        activeAccountRef = nil
        prefersProfileSelection = false
        defaults.removeObject(forKey: Self.profileSelectionKey)
    }

    /// The active account summary resolved from the list, or nil.
    var activeAccount: AccountSummaryFfi? {
        guard let ref = activeAccountRef else { return nil }
        return accounts.first { $0.label == ref }
    }
}
