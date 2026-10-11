#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    /// One broad device-sharing review. Returned targets and snapshots are observations only.
    @MainActor @Observable final class AccountChatSharingViewModel {
        @ObservationIgnored private let readTargets: @MainActor () async throws -> AccountSharingTargetsFfi
        @ObservationIgnored private let begin: @MainActor (Data) async throws -> any AccountSharingReviewing
        @ObservationIgnored private let readPending: @MainActor () async throws -> [any AccountSharingReviewing]
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        private var retired = false
        private var operation = UUID()
        private(set) var targets: AccountSharingTargetsFfi?
        private(set) var selectedDevice: Data?
        private(set) var pending: [any AccountSharingReviewing] = []
        private(set) var review: (any AccountSharingReviewing)?
        private(set) var isWorking = false
        private(set) var actionError: Error?
        var isActive: Bool { !retired && isCurrent() }
        init(
            readTargets: @escaping @MainActor () async throws -> AccountSharingTargetsFfi,
            begin: @escaping @MainActor (Data) async throws -> any AccountSharingReviewing,
            readPending: @escaping @MainActor () async throws -> [any AccountSharingReviewing],
            isCurrent: @escaping @MainActor () -> Bool
        ) {
            self.readTargets = readTargets
            self.begin = begin
            self.readPending = readPending
            self.isCurrent = isCurrent
        }
        private func checkActive() throws {
            try Task.checkCancellation()
            guard isActive else { throw MarmotKitError.AccountSharingClosed }
        }
        func loadTargets() async throws {
            try checkActive()
            guard !isWorking else { throw MarmotKitError.AccountSharingNotReady }
            targets = nil
            selectedDevice = nil
            actionError = nil
            let ticket = UUID()
            operation = ticket
            isWorking = true
            defer { if operation == ticket { isWorking = false } }
            do {
                let value = try await readTargets()
                try checkActive()
                guard operation == ticket else { throw MarmotKitError.AccountSharingClosed }
                guard value.targets.count <= 128, !value.protectedGroupIdHex.isEmpty,
                    value.protectedGroupIdHex.utf8.count <= 512,
                    value.protectedGroupIdHex.utf8.count.isMultiple(of: 2),
                    value.protectedGroupIdHex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                    value.targets.allSatisfy({ $0.device.count == 32 }),
                    Set(value.targets.map(\.leafIndex)).count == value.targets.count,
                    Set(value.targets.map(\.device)).count == value.targets.count
                else { throw MarmotKitError.AccountSharingNotReady }
                targets = value
            } catch {
                if operation == ticket, isActive { actionError = error }
                throw error
            }
        }
        func select(device: Data) throws {
            try checkActive()
            guard !isWorking, targets?.targets.contains(where: { $0.device == device }) == true else {
                throw MarmotKitError.AccountSharingNotReady
            }
            selectedDevice = device
        }
        func requestSharing() async throws {
            try checkActive()
            guard !isWorking, review?.isActive != true, let selectedDevice, let targets,
                targets.targets.contains(where: { $0.device == selectedDevice })
            else { throw MarmotKitError.AccountSharingNotReady }
            let ticket = UUID()
            operation = ticket
            isWorking = true
            actionError = nil
            defer { if operation == ticket { isWorking = false } }
            do {
                let original = try await begin(selectedDevice)
                guard isActive, !Task.isCancelled, operation == ticket else {
                    original.cancel()
                    throw MarmotKitError.AccountSharingClosed
                }
                do {
                    try original.refresh()
                    guard let value = original.snapshot, value.recipientDevice == selectedDevice,
                        value.protectedGroupIdHex == targets.protectedGroupIdHex,
                        value.protectedEpoch == targets.protectedEpoch
                    else { throw MarmotKitError.AccountSharingNotReady }
                } catch {
                    original.cancel()
                    throw error
                }
                review = original
            } catch {
                if operation == ticket, isActive { actionError = error }
                throw error
            }
        }
        func loadPending() async throws {
            try checkActive()
            guard !isWorking else { throw MarmotKitError.AccountSharingNotReady }
            let ticket = UUID()
            operation = ticket
            isWorking = true
            actionError = nil
            defer { if operation == ticket { isWorking = false } }
            do {
                let originals = try await readPending()
                guard isActive, !Task.isCancelled, operation == ticket else {
                    for original in originals { original.cancel() }
                    throw MarmotKitError.AccountSharingClosed
                }
                pending = originals
            } catch {
                if operation == ticket, isActive { actionError = error }
                throw error
            }
        }
        func selectReview(id: UUID) throws {
            try checkActive()
            guard !isWorking, let original = pending.first(where: { $0.id == id }), original.isActive else {
                throw MarmotKitError.AccountSharingClosed
            }
            try original.refresh()
            review = original
        }
        func refreshReview() throws {
            try checkActive()
            guard !isWorking, let review else { throw MarmotKitError.AccountSharingNotReady }
            try review.refresh()
        }
        func approveSharing(displayedRevision: UInt64) async throws {
            try checkActive()
            guard !isWorking, let review, review.snapshot?.revision == displayedRevision else {
                throw MarmotKitError.AccountSharingStaleRevision
            }
            isWorking = true
            actionError = nil
            defer { isWorking = false }
            do {
                try await review.approve(displayedRevision: displayedRevision)
                try checkActive()
            } catch {
                if isActive { actionError = error }
                throw error
            }
        }
        func cancelReview() {
            operation = UUID()
            isWorking = false
            review?.cancel()
            review = nil
            targets = nil
            selectedDevice = nil
        }
        func invalidate() {
            retired = true
            cancelReview()
            for original in pending { original.cancel() }
            pending = []
        }
    }
#endif
