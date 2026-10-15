import Foundation

/// Presentation indexes preserve original ordinary values and never create MLS message records.
nonisolated enum SourceQualifiedTimelineUnion {
    struct OrdinaryKey {
        let canonicalId: String?
        let timestamp: UInt64
    }
    struct PairedKey {
        let canonicalId: String
        let timestamp: UInt64
        let expiresAt: UInt64?
        let visible: Bool
    }
    enum Row: Equatable {
        case ordinary(index: Int)
        case paired(index: Int, canonicalId: String)
    }

    static func canonicalId(_ value: String?) -> String? {
        guard let value, value.utf8.count == 64,
            value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return nil }
        return value
    }

    static func rows(ordinary: [OrdinaryKey], paired: [PairedKey], now: UInt64) -> [Row] {
        struct Entry {
            let row: Row
            let timestamp: UInt64
            let canonicalId: String?
            let stableIndex: Int
        }
        let ordinaryIds = Set(ordinary.compactMap { canonicalId($0.canonicalId) })
        var entries = ordinary.enumerated().map { index, key in
            Entry(
                row: .ordinary(index: index), timestamp: key.timestamp,
                canonicalId: canonicalId(key.canonicalId), stableIndex: index)
        }
        var seen = ordinaryIds
        // A malformed oversized observation lane contributes nothing; ordinary paging is untouched.
        if paired.count <= 128 {
            for (index, key) in paired.enumerated() {
                guard key.visible, let id = canonicalId(key.canonicalId), !seen.contains(id),
                    key.expiresAt.map({ $0 > now }) ?? true
                else { continue }
                seen.insert(id)
                entries.append(
                    Entry(
                        row: .paired(index: index, canonicalId: id), timestamp: key.timestamp,
                        canonicalId: id, stableIndex: ordinary.count + index))
            }
        }
        return entries.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            if let a = lhs.canonicalId, let b = rhs.canonicalId, a != b { return a < b }
            if (lhs.canonicalId == nil) != (rhs.canonicalId == nil) { return lhs.canonicalId != nil }
            return lhs.stableIndex < rhs.stableIndex
        }.map(\.row)
    }
}
