#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    /// Custody of one original SDK approval; display data never recreates consent.
    @MainActor @Observable
    final class DeviceLinkingApprovalScope {
        let accountRef: String
        private(set) var cleanupError: Error?
        @ObservationIgnored private let approval: any DeviceLinkingApprovalProtocol
        @ObservationIgnored private var active = true
        @ObservationIgnored private var cleanup: Task<Void, Error>?

        init(accountRef: String, approval: any DeviceLinkingApprovalProtocol) {
            self.accountRef = accountRef
            self.approval = approval
        }

        func snapshot() async throws -> DeviceLinkingApprovalSnapshotFfi {
            try requireActive()
            let value = try await approval.snapshot()
            try requireActive()
            return value
        }

        func approve(displayedRevision: UInt64) async throws {
            try requireActive()
            try await approval.approve(displayedRevision: displayedRevision)
            try requireActive()
        }

        func receiveEnrollmentPacket(displayedRevision: UInt64, packet: Data) async throws {
            try requireActive()
            try await approval.receiveEnrollmentPacket(displayedRevision: displayedRevision, packet: packet)
            try requireActive()
        }

        private func requireActive() throws {
            try Task.checkCancellation()
            guard active else { throw CancellationError() }
        }

        func invalidate() { active = false }

        func cancel() async throws {
            invalidate()
            let task: Task<Void, Error>
            if let cleanup {
                task = cleanup
            } else {
                let approval = self.approval
                task = Task { try await approval.cancel() }
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
