import MarmotKit
import SwiftUI

#if WN_EXPERIMENTAL_DEVICE_SYNC
    enum AutomaticChatListPresentation {
        static func title(_ row: PairedChatSummaryFfi, peerDisplayName: String? = nil) -> String {
            PairedChatDisplayTitle.resolve(
                name: row.name, directPeerAccountIdHex: row.directPeerAccountIdHex,
                peerDisplayName: peerDisplayName)
        }

        static func rows(
            _ rows: [PairedChatSummaryFfi], excluding ordinaryIds: Set<String>, query: String,
            title: (PairedChatSummaryFfi) -> String = { AutomaticChatListPresentation.title($0) }
        ) -> [PairedChatSummaryFfi] {
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return rows.filter {
                !ordinaryIds.contains($0.groupIdHex)
                    && (query.isEmpty
                        || title($0).localizedStandardContains(query))
            }
        }

        static func latestMessage(_ row: PairedChatSummaryFfi, now: Date = Date()) -> PairedChatMessageFfi? {
            row.latestMessage.flatMap { message in
                message.expiresAt.map { Double($0) <= now.timeIntervalSince1970 } == true ? nil : message
            }
        }

        static func preview(
            _ row: PairedChatSummaryFfi, activeAccountIdHex: String?,
            blockedAuthors: Set<String> = [], senderName: (String) -> String,
            mentionDisplayName: MarkdownMentionResolver? = nil, now: Date = Date()
        ) -> ChatRowPreviewPresentation {
            if let peer = row.directPeerAccountIdHex, blockedAuthors.contains(peer.lowercased()) {
                return .init(prefix: nil, body: L10n.string("You blocked this user"))
            }
            guard let message = latestMessage(row, now: now) else {
                return .init(prefix: nil, body: L10n.string("No messages yet"))
            }
            guard !blockedAuthors.contains(message.authorHex.lowercased()) else {
                return .init(prefix: nil, body: L10n.string("New message"))
            }
            let body = ContentSanitizer.compactSingleLine(
                MessagePreview.body(message, mentionDisplayName: mentionDisplayName), maxLength: 140) ?? ""
            guard message.canonicalChat || message.deleted else {
                return .init(prefix: nil, body: body)
            }
            let media = ChatListAttachmentPresentation.metadata(for: message.mediaAttachments)
            let symbol = message.deleted ? nil : ChatListAttachmentPresentation.systemImageName(
                kind: media.kind, count: media.count)
            return .message(
                body: body, systemImageName: symbol, sender: message.authorHex, senderDisplayName: nil,
                isDirectMessage: row.directPeerAccountIdHex != nil,
                activeAccountIdHex: activeAccountIdHex, senderName: senderName)
        }
    }

    struct AutomaticChatListSection: View {
        let model: AccountChatListViewModel?
        let rows: [PairedChatSummaryFfi]
        let select: (String) -> Void
        var activeAccountIdHex: String?
        var blockedAuthors: Set<String> = []
        var senderName: (String) -> String = { _ in L10n.string("Unknown user") }
        var mentionDisplayName: MarkdownMentionResolver?
        var title: (PairedChatSummaryFfi) -> String = { AutomaticChatListPresentation.title($0) }

        var body: some View {
            ForEach(rows, id: \.groupIdHex) { row in
                Button {
                    select(row.groupIdHex)
                } label: {
                    ChatListRowLayout {
                        GroupAvatarBubble(
                            groupIdHex: row.groupIdHex, imageHashHex: nil,
                            seed: row.directPeerAccountIdHex ?? row.groupIdHex,
                            title: title(row), pictureURL: nil, loadPriority: .chatList)
                    } content: {
                        ChatRowDetails(
                            title: title(row),
                            preview: AutomaticChatListPresentation.preview(
                                row, activeAccountIdHex: activeAccountIdHex,
                                blockedAuthors: blockedAuthors, senderName: senderName,
                                mentionDisplayName: mentionDisplayName),
                            timestamp: AutomaticChatListPresentation.latestMessage(row).map {
                                RelativeTime.chatList(Date(timeIntervalSince1970: TimeInterval($0.createdAt)))
                            }
                        ) {}
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowInsets(ChatListRowMetrics.insets)
            }
            if model?.hasPreviousPairedPage == true {
                Button("Load previous chats") { Task { await model?.loadPreviousPaired() } }
            }
            if model?.snapshot?.nextPairedGroupIdHex != nil {
                Button("Load more chats") { Task { await model?.loadMorePaired() } }
                    .onScrollVisibilityChange(threshold: 1) { visible in
                        Task { await model?.pairedBoundaryVisibilityChanged(visible) }
                    }
                    .onDisappear { Task { await model?.pairedBoundaryVisibilityChanged(false) } }
            }
        }
    }

    #Preview {
        List { AutomaticChatListSection(model: nil, rows: [], select: { _ in }) }
    }
#endif
