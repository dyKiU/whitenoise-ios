#if WN_EXPERIMENTAL_DEVICE_SYNC
    import MarmotKit
    import SwiftUI

    /// Read-only authenticated review and explicit actions on the original account-owned approval.
    struct DeviceEnrollmentApprovalView: View {
        let model: DeviceEnrollmentApprovalViewModel?
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
                    } else if model.isActive, model.snapshot?.phase == .approvedAwaitingPacket {
                        ProgressView(L10n.string("Waiting"))
                    } else if model.isActive, let snapshot = model.snapshot,
                        snapshot.phase == .awaitingSettlement || snapshot.phase == .settled
                    {
                        if snapshot.phase == .settled { Text("Done") } else { Text("Waiting") }
                    } else if model.isActive {
                        WNButton(title: "Try again", size: .standard) { refreshReview() }.disabled(model.isWorking)
                    }
                    Section {
                        if readFailed || model.actionError != nil || model.cleanupError != nil {
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
            .localizedNavigationTitle("Review enrollment")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                refreshReview()
                while !Task.isCancelled, model?.isActive == true {
                    do {
                        try await Task.sleep(for: .milliseconds(500))
                        if let model, !model.isWorking {
                            try await model.refresh()
                            if model.snapshot?.phase == .awaitingApproval, model.reviewDisplay == nil {
                                try await model.refreshForDisplay()
                            }
                            readFailed = false
                        }
                    } catch is CancellationError { return } catch { if !Task.isCancelled { readFailed = true } }
                }
            }
            .onDisappear {
                action?.cancel()
            }
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
        private func perform(_ operation: DeviceEnrollmentApprovalViewModel.ReviewAction, revision: UInt64) {
            guard let model, model.isActive, !model.isWorking else { return }
            action = Task {
                do {
                    try await model.performReviewAction(operation, displayedRevision: revision)
                } catch {
                    // The original model retains the typed error for retry or exact cleanup.
                }
            }
        }
    }
    #Preview { NavigationStack { DeviceEnrollmentApprovalView(model: nil) } }
#endif
