import SwiftUI

/// Shared title, preview, timestamp and attention layout for conversation rows.
struct ChatRowDetails<Badges: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    var isTitlePending = false
    let preview: ChatRowPreviewPresentation
    var timestamp: String?
    var status: ChatRowStatusPresentation.Status = .none
    @ViewBuilder let badges: Badges

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.headline)
                    .redacted(reason: isTitlePending ? .placeholder : [])
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                badges
                Spacer(minLength: 8)
                if let timestamp {
                    Text(timestamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .top, spacing: 5) {
                previewText
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                switch status {
                case .invitation:
                    ChatInviteBadge()
                case .unread(let count):
                    UnreadCountBadge(count: count)
                case .none:
                    EmptyView()
                }
            }
        }
    }

    private var previewText: Text {
        var body = Text(verbatim: preview.body)
        if let symbolName = preview.systemImageName {
            body = Text(Image(systemName: symbolName)) + Text(verbatim: " ") + body
        }
        if let prefix = preview.prefix {
            return Text(verbatim: prefix + ": ").bold() + body
        }
        return body
    }
}

#Preview {
    ChatRowDetails(
        title: "Friends", preview: .init(prefix: "You", body: "See you tomorrow"),
        timestamp: "10:30", status: .unread(2)
    ) {}
    .padding()
}
