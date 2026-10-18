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
    }

    struct AutomaticChatListSection: View {
        let model: AccountChatListViewModel?
        let rows: [PairedChatSummaryFfi]
        let select: (String) -> Void
        var title: (PairedChatSummaryFfi) -> String = { AutomaticChatListPresentation.title($0) }

        var body: some View {
            ForEach(rows, id: \.groupIdHex) { row in
                Button {
                    select(row.groupIdHex)
                } label: {
                    ChatListRowLayout {
                        AvatarBubble(
                            seed: row.directPeerAccountIdHex ?? row.groupIdHex,
                            title: title(row), pictureURL: nil)
                    } content: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: title(row))
                                .font(.headline)
                                .lineLimit(1)
                            Text("Shared from a linked device")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
