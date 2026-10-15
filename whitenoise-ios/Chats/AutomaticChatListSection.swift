import MarmotKit
import SwiftUI

#if WN_EXPERIMENTAL_DEVICE_SYNC
    enum AutomaticChatListPresentation {
        static func title(_ row: PairedChatSummaryFfi, peerDisplayName: String? = nil) -> String {
            PairedChatDisplayTitle.resolve(
                name: row.name, directPeerAccountIdHex: row.directPeerAccountIdHex, peerDisplayName: peerDisplayName)
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
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: title(row))
                                .font(.headline)
                                .lineLimit(2)
                            Text("Shared from a linked device")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
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
