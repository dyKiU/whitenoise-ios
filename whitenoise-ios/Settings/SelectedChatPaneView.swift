#if WN_EXPERIMENTAL_DEVICE_SYNC
    import MarmotKit
    import SwiftUI

    /// The composition boundary injects one actual account-owned model, never a reconstructed handle.
    struct SelectedChatEntryView: View {
        let acquire: @MainActor () throws -> SelectedChatTransferViewModel
        let groupIdHex: String?
        @State private var model: SelectedChatTransferViewModel?
        @State private var failed = false

        init(
            model: SelectedChatTransferViewModel?, groupIdHex: String?,
            acquire: @escaping @MainActor () throws -> SelectedChatTransferViewModel
        ) {
            _model = State(initialValue: model)
            self.groupIdHex = groupIdHex
            self.acquire = acquire
        }
        var body: some View {
            Group {
                if let model, model.isActive {
                    SelectedChatPaneView(model: model, groupIdHex: groupIdHex)
                        .id(ObjectIdentifier(model))
                } else {
                    Form {
                        if failed { Text("Chat copy action failed. Retry or cancel.").foregroundStyle(.red) }
                        WNButton(title: "Try again", size: .standard) { acquireModel() }
                    }
                }
            }
            .localizedNavigationTitle("Selected chat transfer")
            .navigationBarTitleDisplayMode(.inline)
            .task { acquireModel() }
        }
        private func acquireModel() {
            failed = false
            do { model = try acquire() } catch {
                model = nil
                failed = true
            }
        }
    }

    struct SelectedChatPaneView: View {
        let model: SelectedChatTransferViewModel
        let groupIdHex: String?
        @State private var selectedTarget: Data?
        @State private var incoming = ""
        @State private var failed = false
        @State private var action: Task<Void, Never>?

        var body: some View {
            Form {
                if model.isActive {
                    if let copy = model.copy {
                        SelectedChatCopyPaneView(model: copy, groupIdHex: model.copyGroupIdHex)
                    } else if let groupIdHex {
                        Section {
                            CopyableValueRow(title: "Chat ID", value: groupIdHex)
                            Picker(L10n.string("Linked device roster"), selection: $selectedTarget) {
                                Text("Select").tag(Data?.none)
                                ForEach(Array(model.targets.enumerated()), id: \.offset) { _, target in
                                    Text(target.selector.map { String(format: "%02x", $0) }.joined())
                                        .tag(Optional(target.selector))
                                }
                            }
                            if model.targets.isEmpty { Text("No linked device target is available.") }
                            WNButton(title: "Refresh", emphasis: .secondary, size: .standard) {
                                selectedTarget = nil
                                perform { try await model.loadTargets() }
                            }.disabled(model.isWorking)
                            WNButton(title: "Copy selected chat", size: .standard, isLoading: model.isWorking) {
                                guard let selectedTarget else { return }
                                perform {
                                    try await model.begin(groupIdHex: groupIdHex, linkedRosterSelector: selectedTarget)
                                }
                            }.disabled(model.isWorking || selectedTarget == nil)
                        }
                    }
                    if let consent = model.consent {
                        SelectedChatConsentPaneView(model: consent)
                    } else {
                        Section {
                            Text("Opaque chat copy request").font(.subheadline)
                            WNInput(
                                placeholder: L10n.string("Opaque chat copy request"), text: $incoming,
                                kind: .multiline(2...4), surface: .filled)
                            WNButton(title: "Receive chat copy request", size: .standard, isLoading: model.isWorking) {
                                let input = incoming
                                perform {
                                    try await model.receive(input: input)
                                    if model.isActive, !Task.isCancelled { incoming = "" }
                                }
                            }.disabled(model.isWorking)
                        }
                    }
                    if failed { Text("Chat copy action failed. Retry or cancel.").foregroundStyle(.red) }
                } else {
                    Text("Selected chat transfer is unavailable.")
                }
            }
            .task {
                if groupIdHex != nil, model.copy == nil { perform { try await model.loadTargets() } }
            }
            .onDisappear {
                action?.cancel()
                incoming = ""
                selectedTarget = nil
            }
            .onChange(of: model.isActive) { _, active in
                if !active {
                    action?.cancel()
                    incoming = ""
                    selectedTarget = nil
                }
            }
        }
        private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
            guard model.isActive, !model.isWorking else { return }
            failed = false
            action?.cancel()
            action = Task {
                do { try await operation() } catch { if model.isActive, !Task.isCancelled { failed = true } }
            }
        }
    }

    struct SelectedChatCopyPaneView: View {
        let model: SelectedChatCopyViewModel?
        let groupIdHex: String?
        @State private var incoming = ""
        @State private var failed = false
        @State private var action: Task<Void, Never>?
        var body: some View {
            Section {
                if let model {
                    if let groupIdHex { CopyableValueRow(title: "Chat ID", value: groupIdHex) }
                    if let snapshot = model.snapshot {
                        LabeledContent("Revision", value: String(snapshot.revision))
                        if snapshot.phase == .awaitingSiblingConsent {
                            LabeledContent("Consenting devices", value: String(snapshot.consentingSiblingCount))
                            LabeledContent("Offered devices", value: String(snapshot.offeredSiblingCount))
                            WNButton(title: "Export chat copy request", size: .standard) {
                                perform(.request, revision: snapshot.revision)
                            }.disabled(model.isWorking)
                            if let outgoing = model.outgoingPacket { packetCopy(outgoing) }
                            WNInput(
                                placeholder: L10n.string("Opaque packet from the other device"), text: $incoming,
                                kind: .multiline(2...4), surface: .filled)
                            WNButton(title: "Receive chat consent", emphasis: .secondary, size: .standard) {
                                perform(.consent, revision: snapshot.revision)
                            }.disabled(model.isWorking)
                            WNButton(title: "Receive chat offer", emphasis: .secondary, size: .standard) {
                                perform(.offer, revision: snapshot.revision)
                            }.disabled(model.isWorking)
                            WNButton(title: "Continue chat copy", size: .standard) {
                                perform(.continueCopy, revision: snapshot.revision)
                            }.disabled(model.isWorking)
                        } else if snapshot.phase == .inviteConfirmed {
                            Text("Chat copy confirmed")
                        } else {
                            Text("Chat copy is no longer active.")
                        }
                    }
                    WNButton(title: "Refresh", emphasis: .secondary, size: .standard) { refresh() }
                        .disabled(model.isWorking || !model.isActive)
                    if failed || model.actionError != nil || model.cleanupError != nil {
                        Text("Chat copy action failed. Retry or cancel.").foregroundStyle(.red)
                    }
                    Button(L10n.string(model.cleanupError == nil ? "Cancel" : "Try again")) {
                        incoming = ""
                        action?.cancel()
                        action = Task { do { try await model.cancel() } catch { failed = true } }
                    }
                } else {
                    Text("Selected chat transfer is unavailable.")
                }
            }
            .onDisappear {
                action?.cancel()
                incoming = ""
            }
            .onChange(of: model?.isActive) { _, active in if active != true { incoming = "" } }
            .onChange(of: model?.snapshot?.revision) { _, _ in incoming = "" }
        }
        private func refresh() {
            guard let model, model.isActive, !model.isWorking else { return }
            failed = false
            action?.cancel()
            action = Task { do { try await model.refresh() } catch { if !Task.isCancelled { failed = true } } }
        }
        private func perform(_ operation: SelectedChatCopyViewModel.Action, revision: UInt64) {
            guard let model, model.isActive, !model.isWorking else { return }
            let packet = incoming
            failed = false
            action = Task {
                do {
                    try await model.perform(operation, displayedRevision: revision, input: packet)
                    if model.isActive, !Task.isCancelled { incoming = "" }
                } catch { if !Task.isCancelled { failed = true } }
            }
        }
        private func packetCopy(_ packet: String) -> some View {
            WNCopyButton(value: packet, accessibilityTitle: L10n.string("Copy")) { copied in
                Label(
                    copied ? L10n.string("Copied") : L10n.string("Copy"),
                    systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        }
    }

    struct SelectedChatConsentPaneView: View {
        let model: SelectedChatConsentViewModel?
        @State private var failed = false
        @State private var action: Task<Void, Never>?
        var body: some View {
            Section {
                if let model {
                    if let snapshot = model.snapshot {
                        CopyableValueRow(
                            title: "Authenticated chat selector",
                            value: snapshot.chatSelector.map { String(format: "%02x", $0) }.joined())
                        LabeledContent("Revision", value: String(snapshot.revision))
                        if snapshot.phase == .awaitingApproval {
                            Text("Approve only this chat copy request.")
                            WNButton(title: "Approve", size: .standard, isLoading: model.isWorking) {
                                perform(.approve, revision: snapshot.revision)
                            }.disabled(model.isWorking)
                        } else if snapshot.phase == .approved {
                            WNButton(title: "Export chat consent", size: .standard) {
                                perform(.response, revision: snapshot.revision)
                            }.disabled(model.isWorking)
                            WNButton(title: "Export chat offer", size: .standard) {
                                perform(.offer, revision: snapshot.revision)
                            }.disabled(model.isWorking)
                            if let outgoing = model.outgoingPacket {
                                WNCopyButton(value: outgoing, accessibilityTitle: L10n.string("Copy")) { copied in
                                    Label(
                                        copied ? L10n.string("Copied") : L10n.string("Copy"),
                                        systemImage: copied ? "checkmark" : "doc.on.doc")
                                }
                            }
                        } else {
                            Text("Chat copy is no longer active.")
                        }
                    }
                    WNButton(title: "Refresh", emphasis: .secondary, size: .standard) { refresh() }
                        .disabled(model.isWorking || !model.isActive)
                    if failed || model.actionError != nil || model.cleanupError != nil {
                        Text("Chat copy action failed. Retry or cancel.").foregroundStyle(.red)
                    }
                    Button(L10n.string(model.cleanupError == nil ? "Cancel" : "Try again")) {
                        action?.cancel()
                        action = Task { do { try await model.cancel() } catch { failed = true } }
                    }
                } else {
                    Text("Selected chat transfer is unavailable.")
                }
            }
            .onDisappear { action?.cancel() }
        }
        private func refresh() {
            guard let model, model.isActive, !model.isWorking else { return }
            failed = false
            action?.cancel()
            action = Task { do { try await model.refresh() } catch { if !Task.isCancelled { failed = true } } }
        }
        private func perform(_ operation: SelectedChatConsentViewModel.Action, revision: UInt64) {
            guard let model, model.isActive, !model.isWorking else { return }
            failed = false
            action = Task {
                do { try await model.perform(operation, displayedRevision: revision) } catch {
                    if !Task.isCancelled { failed = true }
                }
            }
        }
    }

    #Preview("Entry") {
        NavigationStack {
            SelectedChatEntryView(model: nil, groupIdHex: nil, acquire: { throw MarmotKitError.SelectedChatCopyClosed })
        }
    }
    #Preview("Copy") { Form { SelectedChatCopyPaneView(model: nil, groupIdHex: nil) } }
    #Preview("Consent") { Form { SelectedChatConsentPaneView(model: nil) } }
    #Preview("Transfer") {
        NavigationStack {
            SelectedChatPaneView(
                model: .init(
                    begin: { _, _ in throw MarmotKitError.SelectedChatCopyUnsupported },
                    receive: { _ in throw MarmotKitError.SelectedChatCopyUnsupported },
                    targets: { [] }, isCurrent: { true }), groupIdHex: nil)
        }
    }
#endif
