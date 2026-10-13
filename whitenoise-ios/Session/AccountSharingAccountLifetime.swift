#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit

    @MainActor final class AccountSharingAccountLifetime {
        private var owner: AccountSharingAccountOwner?
        private var retiring: [AccountSharingAccountOwner] = []
        func currentOwner(isCurrent: @escaping @MainActor () -> Bool) throws -> AccountSharingAccountOwner {
            try Task.checkCancellation()
            guard isCurrent() else { throw MarmotKitError.AccountSharingClosed }
            try retryCleanup()
            if let owner, owner.isActive { return owner }
            invalidate()
            try retryCleanup()
            let value = AccountSharingAccountOwner(isCurrent: isCurrent)
            owner = value
            return value
        }
        func invalidate() {
            guard let owner else { return }
            owner.invalidate()
            retiring.append(owner)
            self.owner = nil
        }
        func retryCleanup() throws {
            try owner?.retryCleanup()
            var first: Error?
            for old in retiring {
                do {
                    try old.retryCleanup()
                    retiring.removeAll { $0 === old }
                } catch { if first == nil { first = error } }
            }
            if let first { throw first }
        }
    }
#endif
