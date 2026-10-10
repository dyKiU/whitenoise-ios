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
        private var currentReview: DeviceLinkingApprovalReviewMetadataFfi?
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
            if value.phase != .awaitingApproval || currentReview?.revision != value.revision { currentReview = nil }
        }
        var review: DeviceLinkingApprovalReviewMetadataFfi? {
            guard isActive, snapshot?.phase == .awaitingApproval, currentReview?.revision == snapshot?.revision else {
                return nil
            }
            return currentReview
        }
        struct ReviewDisplay {
            let revision: UInt64
            let sourceKey: String
            let joiningKey: String
            let existingDeviceCount: UInt32
        }
        var reviewDisplay: ReviewDisplay? {
            guard let review else { return nil }
            return .init(
                revision: review.revision,
                sourceKey: review.sourceDevicePublicKey.map { String(format: "%02x", $0) }.joined(),
                joiningKey: review.joiningDevicePublicKey.map { String(format: "%02x", $0) }.joined(),
                existingDeviceCount: review.existingDeviceCount)
        }
        private(set) var isWorking = false
        private(set) var actionError: Error?
        enum ReviewAction { case approve, receivePacket }
        func performReviewAction(_ action: ReviewAction, displayedRevision: UInt64, input: String = "") async throws {
            try checkActive()
            guard !isWorking else { throw MarmotKitError.DeviceLinkingNotReady }
            isWorking = true
            actionError = nil
            defer { isWorking = false }
            do {
                switch action {
                case .approve:
                    try await approveReviewed(displayedRevision: displayedRevision)
                case .receivePacket:
                    guard snapshot?.phase == .approvedAwaitingPacket, snapshot?.revision == displayedRevision else {
                        throw MarmotKitError.DeviceLinkingStaleRevision
                    }
                    try await receiveEnrollmentPacket(
                        displayedRevision: displayedRevision, packet: DeviceEnrollmentPacketInput.decode(input))
                    try await refresh()
                }
                try checkActive()
            } catch {
                actionError = error
                throw error
            }
        }
        func refreshForDisplay() async throws {
            try await refresh()
            if snapshot?.phase == .awaitingApproval { try await refreshReview() }
        }
        func refreshReview() async throws {
            try checkActive()
            currentReview = nil
            try await refresh()
            guard let displayed = snapshot, displayed.phase == .awaitingApproval else {
                throw MarmotKitError.DeviceLinkingNotReady
            }
            let value = try await original.reviewMetadata(displayedRevision: displayed.revision)
            try checkActive()
            guard value.revision == displayed.revision else { throw MarmotKitError.DeviceLinkingStaleRevision }
            guard value.sourceDevicePublicKey.count == 32, value.joiningDevicePublicKey.count == 32,
                (1...128).contains(value.existingDeviceCount)
            else { throw MarmotKitError.DeviceLinkingNotReady }
            try await refresh()
            guard snapshot?.phase == .awaitingApproval, snapshot?.revision == displayed.revision else {
                throw MarmotKitError.DeviceLinkingStaleRevision
            }
            currentReview = value
        }
        func approveReviewed(displayedRevision: UInt64) async throws {
            try checkActive()
            guard review?.revision == displayedRevision else { throw MarmotKitError.DeviceLinkingStaleRevision }
            currentReview = nil
            try await approve(displayedRevision: displayedRevision)
            try await refresh()
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
            currentReview = nil
        }
    }
#endif
