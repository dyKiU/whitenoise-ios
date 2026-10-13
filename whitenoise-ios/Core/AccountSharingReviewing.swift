#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit

    // App interface over the original SDK object, not a generated-binding substitute.
    nonisolated protocol AccountSharingOriginal: AnyObject, Sendable {
        func snapshot() throws -> AccountSharingSnapshotFfi
        func approve(displayedRevision: UInt64) async throws
        func cancel()
    }
    extension AccountSharingApproval: AccountSharingOriginal {}

    @MainActor protocol AccountSharingReviewing: AnyObject {
        var id: UUID { get }
        var isActive: Bool { get }
        var snapshot: AccountSharingSnapshotFfi? { get }
        func refresh() throws
        func approve(displayedRevision: UInt64) async throws
        func cancel()
    }
#endif
