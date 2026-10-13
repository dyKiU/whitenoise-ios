#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    @MainActor @Observable final class NativeAccountSharingScope: AccountSharingReviewing {
        let id = UUID()
        private(set) var snapshot: AccountSharingSnapshotFfi?
        private var lastObserved: AccountSharingSnapshotFfi?
        @ObservationIgnored private let original: any AccountSharingOriginal
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        private var active = true
        var isActive: Bool { active && isCurrent() }

        init(original: any AccountSharingOriginal, isCurrent: @escaping @MainActor () -> Bool) {
            self.original = original
            self.isCurrent = isCurrent
        }
        private func checkActive() throws {
            try Task.checkCancellation()
            guard isActive else { throw MarmotKitError.AccountSharingClosed }
        }
        func refresh() throws {
            try checkActive()
            do {
                let value = try original.snapshot()
                try checkActive()
                guard value.sourceDevice.count == 32, value.recipientDevice.count == 32,
                    value.sourceDevice != value.recipientDevice, value.revision > 0,
                    !value.protectedGroupIdHex.isEmpty, value.protectedGroupIdHex.utf8.count <= 512,
                    value.protectedGroupIdHex.utf8.count.isMultiple(of: 2),
                    value.protectedGroupIdHex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                    !value.complete || value.approved
                else {
                    cancel()
                    throw MarmotKitError.AccountSharingNotReady
                }
                if let old = lastObserved {
                    guard value.protectedGroupIdHex == old.protectedGroupIdHex,
                        value.protectedEpoch == old.protectedEpoch, value.sourceDevice == old.sourceDevice,
                        value.recipientDevice == old.recipientDevice, value.revision >= old.revision,
                        !old.approved || value.approved, !old.complete || value.complete
                    else {
                        cancel()
                        throw MarmotKitError.AccountSharingNotReady
                    }
                }
                lastObserved = value
                snapshot = value
            } catch {
                snapshot = nil
                throw error
            }
        }
        func approve(displayedRevision: UInt64) async throws {
            try checkActive()
            guard snapshot?.revision == displayedRevision else { throw MarmotKitError.AccountSharingStaleRevision }
            try await original.approve(displayedRevision: displayedRevision)
            try checkActive()
            try refresh()
        }
        func cancel() {
            guard active else { return }
            active = false
            snapshot = nil
            original.cancel()
        }
    }

    /// A pending factory still owns its exact late result even after presentation retires.
    @MainActor final class AccountSharingAccountOwner {
        private let isCurrent: @MainActor () -> Bool
        private var active = true
        private var held: [NativeAccountSharingScope] = []
        private var pending: Task<[any AccountSharingOriginal], Error>?
        init(isCurrent: @escaping @MainActor () -> Bool) { self.isCurrent = isCurrent }
        var isActive: Bool { active && isCurrent() }

        func acquire(
            reuseHeld: Bool = true,
            _ factory: @escaping @MainActor () async throws -> [any AccountSharingOriginal]
        ) async throws
            -> [NativeAccountSharingScope]
        {
            try Task.checkCancellation()
            guard isActive else { throw MarmotKitError.AccountSharingClosed }
            try retryCleanup()
            if held.contains(where: { $0.isActive }) {
                guard reuseHeld else { throw MarmotKitError.AccountSharingNotReady }
                return held
            }
            let task = Task { try await factory() }
            pending = task
            defer { pending = nil }
            let originals = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard isActive, !Task.isCancelled else {
                for original in originals { original.cancel() }
                throw MarmotKitError.AccountSharingClosed
            }
            guard originals.count <= 128 else {
                for original in originals { original.cancel() }
                throw MarmotKitError.AccountSharingNotReady
            }
            held = originals.map {
                NativeAccountSharingScope(original: $0, isCurrent: { [weak self] in self?.isActive == true })
            }
            return held
        }
        func invalidate() {
            active = false
            pending?.cancel()
            for original in held { original.cancel() }
            held = []
        }
        func retryCleanup() throws {
            guard pending == nil else { throw MarmotKitError.AccountSharingNotReady }
        }
    }
#endif
