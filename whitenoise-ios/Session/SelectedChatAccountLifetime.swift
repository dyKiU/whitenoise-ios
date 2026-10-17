#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit

    /// Negative account-lifetime custody; no selectors or snapshots can recreate SDK handles.
    @MainActor final class SelectedChatAccountLifetime {
        private var owner: SelectedChatAccountOwner?
        private var retiring: [SelectedChatAccountOwner] = []

        func currentOwner(accountRef: String, client: MarmotClient, isCurrent: @escaping @MainActor () -> Bool) throws
            -> SelectedChatAccountOwner
        {
            guard isCurrent(), !Task.isCancelled else { throw MarmotKitError.SelectedChatCopyClosed }
            if let owner {
                guard owner.matches(accountRef: accountRef, runtime: client) else {
                    throw MarmotKitError.SelectedChatCopyClosed
                }
                return owner
            }
            let value = SelectedChatAccountOwner(accountRef: accountRef, runtime: client, isCurrent: isCurrent)
            owner = value
            return value
        }
        func invalidate() {
            guard let owner else { return }
            owner.invalidate()
            retiring.append(owner)
            self.owner = nil
        }
        func retryCleanup() async throws {
            var firstError: Error?
            if let owner {
                do { try await owner.retryCleanup() } catch { firstError = error }
            }
            for value in retiring {
                do {
                    try await value.retryCleanup()
                    retiring.removeAll { $0 === value }
                } catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }
    }
#endif
