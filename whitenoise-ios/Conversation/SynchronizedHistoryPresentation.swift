import Foundation

nonisolated enum SynchronizedHistoryContentState: Equatable { case visible, deleted, expired }

nonisolated enum SynchronizedHistoryPresentation {
    static func contentState(_ record: SynchronizedHistoryRecord, referenceDate: Date)
        -> SynchronizedHistoryContentState
    {
        if record.deleted { return .deleted }
        if let expiry = record.expiresAt, Double(expiry) <= referenceDate.timeIntervalSince1970 { return .expired }
        return .visible
    }
}
