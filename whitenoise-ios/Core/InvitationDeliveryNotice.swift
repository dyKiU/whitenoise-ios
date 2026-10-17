import Foundation
import MarmotKit

enum InvitationDeliveryNotice {
    static func toast(for event: MarmotEventFfi) -> Toast? {
        guard case .welcomeDeliveryPending = event else { return nil }
        return .warning(
            L10n.string("Invitation delivery pending"),
            message: L10n.string("The chat was created, but invitation delivery is not confirmed. The recipient may not see a chat request yet."),
            duration: 8
        )
    }
}
