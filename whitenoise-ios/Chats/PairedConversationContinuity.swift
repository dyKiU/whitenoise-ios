import Foundation
import MarmotKit
import Observation

#if WN_EXPERIMENTAL_DEVICE_SYNC
    /// Account-scoped display values and client-token correlations, never live SDK handles.
    @MainActor @Observable
    final class PairedConversationContinuity {
        let accountRef: String
        let groupIdHex: String
        var snapshot: AccountConversationWindowSnapshotFfi?
        var markdownByMessageId: [String: [MarkdownDisplayBlock]] = [:]
        var pendingTexts: [String: PairedPendingText] = [:]
        var draft = ""
        private(set) var retired = false

        init(accountRef: String, groupIdHex: String) {
            self.accountRef = accountRef
            self.groupIdHex = groupIdHex
        }

        func invalidate() {
            retired = true
            snapshot = nil
            markdownByMessageId = [:]
            pendingTexts = [:]
            draft = ""
        }
    }
#endif
