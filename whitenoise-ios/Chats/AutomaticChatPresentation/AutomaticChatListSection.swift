import MarmotKit
import SwiftUI

#if WN_EXPERIMENTAL_DEVICE_SYNC
    struct AutomaticChatListSection: View {
        let model: AccountChatListViewModel?
        let searchText: String
        let excludedGroupIds: Set<String>
        let select: (String) -> Void

        private var rows: [PairedChatSummaryFfi] {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return (model?.pairedRows ?? []).filter { row in
                !excludedGroupIds.contains(row.groupIdHex)
                    && (query.isEmpty
                        || (ContentSanitizer.groupName(row.name) ?? "")
                            .localizedStandardContains(query))
            }
        }

        var body: some View {
            ForEach(rows, id: \.groupIdHex) { row in
                Button {
                    select(row.groupIdHex)
                } label: {
                    HStack {
                        Image(systemName: "link")
                        VStack(alignment: .leading) {
                            Text(ContentSanitizer.groupName(row.name) ?? L10n.string("Unnamed group"))
                                .lineLimit(1)
                            Text(L10n.string("Shared from a linked device"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if model?.hasPreviousPairedPage == true || model?.snapshot?.nextPairedGroupIdHex != nil {
                HStack {
                    if model?.hasPreviousPairedPage == true {
                        Button(L10n.string("Back")) { Task { await model?.loadPreviousPaired() } }
                    }
                    Spacer()
                    if model?.snapshot?.nextPairedGroupIdHex != nil {
                        Button(L10n.string("Next")) { Task { await model?.loadMorePaired() } }
                    }
                }
            }
            if model?.snapshot?.nextPairedGroupIdHex != nil {
                Color.clear
                    .frame(height: 1)
                    .onScrollVisibilityChange(threshold: 1) { visible in
                        Task { await model?.pairedBoundaryVisibilityChanged(visible) }
                    }
                    .onDisappear {
                        Task { await model?.pairedBoundaryVisibilityChanged(false) }
                    }
            }
        }
    }

    #Preview {
        AutomaticChatListSection(model: nil, searchText: "", excludedGroupIds: [], select: { _ in })
    }
#endif
