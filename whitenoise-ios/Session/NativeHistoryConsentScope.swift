#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    /// Custody of one original recipient handle; review metadata never recreates it.
    @MainActor @Observable final class NativeHistoryConsentScope: Identifiable {
        let id = UUID()
        private(set) var isActive = true
        private(set) var review: HistoryTransferSnapshotFfi?
        private(set) var isWorking = false
        @ObservationIgnored private var selection: HistoryTransferSnapshotFfi?
        @ObservationIgnored private var originalCancelled = false
        @ObservationIgnored private let original: any HistoryConsentProtocol
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool

        init(original: any HistoryConsentProtocol, isCurrent: @escaping @MainActor () -> Bool = { true }) {
            self.original = original
            self.isCurrent = isCurrent
        }
        private func checkActive() throws {
            try Task.checkCancellation()
            guard isActive, isCurrent() else { throw MarmotKitError.HistoryTransferClosed }
        }
        private func startAction() throws {
            try checkActive()
            guard !isWorking else { throw MarmotKitError.HistoryTransferNotReady }
            isWorking = true
        }
        func refresh() async throws -> HistoryTransferSnapshotFfi {
            try startAction()
            defer { isWorking = false }
            do { return try await readSnapshot() } catch {
                review = nil
                if Task.isCancelled || !isCurrent() { cancel() }
                throw error
            }
        }
        func approve(displayedRevision: UInt64) async throws {
            try checkActive()
            guard review?.revision == displayedRevision else { throw MarmotKitError.HistoryTransferStaleRevision }
            try startAction()
            defer { isWorking = false }
            let original = original
            do {
                try await withTaskCancellationHandler {
                    try await original.approve(revision: displayedRevision)
                } onCancel: {
                    original.cancel()
                }
                try checkActive()
                _ = try await readSnapshot()
            } catch {
                review = nil
                if Task.isCancelled || !isCurrent() { cancel() }
                throw error
            }
        }
        func invalidate() {
            isActive = false
            review = nil
        }
        func cancel() {
            invalidate()
            guard !originalCancelled else { return }
            originalCancelled = true
            original.cancel()
        }
        private func readSnapshot() async throws -> HistoryTransferSnapshotFfi {
            let original = original
            let value = try await withTaskCancellationHandler {
                try await original.snapshot()
            } onCancel: {
                original.cancel()
            }
            try checkActive()
            guard !value.groupIdHex.isEmpty, value.groupIdHex.utf8.count <= 512,
                value.sourceDevice.count == 32, value.recipientDevice.count == 32,
                selection.map({ sameSelection($0, value) }) ?? true
            else {
                cancel()
                throw MarmotKitError.HistoryTransferNotReady
            }
            if selection == nil { selection = value }
            review = value
            return value
        }
        private func sameSelection(_ previous: HistoryTransferSnapshotFfi, _ value: HistoryTransferSnapshotFfi) -> Bool
        {
            previous.groupIdHex == value.groupIdHex && previous.sourceDevice == value.sourceDevice
                && previous.recipientDevice == value.recipientDevice
                && previous.snapshotTimestampCeiling == value.snapshotTimestampCeiling
                && previous.recordCount == value.recordCount && previous.encodedBytes == value.encodedBytes
                && previous.fragmentCount == value.fragmentCount
        }
    }
#endif
