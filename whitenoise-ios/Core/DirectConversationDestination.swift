import MarmotKit

/// A navigation result preserves the distinction between local MLS authority and a paired observation.
nonisolated enum DirectConversationDestination: Equatable, Sendable {
    case localMls(ExistingDirectConversationFfi)
    #if WN_EXPERIMENTAL_DEVICE_SYNC
        case pairedSource(PairedChatSummaryFfi)
    #endif

    var groupIdHex: String {
        switch self {
        case .localMls(let conversation): conversation.groupIdHex
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            case .pairedSource(let conversation): conversation.groupIdHex
        #endif
        }
    }

    var reusable: Bool {
        switch self {
        case .localMls(let conversation): conversation.reusable
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            case .pairedSource: true
        #endif
        }
    }

    var archived: Bool {
        if case .localMls(let conversation) = self { return conversation.archived }
        return false
    }

    var isPaired: Bool {
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            if case .pairedSource = self { return true }
        #endif
        return false
    }
}
