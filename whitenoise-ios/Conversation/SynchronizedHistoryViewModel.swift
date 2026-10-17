import Foundation
import Observation

/// A single account/chat reader. Its owner must invalidate it before account teardown.
@MainActor @Observable final class SynchronizedHistoryViewModel {
    typealias Reader = @Sendable (String, String, String?, UInt32) async throws -> SynchronizedHistoryPage

    private(set) var records: [SynchronizedHistoryRecord] = []
    private(set) var hasMore = true
    private(set) var isLoading = false
    private(set) var readFailed = false
    private(set) var isActive = true
    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let groupIdHex: String
    @ObservationIgnored private let read: Reader
    @ObservationIgnored private let pageSize: UInt32
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    var isCurrentOwner: Bool { isActive && isCurrent() }
    @ObservationIgnored private var cursor: String?
    // A cancelled, non-cooperative read must not clear a newer reload's loading state.
    @ObservationIgnored private var currentRead: ReadOperation?

    private final class ReadOperation {
        let task: Task<SynchronizedHistoryPage, Error>
        init(task: Task<SynchronizedHistoryPage, Error>) { self.task = task }
    }

    private enum ReadError: Error { case invalidPage }

    init(
        accountRef: String, groupIdHex: String, pageSize: UInt32 = 200,
        isCurrent: @escaping @MainActor () -> Bool = { true }, read: @escaping Reader
    ) {
        precondition((1...200).contains(pageSize))
        self.accountRef = accountRef
        self.groupIdHex = groupIdHex
        self.pageSize = pageSize
        self.read = read
        self.isCurrent = isCurrent
    }

    func loadNextPage() async {
        guard isCurrentOwner else {
            invalidate()
            return
        }
        guard !Task.isCancelled, currentRead == nil, hasMore else { return }
        let reader = read
        let account = accountRef
        let group = groupIdHex
        let after = cursor
        let limit = pageSize
        let task = Task.detached { try await reader(account, group, after, limit) }
        let operation = ReadOperation(task: task)
        currentRead = operation
        isLoading = true
        readFailed = false
        defer {
            if currentRead === operation {
                currentRead = nil
                isLoading = false
            }
        }
        do {
            let page = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard isCurrentOwner else {
                invalidate()
                return
            }
            guard currentRead === operation, !Task.isCancelled else { return }
            try validate(page, after: after)
            // Keep one bounded page, not an unbounded native copy of the archive.
            records = page.records
            cursor = page.nextMessageId
            hasMore = cursor != nil
        } catch {
            guard isCurrentOwner else {
                invalidate()
                return
            }
            guard currentRead === operation, !Task.isCancelled else { return }
            records = []
            cursor = nil
            hasMore = true
            readFailed = true
        }
    }

    func reload() async {
        guard isActive, !Task.isCancelled else { return }
        retireRead()
        records = []
        cursor = nil
        hasMore = true
        readFailed = false
        await loadNextPage()
    }

    func invalidate() {
        isActive = false
        retireRead()
        records = []
        cursor = nil
        hasMore = false
        readFailed = false
    }

    private func retireRead() {
        currentRead?.task.cancel()
        currentRead = nil
        isLoading = false
    }

    private func validate(_ page: SynchronizedHistoryPage, after: String?) throws {
        guard page.records.count <= Int(pageSize) else { throw ReadError.invalidPage }
        var previous = after
        for record in page.records {
            guard record.id.utf8.count == 64,
                record.id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                previous.map({ record.id > $0 }) ?? true,
                record.transferId.count == 32, record.sourceDevice.count == 32, record.manifestDigest.count == 32
            else { throw ReadError.invalidPage }
            previous = record.id
        }
        if let next = page.nextMessageId {
            guard page.records.count == Int(pageSize), next == page.records.last?.id, next != after else {
                throw ReadError.invalidPage
            }
        }
    }
}
