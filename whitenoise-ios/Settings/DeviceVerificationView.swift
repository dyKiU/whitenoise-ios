#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import OSLog
    import SwiftUI

    struct DeviceVerificationDestinationView: View {
        @Environment(AppState.self) private var appState
        @Environment(\.dismiss) private var dismiss
        @State private var cancellation = DeviceVerificationCancellation()
        var body: some View {
            Group {
                if let generation = appState.runtimeEventsGeneration {
                    DeviceVerificationView(
                        model: appState.makeDeviceVerificationViewModel(),
                        cancellation: cancellation, onCancelled: { dismiss() })
                        .id(generation)
                        .id(appState.accountStore.deviceLinkingOwnershipIdentity)
                } else {
                    ProgressView(L10n.string("Connecting…"))
                }
            }
        }
    }

    /// Only opaque transport and explicit comparison; original SDK ownership remains in Session.
    struct DeviceVerificationView: View {
        @Environment(\.scenePhase) private var scenePhase
        @State private var model: DeviceVerificationViewModel
        @State private var enrollment: DeviceEnrollmentViewModel?
        @State private var approval: DeviceEnrollmentApprovalViewModel?
        @State private var setup = ""
        @State private var actionFailed = false
        @State private var isPerformingAction = false
        @State private var cancellation: DeviceVerificationCancellation
        private let onCancelled: @MainActor () -> Void
        private var isWorking: Bool { isPerformingAction || cancellation.isWorking }
        @State private var actionTask: Task<Void, Never>?
        private static let diagnostics = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios",
            category: "device-verification"
        )

        init(
            model: DeviceVerificationViewModel,
            cancellation: DeviceVerificationCancellation? = nil,
            onCancelled: @escaping @MainActor () -> Void = {}
        ) {
            _model = State(initialValue: model)
            _cancellation = State(initialValue: cancellation ?? DeviceVerificationCancellation())
            self.onCancelled = onCancelled
        }

        var body: some View {
            Form {
                if !model.verificationSupported {
                    Text("Device verification is unavailable in this build.")
                } else {
                    if model.enrollmentSupported, !model.targets.isEmpty {
                        Section {
                            WNButton(title: "Review enrollment", size: .standard) {
                                perform { approval = try await model.enrollmentApproval() }
                            }.disabled(isWorking || !model.isActive || model.cleanupRequired)
                        }
                    }
                    Section {
                        if model.owner == nil {
                            WNButton(title: "Show pairing QR code", size: .standard, isLoading: model.isStarting) {
                                perform {
                                    try await model.begin()
                                    setup = try model.setupPacket().base64EncodedString()
                                }
                            }
                            .disabled(isWorking || !model.isActive || model.cleanupRequired)
                        }
                    } footer: {
                        if !model.enrollmentSupported {
                            Text("Verification only. Device enrollment is not available in this build.")
                        }
                    }
                    if !setup.isEmpty,
                        model.snapshot?.phase == nil || model.snapshot?.phase == .awaitingSetup
                            || model.snapshot?.phase == .awaitingPeer
                    {
                        Section {
                            DevicePairingQRCard(packet: setup)
                        }
                    }
                    if model.owner == nil {
                        Section {
                            DevicePairingQRImportButton(
                                title: "Scan and sync",
                                isCurrent: { model.isActive && model.owner == nil && !model.cleanupRequired && !isWorking },
                                onStart: { actionFailed = false }
                            ) { packet in
                                guard scenePhase == .active, model.isActive, model.owner == nil,
                                      !model.cleanupRequired, !isWorking else { return }
                                perform { try await model.scanAndSync(request: decodedPacket(packet)) }
                            }
                            .disabled(isWorking || !model.isActive || model.cleanupRequired)
                        }
                    }
                    if let snapshot = model.snapshot, let decimals = snapshot.decimals,
                        snapshot.phase == .comparisonAvailable || snapshot.phase == .awaitingPeerVerification
                    {
                        Section {
                            Text(
                                String(
                                    format: "%04d · %04d · %04d", decimals.first, decimals.second, decimals.third)
                            )
                            .font(.title2.monospaced())
                            .textSelection(.enabled)
                            .accessibilityLabel(Text("Compare these numbers on both devices before confirming."))
                            .accessibilityValue(
                                Text(
                                    String(
                                        format: "%04d · %04d · %04d", decimals.first, decimals.second,
                                        decimals.third)))
                            Text("Compare these numbers on both devices before confirming.")
                            WNButton(title: "The numbers match", size: .standard) {
                                // The action retains this rendered snapshot, never a newer revision.
                                perform { try await model.confirm(displayedRevision: snapshot.revision) }
                            }
                            .disabled(snapshot.phase != .comparisonAvailable || isWorking || !model.isActive)
                        }
                    }
                    if let snapshot = model.snapshot, snapshot.phase == .verificationCompleteEnrollmentPending {
                        if model.enrollmentSupported {
                            Text(
                                "Pairing shares all existing and future chats, chat history, and messaging between these devices."
                            )
                            WNButton(
                                title: "Pair and share all chats", size: .standard,
                                isLoading: isWorking || enrollment?.sharingApprovalSubmitted == true
                            ) {
                                perform {
                                    let original = try model.enrollmentTransport()
                                    enrollment = original
                                    try await original.performTransportAction(
                                        .shareChats, displayedRevision: snapshot.revision)
                                    Self.diagnostics.notice("Pairing sharing approval accepted")
                                }
                            }.disabled(
                                isWorking || !model.isActive || enrollment?.sharingApprovalSubmitted == true)
                        } else {
                            Text("Verification complete. Enrollment remains unavailable.")
                        }
                    }
                    if let snapshot = model.snapshot {
                        if snapshot.phase == .enrollmentComplete {
                            Text("Done")
                        } else if snapshot.phase == .cancelled || snapshot.phase == .expired
                            || snapshot.phase == .failed
                        {
                            Text("Verification action failed. Retry or cancel.").foregroundStyle(.red)
                        } else if snapshot.decimals == nil
                            && snapshot.phase != .verificationCompleteEnrollmentPending
                        {
                            ProgressView(L10n.string("Waiting"))
                        }
                    }
                    Section {
                        Button("Cancel", action: cancel)
                            .disabled(!model.isActive || cancellation.isWorking)
                        if cancellation.isWorking { ProgressView(L10n.string("Waiting")) }
                        if actionFailed || model.cleanupRequired || cancellation.failure != nil {
                            Text("Verification action failed. Retry or cancel.").foregroundStyle(.red)
                        }
                    }
                }
            }
            .localizedNavigationTitle("Device verification")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: Binding(get: { approval != nil }, set: { if !$0 { approval = nil } })) {
                NavigationStack { DeviceEnrollmentApprovalView(model: approval) }
            }
            .task {
                guard model.verificationSupported, model.isActive else { return }
                do {
                    try await model.loadTargets()
                    if model.owner != nil { setup = try model.setupPacket().base64EncodedString() }
                } catch {
                    if !Task.isCancelled, model.isActive { actionFailed = true }
                }
            }
            .onDisappear { actionTask?.cancel() }
            .onChange(of: model.isActive) { _, active in if !active { clearPackets() } }
            .onChange(of: model.snapshot?.phase) { _, phase in
                if let phase {
                    Self.diagnostics.notice("Pairing phase=\(String(describing: phase), privacy: .public)")
                }
                if phase == .cancelled || phase == .expired || phase == .failed { setup = "" }
            }
        }

        private func decodedPacket(_ packet: String) throws -> Data {
            let bytes = try DeviceVerificationPacketInput.decode(packet)
            guard bytes.count <= 1024, String(data: bytes, encoding: .utf8)?.hasPrefix("WNPAIR1:") == true
            else { throw DeviceVerificationPacketInput.Error.invalidPacket }
            return bytes
        }

        private func clearPackets() {
            enrollment = nil
            approval = nil
            setup = ""
        }

        private func cancel() {
            actionTask?.cancel()
            clearPackets()
            // Cleanup outlives the ownership change that rebuilds this child view.
            Task {
                await cancellation.cancel(operation: { try await model.cancel() }, onCancelled: onCancelled)
            }
        }

        private func perform(_ action: @escaping @MainActor () async throws -> Void) {
            guard !isWorking else { return }
            actionFailed = false
            isPerformingAction = true
            actionTask = Task {
                defer { isPerformingAction = false }
                do { try await action() } catch {
                    if !Task.isCancelled, model.isActive {
                        actionFailed = true
                        Self.diagnostics.error(
                            "Verification action failed category=\(DeviceVerificationFailure(error).rawValue, privacy: .public)"
                        )
                    }
                }
            }
        }
    }

    #Preview {
        NavigationStack { DeviceVerificationView(model: .init()) }
    }
#endif
