#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    /// Independent explicit current-member action; a refresh never approves enrollment.
    @MainActor @Observable
    final class DeviceEnrollmentApprovalViewModel {
        @ObservationIgnored private let original: DeviceLinkingApprovalScope
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        @ObservationIgnored private let cancelOriginal: @MainActor () async throws -> Void
        private var retired = false
        private var currentSnapshot: DeviceLinkingApprovalSnapshotFfi?
        var isActive: Bool { !retired && isCurrent() }
        var snapshot: DeviceLinkingApprovalSnapshotFfi? { isActive ? currentSnapshot : nil }
        init(
            original: DeviceLinkingApprovalScope, isCurrent: @escaping @MainActor () -> Bool,
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
        func refresh() async throws {
            try checkActive()
            let value = try await original.snapshot()
            try checkActive()
            currentSnapshot = value
        }
        func approve(displayedRevision: UInt64) async throws {
            try checkActive()
            try await original.approve(displayedRevision: displayedRevision)
            try checkActive()
        }
        func receiveEnrollmentPacket(displayedRevision: UInt64, packet: Data) async throws {
            try checkActive()
            try DeviceEnrollmentPacketInput.check(packet)
            try await original.receiveEnrollmentPacket(displayedRevision: displayedRevision, packet: packet)
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
        func invalidate() {
            retired = true
            currentSnapshot = nil
        }
    }
#endif
