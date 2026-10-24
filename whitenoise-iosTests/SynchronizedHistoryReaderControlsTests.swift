import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

private actor HistoryReaderGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor HistoryPageQueue {
    private var pages: [SynchronizedHistoryPage]
    private(set) var cursors: [String?] = []
    init(_ pages: [SynchronizedHistoryPage]) { self.pages = pages }
    func read(cursor: String?) -> SynchronizedHistoryPage {
        cursors.append(cursor)
        return pages.removeFirst()
    }
}

@MainActor struct SynchronizedHistoryReaderControlsTests {
    private func record(_ byte: String, deleted: Bool = false) -> SynchronizedHistoryRecord {
        SynchronizedHistoryRecord(
            id: String(repeating: byte, count: 32), authorPubkey: String(repeating: "02", count: 32),
            createdAt: 12, expiresAt: nil, deleted: deleted, content: deleted ? "" : "synthetic archive",
            tags: [.init(values: ["subject", "synthetic tag"])],
            mediaAttachments: [
                .rejected(attachmentIndex: 0, rejection: .init(kind: .invalidStructure, detail: "synthetic")),
                .rejected(attachmentIndex: 2, rejection: .init(kind: .unsupportedFormat, detail: "synthetic")),
            ], transferId: Data(repeating: 3, count: 32), sourceDevice: Data(repeating: 4, count: 32),
            manifestDigest: Data(repeating: 5, count: 32))
    }

    @Test func nextPageUsesExactCursorAndKeepsOnlyOneBoundedPage() async {
        let first = record("01")
        let second = record("02")
        let queue = HistoryPageQueue([
            .init(records: [first], nextMessageId: first.id),
            .init(records: [second], nextMessageId: second.id),
            .init(records: [], nextMessageId: nil),
        ])
        let model = SynchronizedHistoryViewModel(accountRef: "alice", groupIdHex: "chat", pageSize: 1) {
            _, _, cursor, limit in
            #expect(limit == 1)
            return await queue.read(cursor: cursor)
        }
        await model.loadNextPage()
        await model.loadNextPage()
        #expect(model.records.map(\.id) == [second.id])
        await model.loadNextPage()
        await model.loadNextPage()
        #expect(model.records.isEmpty)
        #expect(!model.hasMore)
        #expect(await queue.cursors == [nil, first.id, second.id])
    }

    @Test func accountInvalidationRefusesLateNonCooperativeReadAndFurtherReads() async {
        let gate = HistoryReaderGate()
        let value = record("01")
        let model = SynchronizedHistoryViewModel(accountRef: "alice", groupIdHex: "chat") { _, _, _, _ in
            await gate.pause()
            return .init(records: [value], nextMessageId: nil)
        }
        let loading = Task { await model.loadNextPage() }
        await gate.waitUntilEntered()
        model.invalidate()
        #expect(!model.isLoading)
        await gate.release()
        await loading.value
        await model.loadNextPage()
        #expect(!model.isActive)
        #expect(model.records.isEmpty)
        #expect(!model.hasMore)
        #expect(!model.readFailed)
    }

    @Test func reloadSupersedesLateOldReadWithoutOverwritingNewPage() async {
        let gate = HistoryReaderGate()
        let old = record("01")
        let fresh = record("02")
        let queue = HistoryPageQueue([
            .init(records: [old], nextMessageId: nil), .init(records: [fresh], nextMessageId: nil),
        ])
        let model = SynchronizedHistoryViewModel(accountRef: "alice", groupIdHex: "chat") { _, _, cursor, _ in
            let page = await queue.read(cursor: cursor)
            if page.records.first?.id == old.id { await gate.pause() }
            return page
        }
        let loading = Task { await model.loadNextPage() }
        await gate.waitUntilEntered()
        await model.reload()
        #expect(model.records.map(\.id) == [fresh.id])
        await gate.release()
        await loading.value
        #expect(model.records.map(\.id) == [fresh.id])
        #expect(!model.isLoading)
        #expect(await queue.cursors == [nil, nil])
    }

    @Test func callerCancellationCannotPublishLateRead() async {
        let gate = HistoryReaderGate()
        let value = record("01")
        let model = SynchronizedHistoryViewModel(accountRef: "alice", groupIdHex: "chat") { _, _, _, _ in
            await gate.pause()
            return .init(records: [value], nextMessageId: nil)
        }
        let loading = Task { await model.loadNextPage() }
        await gate.waitUntilEntered()
        loading.cancel()
        await gate.release()
        await loading.value
        #expect(model.records.isEmpty)
        #expect(!model.readFailed)
        #expect(!model.isLoading)
    }

    @Test func failedReadClearsEarlierPageAndRetriesFromBeginning() async {
        enum Failure: Error { case unavailable }
        let first = record("01")
        let queue = HistoryPageQueue([
            .init(records: [first], nextMessageId: first.id), .init(records: [first], nextMessageId: nil),
        ])
        let model = SynchronizedHistoryViewModel(accountRef: "alice", groupIdHex: "chat", pageSize: 1) {
            _, _, cursor, _ in
            if cursor != nil { throw Failure.unavailable }
            return await queue.read(cursor: cursor)
        }
        await model.loadNextPage()
        #expect(model.records.count == 1)
        await model.loadNextPage()
        #expect(model.records.isEmpty)
        #expect(model.readFailed)
        #expect(!model.isLoading)
        #expect(model.hasMore)
        await model.reload()
        #expect(model.records.map(\.id) == [first.id])
        #expect(!model.readFailed)
        #expect(await queue.cursors == [nil, nil])
    }

    @Test func malformedOversizedOrNonAdvancingPagesNeverPublish() async {
        let first = record("01")
        let second = record("02")
        for (limit, page): (UInt32, SynchronizedHistoryPage) in [
            (1, .init(records: [first, second], nextMessageId: nil)),
            (1, .init(records: [first], nextMessageId: second.id)),
            (2, .init(records: [first, first], nextMessageId: nil)),
            (2, .init(records: [second, first], nextMessageId: nil)),
        ] {
            let model = SynchronizedHistoryViewModel(accountRef: "alice", groupIdHex: "chat", pageSize: limit) {
                _, _, _, _ in page
            }
            await model.loadNextPage()
            #expect(model.records.isEmpty)
            #expect(model.readFailed)
        }
    }

    @Test func logicalTombstoneTagsAndRejectedMediaRemainOrderedAndDebugIsRedacted() async {
        let value = record("01", deleted: true)
        let model = SynchronizedHistoryViewModel(accountRef: "alice", groupIdHex: "chat") { _, _, _, _ in
            .init(records: [value], nextMessageId: nil)
        }
        await model.loadNextPage()
        #expect(model.records.first?.deleted == true)
        #expect(model.records.first?.content == "")
        #expect(model.records.first?.tags == value.tags)
        let indices = model.records.first?.mediaAttachments.map { outcome in
            switch outcome {
            case .accepted(let index, _), .rejected(let index, _): index
            }
        }
        #expect(indices == [0, 2])
        #expect(String(reflecting: value) == "SynchronizedHistoryRecord(redacted)")
    }
}
