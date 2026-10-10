#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import SwiftUI

    struct DeviceVerificationDestinationView: View {
        @Environment(AppState.self) private var appState
        var body: some View {
            DeviceVerificationView(model: appState.makeDeviceVerificationViewModel())
                .id(appState.accountStore.deviceLinkingOwnershipIdentity)
        }
    }

    /// Only opaque transport and explicit comparison; original SDK ownership remains in Session.
    struct DeviceVerificationView: View {
        @State private var model: DeviceVerificationViewModel
        @State private var enrollment: DeviceEnrollmentViewModel?
        @State private var incoming = ""
        @State private var setup = ""
        @State private var outgoing: [DeviceLinkingOutgoingPacketFfi] = []
        @State private var selectedTarget: Data?
        @State private var actionFailed = false
        @State private var isWorking = false
        @State private var actionTask: Task<Void, Never>?

        init(model: DeviceVerificationViewModel) { _model = State(initialValue: model) }

        var body: some View {
            Form {
                if !model.verificationSupported {
                    Text("Device verification is unavailable in this build.")
                } else {
                    Section {
                        if model.owner == nil {
                            WNButton(title: "Start verification", size: .standard, isLoading: model.isStarting) {
                                perform {
                                    try await model.begin()
                                    setup = try model.setupPacket().base64EncodedString()
                                }
                            }
                            .disabled(isWorking || !model.isActive || model.cleanupRequired)
                            if !model.targets.isEmpty {
                                Picker("Existing device group", selection: $selectedTarget) {
                                    Text("Choose a target").tag(Optional<Data>.none)
                                    ForEach(Array(model.targets.enumerated()), id: \.offset) { index, target in
                                        Text(L10n.formatted("Target %lld", index + 1)).tag(Optional(target.selector))
                                    }
                                }
                            }
                        }
                    } footer: {
                        if !model.enrollmentSupported {
                            Text("Verification only. Device enrollment is not available in this build.")
                        }
                    }
                    if !setup.isEmpty {
                        Section {
                            CopyableValueRow(title: "Setup packet", value: setup)
                        }
                    }
                    Section {
                        Text("Opaque packet from the other device")
                            .font(.subheadline)
                        WNInput(
                            placeholder: L10n.string("Opaque packet from the other device"), text: $incoming,
                            kind: .multiline(2...4), surface: .filled
                        )
                        .disabled(isWorking || !model.isActive)
                        if model.owner == nil {
                            if model.offersFirstDeviceSetupAttempt {
                                WNButton(
                                    title: "Approve first-device setup", size: .standard,
                                    isLoading: model.isStarting
                                ) {
                                    perform {
                                        try await model.approveFirstDeviceSetup(request: decodedPacket())
                                        setup = try model.setupPacket().base64EncodedString()
                                        incoming = ""
                                    }
                                }
                                .disabled(isWorking || !model.isActive || model.cleanupRequired)
                            } else if !model.targets.isEmpty {
                                WNButton(title: "Approve setup", size: .standard, isLoading: model.isStarting) {
                                    perform {
                                        guard let selectedTarget else {
                                            throw DeviceVerificationPacketInput.Error.invalidPacket
                                        }
                                        try await model.approve(request: decodedPacket(), target: selectedTarget)
                                        setup = try model.setupPacket().base64EncodedString()
                                        incoming = ""
                                    }
                                }
                                .disabled(
                                    selectedTarget == nil || isWorking || !model.isActive || model.cleanupRequired)
                            }
                            if !model.hasLoadedTargets && !model.isReadingTargets && actionFailed {
                                WNButton(title: "Try again", emphasis: .secondary, size: .standard) {
                                    perform { try await model.loadTargets() }
                                }
                                .disabled(isWorking || !model.isActive)
                            }
                        } else {
                            WNButton(title: "Receive setup", emphasis: .secondary, size: .standard) {
                                perform {
                                    try await model.receiveSetupPacket(decodedPacket())
                                    incoming = ""
                                }
                            }
                            .disabled(isWorking || !model.isActive)
                            WNButton(title: "Receive packet", emphasis: .secondary, size: .standard) {
                                perform {
                                    try await model.receivePacket(decodedPacket())
                                    incoming = ""
                                }
                            }
                            .disabled(isWorking || !model.isActive)
                            WNButton(title: "Read outgoing packets", emphasis: .secondary, size: .standard) {
                                perform { outgoing = try await model.outgoingPackets() }
                            }
                            .disabled(isWorking || !model.isActive)
                        }
                    }
                    if let snapshot = model.snapshot, let decimals = snapshot.decimals,
                        snapshot.phase == .comparisonAvailable || snapshot.phase == .awaitingPeerVerification
                    {
                        Section {
                            Text(String(format: "%04d · %04d · %04d", decimals.first, decimals.second, decimals.third))
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
                    if model.snapshot?.phase == .verificationCompleteEnrollmentPending {
                        if model.enrollmentSupported {
                            WNButton(title: "Device enrollment", size: .standard) {
                                perform { enrollment = try model.enrollmentTransport() }
                            }
                            .disabled(isWorking || !model.isActive)
                        } else {
                            Text("Verification complete. Enrollment remains unavailable.")
                        }
                    }
                    ForEach(Array(outgoing.enumerated()), id: \.offset) { _, packet in
                        Section {
                            WNCopyButton(
                                value: packet.bytes.base64EncodedString(), accessibilityTitle: L10n.string("Copy")
                            ) { copied in
                                Label(
                                    copied ? L10n.string("Copied") : L10n.string("Copy"),
                                    systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            WNButton(title: "Delivered to the other device", emphasis: .secondary, size: .standard) {
                                perform {
                                    try await model.acknowledgePacket(packet.acknowledgementId)
                                    outgoing.removeAll { $0.acknowledgementId == packet.acknowledgementId }
                                }
                            }
                            .disabled(isWorking || !model.isActive)
                        }
                    }
                    Section {
                        Button("Cancel", action: cancel)
                            .disabled(!model.isActive)
                        if actionFailed || model.cleanupRequired {
                            Text("Verification action failed. Retry or cancel.").foregroundStyle(.red)
                        }
                    }
                }
            }
            .localizedNavigationTitle("Device verification")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: Binding(get: { enrollment != nil }, set: { if !$0 { enrollment = nil } })) {
                NavigationStack { DeviceEnrollmentTransportView(model: enrollment) }
            }
            .task {
                guard model.verificationSupported, model.isActive else { return }
                do { try await model.loadTargets() } catch {
                    if !Task.isCancelled, model.isActive { actionFailed = true }
                }
            }
            .onDisappear { actionTask?.cancel() }
            .onChange(of: model.isActive) { _, active in if !active { clearPackets() } }
        }

        private func decodedPacket() throws -> Data { try DeviceVerificationPacketInput.decode(incoming) }

        private func clearPackets() {
            enrollment = nil
            incoming = ""
            setup = ""
            outgoing = []
            selectedTarget = nil
        }

        private func cancel() {
            actionTask?.cancel()
            clearPackets()
            actionTask = Task {
                do { try await model.cancel() } catch { if !Task.isCancelled { actionFailed = true } }
            }
        }

        private func perform(_ action: @escaping @MainActor () async throws -> Void) {
            guard !isWorking else { return }
            actionFailed = false
            isWorking = true
            actionTask = Task {
                defer { isWorking = false }
                do { try await action() } catch {
                    if !Task.isCancelled, model.isActive { actionFailed = true }
                }
            }
        }
    }

    #Preview {
        NavigationStack { DeviceVerificationView(model: .init()) }
    }
#endif
