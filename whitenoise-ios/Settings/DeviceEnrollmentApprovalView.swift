#if WN_EXPERIMENTAL_DEVICE_SYNC
    import MarmotKit
    import SwiftUI

    /// Read-only authenticated review and explicit actions on the original account-owned approval.
    struct DeviceEnrollmentApprovalView: View {
        let model: DeviceEnrollmentApprovalViewModel?
        @State private var incoming = ""
        @State private var action: Task<Void, Never>?
        @State private var readFailed = false

        var body: some View {
            Form {
                if let model {
                    if let review = model.reviewDisplay {
                        Section {
                            CopyableValueRow(title: "Source device key", value: review.sourceKey)
                            CopyableValueRow(title: "Joining device key", value: review.joiningKey)
                            LabeledContent("Existing devices", value: String(review.existingDeviceCount))
                            Text(
                                "Pairing shares all existing and future chats, chat history, and messaging between these devices."
                            )
                            WNButton(
                                title: "Approve pairing and share all chats", size: .standard,
                                isLoading: model.isWorking
                            ) {
                                perform(.approveAndShareChats, revision: review.revision)
                            }.disabled(model.isWorking)
                        }
                    } else if model.isActive, let snapshot = model.snapshot,
                        snapshot.phase == .approvedAwaitingPacket
                    {
                        Section {
                            Text("Opaque packet from the other device").font(.subheadline)
                            WNInput(
                                placeholder: L10n.string("Opaque packet from the other device"), text: $incoming,
                                kind: .multiline(2...4), surface: .filled)
                            qrImportButton(model)
                                .disabled(model.isWorking || model.cleanupError != nil)
                            WNButton(title: "Receive packet", size: .standard, isLoading: model.isWorking) {
                                perform(.receivePacket, revision: snapshot.revision)
                            }.disabled(model.isWorking)
                        }
                    } else if model.isActive, let snapshot = model.snapshot,
                        snapshot.phase == .awaitingSettlement || snapshot.phase == .settled
                    {
                        if snapshot.phase == .settled { Text("Done") } else { Text("Waiting") }
                        WNButton(title: "Refresh", size: .standard) { refreshReview() }.disabled(model.isWorking)
                    } else if model.isActive {
                        WNButton(title: "Try again", size: .standard) { refreshReview() }.disabled(model.isWorking)
                    }
                    Section {
                        if readFailed || model.actionError != nil || model.cleanupError != nil {
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
            .localizedNavigationTitle("Review enrollment")
            .navigationBarTitleDisplayMode(.inline)
            .task { refreshReview() }
            .onDisappear {
                action?.cancel()
                incoming = ""
            }
            .onChange(of: model?.isActive) { _, active in if active != true { incoming = "" } }
        }
        private func refreshReview() {
            guard let model, model.isActive, !model.isWorking else { return }
            readFailed = false
            action?.cancel()
            action = Task {
                do { try await model.refreshForDisplay() } catch {
                    if !Task.isCancelled, model.isActive { readFailed = true }
                }
            }
        }
        private func qrImportButton(_ captured: DeviceEnrollmentApprovalViewModel) -> some View {
            let revision = captured.snapshot?.revision
            let identity = "\(ObjectIdentifier(captured)):\(revision ?? 0)"
            return DevicePairingQRImportButton(isCurrent: {
                model === captured && captured.isActive && captured.cleanupError == nil
                    && captured.snapshot?.phase == .approvedAwaitingPacket && captured.snapshot?.revision == revision
            }, onScan: { incoming = $0 }).id(identity)
        }

        private func perform(_ operation: DeviceEnrollmentApprovalViewModel.ReviewAction, revision: UInt64) {
            guard let model, model.isActive, !model.isWorking else { return }
            let packet = incoming
            action = Task {
                do {
                    try await model.performReviewAction(operation, displayedRevision: revision, input: packet)
                    if model.isActive, !Task.isCancelled { incoming = "" }
                } catch {
                    // The original model retains the typed error for retry or exact cleanup.
                }
            }
        }
    }
    #Preview { NavigationStack { DeviceEnrollmentApprovalView(model: nil) } }
#endif
