#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    /// Native lifetime for one original SDK session; observations never restore permission.
    @MainActor
    @Observable
    final class DeviceLinkingAccountScope {
        let accountRef: String
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
            latestSnapshot = nil
            subscription.close()
            observation?.cancel()
            observation = nil
        }

        func confirmComparison(displayedRevision: UInt64) async throws {
            try requireActive()
            try await session.confirmComparison(displayedRevision: displayedRevision)
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

        func setupPacket() throws -> Data {
            try requireActive()
            return session.setupPacket()
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
                task = Task { try await session.cancel() }
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
