#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    /// Native lifetime for one original SDK session; observations never restore permission.
    @MainActor
    @Observable
    final class DeviceLinkingAccountScope: DeviceVerificationSession {
        let accountRef: String
        @ObservationIgnored private var automaticBootstrap: Data?
        private(set) var latestSnapshot: DeviceLinkingSnapshotFfi?
        private(set) var cleanupError: Error?
        private(set) var observationError: Error?
        @ObservationIgnored private let session: any DeviceLinkingSessionProtocol
        @ObservationIgnored private let subscription: DeviceLinkingSubscription
        @ObservationIgnored private var observation: Task<Void, Never>?
        @ObservationIgnored private var cleanup: Task<Void, Error>?
        @ObservationIgnored private var active = true

        init(accountRef: String, session: any DeviceLinkingSessionProtocol) {
            self.accountRef = accountRef
            self.session = session
            self.subscription = session.subscribe()
            let subscription = self.subscription
            observation = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let snapshot = try await subscription.next()
                        guard !Task.isCancelled, let self, self.active else { return }
                        self.latestSnapshot = snapshot
                    }
                } catch {
                    guard !Task.isCancelled, let self, self.active else { return }
                    self.observationError = error
                }
            }
        }

        func invalidate() {
            guard active else { return }
            active = false
            automaticBootstrap = nil
            latestSnapshot = nil
            subscription.closeStream()
            observation?.cancel()
            observation = nil
        }

        func confirmComparison(displayedRevision: UInt64) async throws {
            try requireActive()
            try await session.confirmComparison(displayedRevision: displayedRevision)
            try requireActive()
        }

        // Enrollment is a separate explicit action on this original owner.
        func continueLinking(displayedRevision: UInt64) async throws {
            try requireActive()
            if automaticBootstrap != nil {
                try await session.continueAutomaticLinking(displayedRevision: displayedRevision, shareChats: false)
            } else {
                try await session.continueLinking(displayedRevision: displayedRevision)
            }
            try requireActive()
        }

        func continueLinkingAndShareChats(displayedRevision: UInt64) async throws {
            try requireActive()
            if automaticBootstrap != nil {
                try await session.continueAutomaticLinking(displayedRevision: displayedRevision, shareChats: true)
            } else {
                try await session.continueLinkingAndShareChats(displayedRevision: displayedRevision)
            }
            try requireActive()
        }

        // Broad chat sharing is a distinct explicit action; ordinary linking remains separate.
        func continueLinkingAndShareChats(displayedRevision: UInt64) async throws {
            try requireActive()
            try await session.continueLinkingAndShareChats(displayedRevision: displayedRevision)
            try requireActive()
        }

        func enrollmentPacket(displayedRevision: UInt64) async throws -> Data {
            try requireActive()
            let packet = try await session.enrollmentPacket(displayedRevision: displayedRevision)
            try requireActive()
            return packet
        }

        func receiveEnrollmentPacket(displayedRevision: UInt64, packet: Data) async throws {
            try requireActive()
            try await session.receiveEnrollmentPacket(displayedRevision: displayedRevision, packet: packet)
            try requireActive()
        }

        func finalizeLinking(displayedRevision: UInt64) async throws {
            try requireActive()
            try await session.finalizeLinking(displayedRevision: displayedRevision)
            try requireActive()
        }

        func outgoingPackets() async throws -> [DeviceLinkingOutgoingPacketFfi] {
            try requireActive()
            let packets = try await session.outgoingPackets()
            try requireActive()
            return packets
        }

        private func requireActive() throws {
            try Task.checkCancellation()
            guard active else { throw CancellationError() }
        }

        /// Activate only after the exact original has been adopted by this live account scope.
        func activateAutomaticPairing(displayBootstrap: Bool) async throws {
            try requireActive()
            let code = try await session.automaticPairingCode()
            try requireActive()
            automaticBootstrap = displayBootstrap ? Data(code.utf8) : Data()
        }

        func setupPacket() throws -> Data {
            try requireActive()
            return automaticBootstrap ?? session.setupPacket()
        }

        func receiveSetupPacket(_ packet: Data) async throws {
            try requireActive()
            try await session.receiveSetupPacket(packet: packet)
            try requireActive()
        }

        func receivePacket(_ packet: Data) async throws {
            try requireActive()
            try await session.receivePacket(packet: packet)
            try requireActive()
        }

        func acknowledgePacket(_ id: String) async throws {
            try requireActive()
            try await session.acknowledgePacket(acknowledgementId: id)
            try requireActive()
        }

        func cancel() async throws {
            invalidate()
            let task: Task<Void, Error>
            if let cleanup {
                task = cleanup
            } else {
                let session = self.session
                task = Task {
                    do { try await session.cancel() } catch MarmotKitError.DeviceLinkingClosed {
                        // The SDK has already retired this exact original and its transport.
                    }
                }
                cleanup = task
            }
            do {
                try await task.value
                cleanupError = nil
            } catch {
                cleanupError = error
                cleanup = nil
                throw error
            }
        }
    }
#endif
