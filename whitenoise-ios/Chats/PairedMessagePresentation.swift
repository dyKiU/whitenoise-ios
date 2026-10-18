import Foundation
import MarmotKit

#if WN_EXPERIMENTAL_DEVICE_SYNC
    struct PairedMessagePresentation {
        let isOutgoing: Bool
        let text: String
        let isDeleted: Bool
        let showsUnavailableAttachment: Bool
        let timestamp: UInt64
        let expiresAt: UInt64?

        init(message: PairedChatMessageFfi, localAccountIdHex: String?) {
            isOutgoing =
                localAccountIdHex.map { !$0.isEmpty && $0.lowercased() == message.authorHex.lowercased() }
                ?? false
            isDeleted = message.deleted
            text = message.deleted || !message.canonicalChat ? "" : message.content
            showsUnavailableAttachment =
                !message.deleted && message.canonicalChat && !message.mediaAttachments.isEmpty
            timestamp = message.createdAt
            expiresAt = message.expiresAt
        }

        func isVisible(at date: Date) -> Bool {
            expiresAt.map { Double($0) > date.timeIntervalSince1970 } ?? true
        }
    }
    struct PairedTimelineEntry: Identifiable {
        let message: PairedChatMessageFfi
        let dayStart: Date?
        var id: String { message.messageIdHex }

        static func make(
            messages: [PairedChatMessageFfi], now: Date = Date(),
            blockedAuthors: Set<String> = [], calendar: Calendar = .autoupdatingCurrent
        ) -> [PairedTimelineEntry] {
            var previousDay: Date?
            return messages.compactMap { message in
                guard !blockedAuthors.contains(message.authorHex.lowercased()),
                    message.expiresAt.map({ Double($0) > now.timeIntervalSince1970 }) ?? true
                else { return nil }
                let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(message.createdAt)))
                let startsDay = day != previousDay
                previousDay = day
                return PairedTimelineEntry(message: message, dayStart: startsDay ? day : nil)
            }
        }
    }
#endif
