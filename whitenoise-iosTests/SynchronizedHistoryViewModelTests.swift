import Foundation
import Testing

@testable import whitenoise_ios

@MainActor struct SynchronizedHistoryViewModelTests {
    @Test func firstPageDisplaysSourceAttestedContentAndPreservesProvenance() async {
        let record = SynchronizedHistoryRecord(
            id: String(repeating: "01", count: 32), authorPubkey: String(repeating: "02", count: 32),
            createdAt: 12, expiresAt: nil, deleted: false, content: "retained test message",
            tags: [], mediaAttachments: [], transferId: Data(repeating: 3, count: 32),
            sourceDevice: Data(repeating: 4, count: 32), manifestDigest: Data(repeating: 5, count: 32))
        let model = SynchronizedHistoryViewModel(accountRef: "alice", groupIdHex: "opaque-group") {
            account, group, cursor, limit in
            #expect(account == "alice")
            #expect(group == "opaque-group")
            #expect(cursor == nil)
            #expect(limit == 200)
            return SynchronizedHistoryPage(records: [record], nextMessageId: nil)
        }
        await model.loadNextPage()
        #expect(model.records.map(\.content) == [record.content])
        #expect(model.records.first?.sourceDevice == record.sourceDevice)
        #expect(model.records.first?.manifestDigest == record.manifestDigest)
        #expect(!model.hasMore)
    }
}
