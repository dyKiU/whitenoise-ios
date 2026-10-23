#if WN_EXPERIMENTAL_DEVICE_SYNC
    import MarmotKit
    import SwiftUI

    /// Opaque A/C transport on an already-held original; no approval or packet interpretation.
    struct DeviceEnrollmentTransportView: View {
        let model: DeviceEnrollmentViewModel?
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

                        }
                    }
                    if model.snapshot?.phase == .enrollmentComplete {
                        Text("Done")
                    } else {
                        ProgressView(L10n.string("Waiting"))
                    }
                    Section {
                        if model.transportError != nil || model.cleanupError != nil {
                            Text("Enrollment action failed. Retry or cancel.").foregroundStyle(.red)
                        }
                        Button(L10n.string(model.cleanupError == nil ? "Cancel" : "Try again")) {
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
            }
        }

        private func perform(_ operation: DeviceEnrollmentViewModel.TransportAction, revision: UInt64) {
            guard let model, model.isActive, !model.isWorking else { return }
            action = Task {
                do {
                    try await model.performTransportAction(operation, displayedRevision: revision)
                } catch {
                    // The original model retains the typed action or cleanup error.
                }
            }
        }
    }

    #Preview { NavigationStack { DeviceEnrollmentTransportView(model: nil) } }
#endif
