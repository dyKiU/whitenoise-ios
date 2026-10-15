import MarmotKit
import SwiftUI

#if WN_EXPERIMENTAL_DEVICE_SYNC
    struct AutomaticConversationScreen: View {
        let groupIdHex: String
        @Environment(AppState.self) private var appState
        @State private var model: AccountConversationViewModel?
        @State private var blockedUsers = BlockedUsersModel()

        var body: some View {
            AutomaticConversationContent(model: model, blockedAuthors: blockedUsers.blockedAccountIds)
                .id(appState.automaticChatOwner)
                .task(id: appState.automaticChatOwner) {
                    if let model { appState.releaseAutomaticConversationModel(model, groupIdHex: groupIdHex) }
                    model = nil
                    guard let current = try? appState.makeAutomaticConversationModel(groupIdHex: groupIdHex) else {
                        return
                    }
                    model = current
                    current.start()
                }
                .task(id: appState.automaticChatOwner) {
                    await blockedUsers.run(using: appState, target: nil)
                }
                .onDisappear {
                    if let model { appState.releaseAutomaticConversationModel(model, groupIdHex: groupIdHex) }
                    model = nil
                }
        }
    }

    private struct AutomaticConversationContent: View {
        let model: AccountConversationViewModel?
        let blockedAuthors: Set<String>
        @State private var text = ""
        @State private var sending = false
        @State private var sendFailed = false

        private func statusLabel(_ status: LocalSendStatusFfi?) -> LocalizedStringKey {
            switch status {
            case .completed: "Sent"
            case .rejected: "Send failed"
            case .engineOwned: "Sending…"
            case .queued, nil: "Pending"
            }
        }

        var body: some View {
            List {
                if model?.isLoading == true { ProgressView() }
                if model?.error != nil { Text("Chat unavailable") }
                if model?.snapshot?.nextBefore != nil {
                    Button("Load older messages") { Task { await model?.loadOlder() } }
                }
                ForEach(model?.pairedMessages ?? [], id: \.messageIdHex) { message in
                    if !blockedAuthors.contains(message.authorHex.lowercased()) {
                        AutomaticPairedMessageRow(message: message)
                    }
                }
                ForEach((model.map { Array($0.pendingTexts.values) } ?? []).sorted { $0.id < $1.id }) { pending in
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(verbatim: pending.text)
                        Text(statusLabel(pending.status)).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(ContentSanitizer.groupName(model?.pairedHeader?.name) ?? L10n.string("Unnamed group"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if sendFailed { Text("Send failed").foregroundStyle(.red).font(.caption) }
                    HStack(alignment: .bottom) {
                        WNInput(placeholder: L10n.string("Message"), text: $text, kind: .multiline(1...5))
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Send")
                        .disabled(
                            sending || model?.pairedHeader == nil
                                || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }

        private func send() {
            guard let model, !sending else { return }
            let captured = text
            sending = true
            sendFailed = false
            Task {
                defer { sending = false }
                do {
                    _ = try await model.sendText(captured)
                    guard model.isCurrentOwner else { return }
                    if text == captured { text = "" }
                    await model.refreshPendingStatus()
                } catch {
                    guard model.isCurrentOwner else { return }
                    sendFailed = true
                }
            }
        }
    }

    struct AutomaticPairedMessageRow: View {
        let message: PairedChatMessageFfi?

        var body: some View {
            if let message {
                TimelineView(.periodic(from: .now, by: 1)) { clock in
                    if message.expiresAt.map({ Double($0) > clock.date.timeIntervalSince1970 }) ?? true {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(IdentityPresentation.text(accountIdHex: message.authorHex))
                                .font(.caption.weight(.semibold))
                            if message.deleted {
                                Text("Message deleted").foregroundStyle(.secondary)
                            } else if message.canonicalChat {
                                Text(verbatim: ContentSanitizer.textRun(message.content))
                                    .textSelection(.enabled)
                            } else {
                                Text("Unsupported message").foregroundStyle(.secondary)
                            }
                            if !message.deleted, !message.mediaAttachments.isEmpty {
                                Text("Attachment unavailable").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Shared from a linked device").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    #Preview("Shared conversation") {
        NavigationStack { AutomaticConversationContent(model: nil, blockedAuthors: []) }
    }

    #Preview("Shared message") { AutomaticPairedMessageRow(message: nil) }
    #Preview("Shared conversation screen") {
        AutomaticConversationScreen(groupIdHex: "preview").environment(AppState())
    }
#endif
