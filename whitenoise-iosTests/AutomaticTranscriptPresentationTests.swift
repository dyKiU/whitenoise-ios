import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    @MainActor @Suite struct AutomaticTranscriptPresentationTests {
        private let messageId = String(repeating: "a", count: 64)
        private let author = String(repeating: "b", count: 64)

        private func paired(deleted: Bool = false, expiresAt: UInt64? = nil) -> PairedChatMessageFfi {
            .init(
                kind: 9, canonicalChat: true, messageIdHex: messageId, authorHex: author,
                createdAt: 2, expiresAt: expiresAt, deleted: deleted, content: deleted ? "" : "Synthetic",
                contentTokens: .init(blocks: [], truncated: false, blankLinesBefore: Data()),
                tags: [], mediaAttachments: [],
                source: .init(
                    deviceHex: String(repeating: "c", count: 64), policyDigestHex: String(repeating: "d", count: 64),
                    protectedGeneration: 1, sourceEpoch: 1, sourceSequence: 1,
                    sourceDigestHex: String(repeating: "e", count: 64)))
        }

        @Test func ordinaryRecordAndItsActionsKeepExactValueOnCanonicalCollision() throws {
            let record = AppMessageRecordFfi(
                messageIdHex: messageId, direction: "received", groupIdHex: "0102", sender: author,
                plaintext: "Synthetic", contentTokens: .init(blocks: [], truncated: false, blankLinesBefore: Data()),
                kind: 9, tags: [], recordedAt: 2, receivedAt: 2)
            let ordinary = TimelineItem.message(record, status: .received)
            let rows = AutomaticTranscriptPresentation.rows(
                ordinary: [ordinary], paired: [paired()], blockedAuthors: [], now: 3)
            #expect(rows.count == 1)
            guard case .ordinary(let original) = try #require(rows.first) else {
                Issue.record("Source copy replaced ordinary authority")
                return
            }
            #expect(original == ordinary)
            #expect(rows.first?.id == ordinary.id)
        }

        @Test func systemRowsSurviveAndMissingSourceMessageAppearsWithoutAnMlsRecord() throws {
            let system = TimelineItem.systemEvent(id: "system", event: .groupCreated, timestamp: 1)
            let rows = AutomaticTranscriptPresentation.rows(
                ordinary: [system], paired: [paired()], blockedAuthors: [], now: 3)
            #expect(rows.map(\.id) == [system.id, "paired:" + messageId])
            guard case .paired(let observation) = try #require(rows.last) else {
                Issue.record("Missing source observation")
                return
            }
            #expect(observation == paired())
        }

        @Test func blockExpiryAndRevocationNeverRemoveOrdinarySystemRows() {
            let ordinary = [TimelineItem.systemEvent(id: "system", event: .groupCreated, timestamp: 1)]
            let blocked = AutomaticTranscriptPresentation.rows(
                ordinary: ordinary, paired: [paired()], blockedAuthors: [author], now: 3)
            let expired = AutomaticTranscriptPresentation.rows(
                ordinary: ordinary, paired: [paired(expiresAt: 3)], blockedAuthors: [], now: 3)
            let revoked = AutomaticTranscriptPresentation.rows(
                ordinary: ordinary, paired: [], blockedAuthors: [], now: 3)
            #expect(blocked.map(\.id) == ordinary.map(\.id))
            #expect(expired.map(\.id) == ordinary.map(\.id))
            #expect(revoked.map(\.id) == ordinary.map(\.id))
        }

        @Test func deletionTombstoneRetainsSourceAndCanonicalIdentity() throws {
            let rows = AutomaticTranscriptPresentation.rows(
                ordinary: [], paired: [paired(deleted: true)], blockedAuthors: [], now: 3)
            guard case .paired(let observation) = try #require(rows.first) else {
                Issue.record("Missing source tombstone")
                return
            }
            #expect(observation.deleted)
            #expect(observation.content.isEmpty)
            #expect(observation.messageIdHex == messageId)
        }
    }
#endif
