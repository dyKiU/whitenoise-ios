#if WN_EXPERIMENTAL_DEVICE_SYNC
    import MarmotKit
    import SwiftUI

    /// Opaque A/C transport on an already-held original; no approval or packet interpretation.
    struct DeviceEnrollmentTransportView: View {
        let model: DeviceEnrollmentViewModel?
        @State private var incoming = ""
        @State private var action: Task<Void, Never>?

        var body: some View {
            Form {
                if let model {
                    if model.enrollmentSupported, model.isActive,
                        let snapshot = model.snapshot, snapshot.phase == .verificationCompleteEnrollmentPending
                    {
                        Section {
                            Text(
                                "Pairing shares all existing and future chats, chat history, and messaging between these devices."
                            )
                            WNButton(title: "Pair and share all chats", size: .standard, isLoading: model.isWorking) {
                                perform(.shareChats, revision: snapshot.revision)
                            }.disabled(model.isWorking)
                            WNButton(title: "Read outgoing packets", emphasis: .secondary, size: .standard) {
                                perform(.exportPacket, revision: snapshot.revision)
                            }.disabled(model.isWorking)
                            if let outgoing = model.outgoingPacket {
                                WNCopyButton(value: outgoing, accessibilityTitle: L10n.string("Copy")) { copied in
                                    Label(
                                        copied ? L10n.string("Copied") : L10n.string("Copy"),
                                        systemImage: copied ? "checkmark" : "doc.on.doc")
                                }
                            }
                            Text("Opaque packet from the other device").font(.subheadline)
                            WNInput(
                                placeholder: L10n.string("Opaque packet from the other device"), text: $incoming,
                                kind: .multiline(2...4), surface: .filled
                            )
                            .disabled(model.isWorking)
                            WNButton(title: "Receive packet", emphasis: .secondary, size: .standard) {
                                perform(.receivePacket, revision: snapshot.revision)
                            }.disabled(model.isWorking)
                            WNButton(title: "Finalize enrollment", size: .standard) {
                                perform(.finalizeLinking, revision: snapshot.revision)
                            }.disabled(model.isWorking)
                        }
                    }
                    Section {
                        if model.transportError != nil || model.cleanupError != nil {
                            Text("Enrollment action failed. Retry or cancel.").foregroundStyle(.red)
                        }
                        Button(L10n.string(model.cleanupError == nil ? "Cancel" : "Try again")) {
                            incoming = ""
                            action?.cancel()
                            action = Task { try? await model.cancel() }
                        }
                    }
                } else {
                    Text("Verification complete. Enrollment remains unavailable.")
                }
            }
            .navigationTitle("Device enrollment")
            .onDisappear {
                action?.cancel()
                incoming = ""
            }
            .onChange(of: model?.isActive) { _, active in if active != true { incoming = "" } }
        }

        private func perform(_ operation: DeviceEnrollmentViewModel.TransportAction, revision: UInt64) {
            guard let model, model.isActive, !model.isWorking else { return }
            let input = incoming
            action = Task {
                do {
                    try await model.performTransportAction(operation, displayedRevision: revision, input: input)
                    if model.isActive, !Task.isCancelled, operation == .receivePacket { incoming = "" }
                } catch {
                    // The original model retains the typed action or cleanup error.
                }
            }
        }
    }

    #Preview { NavigationStack { DeviceEnrollmentTransportView(model: nil) } }
#endif
