import MarmotKit

#if WN_EXPERIMENTAL_DEVICE_SYNC
    enum SourceQualifiedConversationRow: Identifiable {
        case ordinary(TimelineItem)
        case paired(PairedChatMessageFfi)

        var id: String {
            switch self {
            case .ordinary(let item): item.id
            case .paired(let message): "paired:" + message.messageIdHex
            }
        }

        static func rows(
            ordinary: [TimelineItem], paired: [PairedChatMessageFfi],
            blockedAuthors: Set<String>, now: UInt64
        ) -> [Self] {
            let positions = SourceQualifiedTimelineUnion.rows(
                ordinary: ordinary.map { item in
                    let id: String?
                    if case .message(let record, _) = item.kind { id = record.messageIdHex } else { id = nil }
                    return .init(canonicalId: id, timestamp: item.timestamp)
                },
                paired: paired.map { row in
                    .init(
                        canonicalId: row.messageIdHex, timestamp: row.createdAt, expiresAt: row.expiresAt,
                        visible: !blockedAuthors.contains(row.authorHex.lowercased()))
                }, now: now)
            return positions.map { position in
                switch position {
                case .ordinary(let index): .ordinary(ordinary[index])
                case .paired(let index, _): .paired(paired[index])
                }
            }
        }
    }
#endif
