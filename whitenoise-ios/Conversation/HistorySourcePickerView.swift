#if WN_EXPERIMENTAL_DEVICE_SYNC
    import MarmotKit
    import SwiftUI

    struct HistorySourceConversationEntry: View {
        let acquire: @MainActor () async throws -> HistorySourcePickerModel
        let release: @MainActor (HistorySourcePickerModel) -> Void
        @State private var model: HistorySourcePickerModel?
        @State private var action: Task<Void, Never>?
        @State private var failed = false
        @State private var presented = false

        var body: some View {
            HStack {
                Spacer()
                Button("Send chat history") {
                    action = Task {
                        do {
                            let value = try await acquire()
                            guard !Task.isCancelled else {
                                release(value)
                                return
                            }
                            model = value
                            failed = false
                            presented = true
                        } catch { failed = !Task.isCancelled }
                        action = nil
                    }
                }.disabled(action != nil)
                    .accessibilityIdentifier("conversation.historySource.open")
                if failed { Text("History request unavailable. Retry or cancel.").font(.caption) }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .sheet(isPresented: $presented, onDismiss: retire) {
                if let model { HistorySourcePickerView(model: model) }
            }
            .onDisappear { retire() }
        }
        private func retire() {
            action?.cancel()
            if let model { release(model) }
            model = nil
        }
    }

    struct HistorySourcePickerView: View {
        let model: HistorySourcePickerModel
        @Environment(\.dismiss) private var dismiss
        @State private var action: Task<Void, Never>?
        @State private var failed = false

        var body: some View {
            NavigationStack {
                Form {
                    if model.isActive {
                        if model.hasOriginal {
                            if let review = model.review {
                                HistoryConsentReviewDetails(review: review)
                            }
                            Section {
                                if let review = model.review {
                                    WNButton(title: "Continue", size: .standard, isLoading: model.isWorking) {
                                        let revision = review.revision
                                        perform { try await model.continueTransfer(displayedRevision: revision) }
                                    }.disabled(model.isWorking || review.complete)
                                        .accessibilityIdentifier("history-source.continue")
                                }
                                WNButton(title: "Refresh", emphasis: .secondary, size: .standard) {
                                    perform { try await model.refresh() }
                                }.disabled(model.isWorking)
                                    .accessibilityIdentifier("history-source.refresh")
                            }
                        } else {
                            Section {
                                if model.recipients.isEmpty, !model.isWorking, !model.failed {
                                    Text("No eligible receiving devices.")
                                }
                                ForEach(model.recipients, id: \.device) { choice in
                                    Button {
                                        perform { try model.select(device: choice.device) }
                                    } label: {
                                        HStack {
                                            Text(verbatim: HistoryConsentReviewPresentation.fingerprint(choice.device))
                                                .font(.caption.monospaced()).textSelection(.enabled)
                                            if model.selectedDevice == choice.device {
                                                Image(systemName: "checkmark").accessibilityHidden(true)
                                            }
                                        }
                                    }.disabled(model.isWorking)
                                        .accessibilityIdentifier("history-source.choice-\(choice.leafIndex)")
                                }
                                WNButton(title: "Request history transfer", size: .standard, isLoading: model.isWorking)
                                {
                                    perform { try await model.begin() }
                                }.disabled(model.isWorking || model.selectedDevice == nil)
                                    .accessibilityIdentifier("history-source.request")
                                WNButton(title: "Refresh", emphasis: .secondary, size: .standard) {
                                    perform { try await model.loadRecipients() }
                                }.disabled(model.isWorking)
                            } header: {
                                Text("Receiving device key")
                            } footer: {
                                Text("Choose a linked device to receive a snapshot of this chat.")
                            }
                        }
                        Section {
                            WNButton(title: "Cancel", emphasis: .secondary, size: .standard) {
                                action?.cancel()
                                model.cancel()
                            }.accessibilityIdentifier("history-source.cancel")
                        }
                    }
                    if failed || model.failed || !model.isActive {
                        Text("History request unavailable. Retry or cancel.").foregroundStyle(.red)
                    }
                }
                .localizedNavigationTitle("History transfer")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
                .task { perform { try await model.loadRecipients() } }
                .onDisappear { action?.cancel() }
            }
        }
        private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
            guard action == nil else { return }
            action = Task {
                do {
                    try await operation()
                    failed = false
                } catch { failed = !Task.isCancelled }
                action = nil
            }
        }
    }

    #Preview {
        HistorySourcePickerView(
            model: HistorySourcePickerModel(
                groupIdHex: "", readRecipients: { [] },
                beginOriginal: { _ in throw MarmotKitError.HistoryTransferNotReady }, isCurrent: { true }))
    }
#endif
