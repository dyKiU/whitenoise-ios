import MarmotKit
import SwiftUI

#if WN_EXPERIMENTAL_DEVICE_SYNC
    /// Read-only source-attested row. It has no ordinary reference, media request, or moderation action.
    struct PairedChatMessageRow: View {
        let message: PairedChatMessageFfi?

        var body: some View {
            if let message {
                TimelineView(.periodic(from: .now, by: 1)) { clock in
                    if message.expiresAt.map({ Double($0) > clock.date.timeIntervalSince1970 }) ?? true {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.string("Shared from a linked device"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if message.deleted {
                                Text(L10n.string("Message deleted"))
                                    .foregroundStyle(.secondary)
                            } else {
                                if message.canonicalChat {
                                    Text(verbatim: message.content)
                                        .textSelection(.enabled)
                                } else {
                                    Text(L10n.string("Unsupported message"))
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(Array(message.mediaAttachments.enumerated()), id: \.offset) { _, outcome in
                                    switch outcome {
                                    case .accepted:
                                        Text(L10n.string("Attachment not downloaded"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    case .rejected:
                                        Text(L10n.string("Attachment unavailable"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text(L10n.string("Shared from a linked device"))
            }
        }
    }

    #Preview {
        PairedChatMessageRow(message: nil)
    }
#endif
