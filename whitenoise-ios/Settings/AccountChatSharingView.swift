#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import SwiftUI

    /// Broad sharing between paired devices; no per-chat actions or inferred approvals.
    struct AccountChatSharingView: View {
        let model: AccountChatSharingViewModel
        @State private var task: Task<Void, Never>?
        @State private var failed = false
        var body: some View {
            Form {
                Section {
                    Text(
                        "Pairing shares all existing and future chats, chat history, and messaging between these devices."
                    )
                    Button("Load paired devices") { perform { try await model.loadTargets() } }
                    if let targets = model.targets {
                        ForEach(targets.targets, id: \.leafIndex) { target in
                            Button {
                                perform { try model.select(device: target.device) }
                            } label: {
                                HStack {
                                    Text(fingerprint(target.device)).font(.caption.monospaced())
                                    if model.selectedDevice == target.device { Image(systemName: "checkmark") }
                                }
                            }
                        }
                        if targets.targets.isEmpty { Text("No paired receiving devices.") }
                        Button("Request sharing with this device") { perform { try await model.requestSharing() } }
                            .disabled(model.selectedDevice == nil)
                    }
                    Button("Review chat sharing") { perform { try await model.loadPending() } }
                    ForEach(model.pending, id: \.id) { original in
                        Button("Review sharing request") { perform { try model.selectReview(id: original.id) } }
                    }
                }
                .disabled(model.isWorking)
                if let original = model.review, let snapshot = original.snapshot {
                    Section("Review chat sharing") {
                        Text("Source device key")
                        Text(fingerprint(snapshot.sourceDevice)).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Receiving device key")
                        Text(fingerprint(snapshot.recipientDevice)).font(.caption.monospaced()).textSelection(.enabled)
                        if snapshot.complete {
                            Text("Done")
                        } else {
                            Button("Approve sharing all chats") {
                                let revision = snapshot.revision
                                perform { try await model.approveSharing(displayedRevision: revision) }
                            }
                            .disabled(model.isWorking)
                            Button("Refresh") { perform { try model.refreshReview() } }.disabled(model.isWorking)
                        }
                        Button("Cancel") {
                            task?.cancel()
                            model.cancelReview()
                        }
                    }
                }
                if model.review == nil, model.isWorking {
                    Button("Cancel") {
                        task?.cancel()
                        model.cancelReview()
                    }
                }
                if failed || model.actionError != nil {
                    Text("Sharing action failed. Refresh or cancel.").foregroundStyle(.red)
                }
            }
            .disabled(!model.isActive)
            .onDisappear { task?.cancel() }
        }
        private func fingerprint(_ key: Data) -> String { key.map { String(format: "%02x", $0) }.joined() }
        private func perform(_ action: @escaping @MainActor () async throws -> Void) {
            guard model.isActive, !model.isWorking else { return }
            failed = false
            task?.cancel()
            task = Task {
                do { try await action() } catch {
                    if !Task.isCancelled, model.isActive { failed = true }
                }
            }
        }
    }

    struct AccountChatSharingEntryView: View {
        let acquire: @MainActor () throws -> AccountChatSharingViewModel
        @State private var model: AccountChatSharingViewModel?
        @State private var failed = false
        var body: some View {
            Button("Share all chats with paired devices") {
                do {
                    model = try acquire()
                    failed = false
                } catch { failed = true }
            }
            .sheet(isPresented: Binding(get: { model != nil }, set: { if !$0 { model = nil } })) {
                if let model { AccountChatSharingView(model: model) }
            }
            if failed { Text("Sharing action failed. Refresh or cancel.").foregroundStyle(.red) }
        }
    }
    #Preview {
        AccountChatSharingView(
            model: .init(
                readTargets: { throw MarmotKitError.AccountSharingUnsupported },
                begin: { _ in throw MarmotKitError.AccountSharingUnsupported },
                readPending: { [] }, isCurrent: { true }))
    }
    #Preview("Entry") {
        AccountChatSharingEntryView(acquire: { throw MarmotKitError.AccountSharingUnsupported })
    }
#endif
