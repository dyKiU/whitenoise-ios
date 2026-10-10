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
        private(set) var deviceLinkingScope: DeviceLinkingAccountScope?
        private(set) var retiringDeviceLinkingScope: DeviceLinkingAccountScope?
        @ObservationIgnored private var deviceLinkingRetirement: Task<Void, Error>?
        @ObservationIgnored private var deviceLinkingOwnerEpoch = UUID()
        @ObservationIgnored private var pendingDeviceLinkingFactory:
            (
                id: UUID, task: Task<any DeviceLinkingSessionProtocol, Error>
            )?

        func adoptDeviceLinkingFactory(
            accountRef: String,
            isRuntimeCurrent: @MainActor () -> Bool,
            factory: @escaping @MainActor () async throws -> any DeviceLinkingSessionProtocol
        ) async throws -> DeviceLinkingAccountScope {
            guard activeAccountRef == accountRef, isRuntimeCurrent(), pendingDeviceLinkingFactory == nil,
                deviceLinkingScope == nil
            else { throw CancellationError() }
            let ownerEpoch = deviceLinkingOwnerEpoch
            try await cancelRetiringDeviceLinkingScope()
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
            try await cancelRetiringDeviceLinkingScope()
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
            pendingDeviceLinkingFactory?.task.cancel()
            guard let scope = deviceLinkingScope else { return }
            scope.invalidate()
            deviceLinkingScope = nil
            retiringDeviceLinkingScope = scope
            deviceLinkingRetirement = Task { try await scope.cancel() }
        }

        func cancelDeviceLinking() async throws {
            retireDeviceLinkingScope()
            try await cancelRetiringDeviceLinkingScope()
        }

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
