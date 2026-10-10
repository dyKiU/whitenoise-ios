import Foundation
import Testing

@testable import whitenoise_ios

struct SynchronizedHistoryPresentationTests {
    private func record(deleted: Bool = false, expiresAt: UInt64? = nil) -> SynchronizedHistoryRecord {
        .init(
            id: String(repeating: "01", count: 32), authorPubkey: String(repeating: "02", count: 32),
            createdAt: 1, expiresAt: expiresAt, deleted: deleted, content: "isolated retained content",
            tags: [], mediaAttachments: [], transferId: Data(repeating: 3, count: 32),
            sourceDevice: Data(repeating: 4, count: 32), manifestDigest: Data(repeating: 5, count: 32))
    }
    @Test func deletedRecordNeverDisplaysRetainedContent() {
        #expect(
            SynchronizedHistoryPresentation.contentState(record(deleted: true), referenceDate: .distantPast) == .deleted
        )
    }
    @Test func cachedRecordIsMaskedAtOriginalExpiryWithoutAnotherRead() {
        let value = record(expiresAt: 10)
        #expect(
            SynchronizedHistoryPresentation.contentState(value, referenceDate: Date(timeIntervalSince1970: 9))
                == .visible)
        #expect(
            SynchronizedHistoryPresentation.contentState(value, referenceDate: Date(timeIntervalSince1970: 10))
                == .expired)
        #expect(
            SynchronizedHistoryPresentation.contentState(value, referenceDate: Date(timeIntervalSince1970: 11))
                == .expired)
    }
    @Test func unexpiredSourceRecordRemainsVisible() {
        #expect(SynchronizedHistoryPresentation.contentState(record(), referenceDate: .now) == .visible)
    }
}
