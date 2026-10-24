import MarmotKit
import Observation

#if WN_EXPERIMENTAL_DEVICE_SYNC
    /// Bounded display data survives a runtime handoff without retaining its native window.
    @MainActor @Observable
    final class PairedChatListContinuity {
        let accountRef: String
        var snapshot: AccountChatListWindowSnapshotFfi?
        private(set) var retired = false

        init(accountRef: String) { self.accountRef = accountRef }

        func invalidate() {
            retired = true
            snapshot = nil
        }
    }
#endif
