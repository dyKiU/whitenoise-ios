import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    @MainActor @Suite struct PairedMessagePresentationTests {
        private func message() -> PairedChatMessageFfi {
            PairedChatMessageFfi(
                kind: 9, canonicalChat: true, messageIdHex: String(repeating: "a", count: 64),
                authorHex: String(repeating: "b", count: 64), createdAt: 123, expiresAt: 200,
                deleted: false, content: "Synthetic text",
                contentTokens: .init(blocks: [], truncated: false, blankLinesBefore: Data()),
                tags: [], mediaAttachments: [],
                source: .init(
                    deviceHex: String(repeating: "c", count: 64),
                    policyDigestHex: String(repeating: "d", count: 64),
                    protectedGeneration: 1, sourceEpoch: 1, sourceSequence: 1,
                    sourceDigestHex: String(repeating: "e", count: 64)))
        }

        @Test func ownMessagesUseOutgoingAlignmentAndRetainSourceTimestamp() {
            let value = message()
            let presentation = PairedMessagePresentation(
                message: value, localAccountIdHex: value.authorHex.uppercased())
            #expect(presentation.isOutgoing)
            #expect(presentation.timestamp == 123)
            #expect(presentation.text == "Synthetic text")
        }

        @Test func missingOrDifferentAccountNeverLooksLikeAnOwnMessage() {
            let value = message()
            for account in [nil, "", String(repeating: "f", count: 64)] {
                #expect(!PairedMessagePresentation(message: value, localAccountIdHex: account).isOutgoing)
            }
        }

        @Test func deletedAndUnsupportedContentIsNeverRenderedAsChatText() {
            var value = message()
            value.deleted = true
            let deleted = PairedMessagePresentation(message: value, localAccountIdHex: nil)
            #expect(deleted.isDeleted)
            #expect(deleted.text.isEmpty)
            #expect(!deleted.showsUnavailableAttachment)
            value.deleted = false
            value.canonicalChat = false
            #expect(PairedMessagePresentation(message: value, localAccountIdHex: nil).text.isEmpty)
        }

        @Test func dateSectionsFollowVisibleSourceRowsWithoutReorderingThem() {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var first = message()
            first.expiresAt = nil
            first.createdAt = 86_401
            var second = first
            second.messageIdHex = "second"
            second.createdAt = 86_402
            var third = first
            third.messageIdHex = "third"
            third.createdAt = 172_801
            let rows = PairedTimelineEntry.make(messages: [first, second, third], calendar: calendar)
            #expect(rows.map(\.id) == [first.messageIdHex, "second", "third"])
            #expect(rows[0].dayStart == Date(timeIntervalSince1970: 86_400))
            #expect(rows[1].dayStart == nil)
            #expect(rows[2].dayStart == Date(timeIntervalSince1970: 172_800))
        }

        @Test func hiddenMessagesCannotLeaveAnEmptyDateSectionOrLeakBlockedText() {
            var expired = message()
            expired.expiresAt = 100
            var visible = message()
            visible.messageIdHex = "visible"
            visible.expiresAt = nil
            visible.authorHex = String(repeating: "f", count: 64)
            let rows = PairedTimelineEntry.make(
                messages: [expired, visible], now: Date(timeIntervalSince1970: 101))
            #expect(rows.count == 1)
            #expect(rows.first?.id == "visible")
            #expect(rows.first?.dayStart != nil)
            #expect(
                PairedTimelineEntry.make(
                    messages: [visible], blockedAuthors: [visible.authorHex]
                ).isEmpty)
        }

        @Test func expirationUsesSourceDeadlineIncludingExactBoundary() {
            var value = message()
            let presentation = PairedMessagePresentation(message: value, localAccountIdHex: nil)
            #expect(presentation.isVisible(at: Date(timeIntervalSince1970: 199)))
            #expect(!presentation.isVisible(at: Date(timeIntervalSince1970: 200)))
            value.expiresAt = nil
            #expect(
                PairedMessagePresentation(message: value, localAccountIdHex: nil)
                    .isVisible(at: Date(timeIntervalSince1970: 1_000)))
        }
    }
#endif
