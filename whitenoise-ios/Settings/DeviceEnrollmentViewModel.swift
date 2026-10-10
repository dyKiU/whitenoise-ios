#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    /// Presentation actions on the already-held original; it never starts or recreates a session.
    @MainActor @Observable
    final class DeviceEnrollmentViewModel {
        @ObservationIgnored private let original: DeviceLinkingAccountScope
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        @ObservationIgnored private let cancelOriginal: @MainActor () async throws -> Void
        private var retired = false
        var isActive: Bool { !retired && isCurrent() }
        var snapshot: DeviceLinkingSnapshotFfi? { isActive ? original.latestSnapshot : nil }

        init(
            original: DeviceLinkingAccountScope, isCurrent: @escaping @MainActor () -> Bool,
            cancel: @escaping @MainActor () async throws -> Void
        ) {
            self.original = original
            self.isCurrent = isCurrent
            cancelOriginal = cancel
        }
        @ObservationIgnored private var cleanup: Task<Void, Error>?
        private(set) var cleanupError: Error?

        private func checkActive() throws {
            guard isActive, !Task.isCancelled else { throw MarmotKitError.DeviceLinkingClosed }
        }
        func continueLinking(displayedRevision: UInt64) async throws {
            try checkActive()
            try await original.continueLinking(displayedRevision: displayedRevision)
            try checkActive()
        }
        func enrollmentPacket(displayedRevision: UInt64) async throws -> Data {
            try checkActive()
            let packet = try await original.enrollmentPacket(displayedRevision: displayedRevision)
            try checkActive()
            try DeviceEnrollmentPacketInput.check(packet)
            return packet
        }
        func receiveEnrollmentPacket(displayedRevision: UInt64, packet: Data) async throws {
            try checkActive()
            try DeviceEnrollmentPacketInput.check(packet)
            try await original.receiveEnrollmentPacket(displayedRevision: displayedRevision, packet: packet)
            try checkActive()
        }
        func finalizeLinking(displayedRevision: UInt64) async throws {
            try checkActive()
            try await original.finalizeLinking(displayedRevision: displayedRevision)
            try checkActive()
        }
        func cancel() async throws {
            invalidate()
            let task: Task<Void, Error>
            if let cleanup {
                task = cleanup
            } else {
                task = Task { try await cancelOriginal() }
                cleanup = task
            }
            do {
                try await task.value
                cleanupError = nil
            } catch {
                cleanup = nil
                cleanupError = error
                throw error
            }
        }
        func invalidate() { retired = true }
    }

    nonisolated enum DeviceEnrollmentPacketInput {
        enum Error: Swift.Error { case invalidPacket }
        static func check(_ packet: Data) throws {
            guard !packet.isEmpty, packet.count <= 16_384 else { throw Error.invalidPacket }
        }
        static func decode(_ input: String) throws -> Data {
            let encoded = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !encoded.isEmpty, encoded.utf8.count <= 21_848,
                let packet = Data(base64Encoded: encoded), packet.base64EncodedString() == encoded
            else { throw Error.invalidPacket }
            try check(packet)
            return packet
        }
    }
#endif
