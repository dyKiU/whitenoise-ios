import MarmotKit
import SwiftUI

#if WN_EXPERIMENTAL_DEVICE_SYNC
    /// Paired-only text lane. Ordinary conversations keep their authenticated window and media actions.
    struct AutomaticConversationView: View {
        let model: AccountConversationViewModel?
        @State private var text = ""
        @State private var sending = false
        @State private var sendFailed = false

        private var messages: [PairedChatMessageFfi] {
            model?.snapshot?.rows.compactMap { row in
                if case .pairedSource(let value) = row { return value }
                return nil
            } ?? []
        }

        private func statusLabel(_ status: LocalSendStatusFfi?) -> LocalizedStringKey {
            switch status {
            case .completed: "Sent"
            case .rejected: "Send failed"
            case .engineOwned: "Sending…"
            case .queued, nil: "Pending"
            }
        }

        var body: some View {
            VStack(alignment: .leading) {
                Text(ContentSanitizer.groupName(model?.pairedHeader?.name) ?? L10n.string("Unnamed group"))
                    .font(.headline)
                Text("Shared from a linked device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                if model?.isLoading == true {
                    ProgressView()
                }
                if model?.error != nil {
                    Text(L10n.string("Chat unavailable"))
                }
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        if model?.snapshot?.nextBefore != nil {
                            Button("Load older messages") { Task { await model?.loadOlder() } }
                        }
                        ForEach(messages, id: \.messageIdHex) { message in
                            PairedChatMessageRow(message: message)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let model {
                    ForEach(Array(model.pendingTexts.values).sorted { $0.id < $1.id }) { pending in
                        VStack(alignment: .leading) {
                            Text(verbatim: pending.text)
                            Text(statusLabel(pending.status))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if sendFailed { Text(L10n.string("Send failed")) }
                HStack {
                    TextField(L10n.string("Message"), text: $text, axis: .vertical)
                    Button(L10n.string("Send")) {
                        guard let model, !sending else { return }
                        let captured = text
                        sending = true
                        sendFailed = false
                        Task {
                            defer { sending = false }
                            do {
                                _ = try await model.sendText(captured)
                                if text == captured { text = "" }
                                await model.refreshPendingStatus()
                            } catch { sendFailed = true }
                        }
                    }
                    .disabled(
                        sending || model?.pairedHeader == nil
                            || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
        }
    }

    #Preview {
        AutomaticConversationView(model: nil)
    }
#endif
