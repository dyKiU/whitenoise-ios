import Foundation
import MarmotKit

nonisolated enum SynchronizedHistoryReadError: Error { case unavailable }

/// Source-attested logical history, separate from authenticated live timeline rows.
nonisolated struct SynchronizedHistoryRecord: Sendable, Identifiable, CustomDebugStringConvertible {
    let id: String
    let authorPubkey: String
    let createdAt: UInt64
    let expiresAt: UInt64?
    let deleted: Bool
    let content: String
    let tags: [MessageTagFfi]
    let mediaAttachments: [MediaAttachmentOutcomeFfi]
    let transferId: Data
    let sourceDevice: Data
    let manifestDigest: Data

    var debugDescription: String { "SynchronizedHistoryRecord(redacted)" }
}

/// The cursor is a local read observation, never a transfer or download grant.
nonisolated struct SynchronizedHistoryPage: Sendable {
    let records: [SynchronizedHistoryRecord]
    let nextMessageId: String?
}

#if WN_EXPERIMENTAL_DEVICE_SYNC
    extension SynchronizedHistoryPage {
        init(_ page: ArchivedHistoryPageFfi) {
            records = page.records.map { record in
                SynchronizedHistoryRecord(
                    id: record.messageIdHex, authorPubkey: record.authorPubkey, createdAt: record.createdAt,
                    expiresAt: record.expiresAt, deleted: record.deleted, content: record.content,
                    tags: record.tags, mediaAttachments: record.mediaAttachments, transferId: record.transferId,
                    sourceDevice: record.sourceDevice, manifestDigest: record.manifestDigest)
            }
            nextMessageId = page.nextMessageIdHex
        }
    }
#endif
