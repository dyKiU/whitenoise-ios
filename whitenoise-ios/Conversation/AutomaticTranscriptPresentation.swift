import MarmotKit

#if WN_EXPERIMENTAL_DEVICE_SYNC
    enum AutomaticTranscriptRow: Identifiable {
        case ordinary(TimelineItem)
        case paired(PairedChatMessageFfi)

        var id: String {
            switch self {
            case .ordinary(let item): item.id
            case .paired(let item): "paired:" + item.messageIdHex
            }
        }
    }

    enum AutomaticTranscriptPresentation {
        static func rows(
            ordinary: [TimelineItem], paired: [PairedChatMessageFfi], blockedAuthors: Set<String>, now: UInt64
        ) -> [AutomaticTranscriptRow] {
            SourceQualifiedTimelineUnion.rows(
                ordinary: ordinary.map { item in
                    let id: String?
                    if case .message(let record, _) = item.kind { id = record.messageIdHex } else { id = nil }
                    return .init(canonicalId: id, timestamp: item.timestamp)
                },
                paired: paired.map { message in
                    .init(
                        canonicalId: message.messageIdHex, timestamp: message.createdAt,
                        expiresAt: message.expiresAt,
                        visible: !blockedAuthors.contains(message.authorHex.lowercased()))
                }, now: now
            ).map { row in
                switch row {
                case .ordinary(let index): .ordinary(ordinary[index])
                case .paired(let index, _): .paired(paired[index])
                }
            }
        }
    }
#endif
