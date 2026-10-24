#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    /// One chat's observed choices and exact original source action; observation never grants consent.
    @MainActor @Observable final class HistorySourcePickerModel {
        let groupIdHex: String
        private(set) var recipients: [HistoryTransferRecipientFfi] = []
        private(set) var selectedDevice: Data?
        private(set) var review: HistoryTransferSnapshotFfi?
        private(set) var isWorking = false
        private(set) var failed = false
        private var retired = false
        private var loaded = false
        @ObservationIgnored private var original: (any HistoryTransferProtocol)?
        @ObservationIgnored private var selection: HistoryTransferSnapshotFfi?
        @ObservationIgnored private var pending: Task<any HistoryTransferProtocol, Error>?
        @ObservationIgnored private let readRecipients: @MainActor () async throws -> [HistoryTransferRecipientFfi]
        @ObservationIgnored private let beginOriginal: @MainActor (Data) async throws -> any HistoryTransferProtocol
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        var isActive: Bool { !retired && isCurrent() }
        var hasOriginal: Bool { original != nil }

        init(
            groupIdHex: String,
            readRecipients: @escaping @MainActor () async throws -> [HistoryTransferRecipientFfi],
            beginOriginal: @escaping @MainActor (Data) async throws -> any HistoryTransferProtocol,
            isCurrent: @escaping @MainActor () -> Bool
        ) {
            self.groupIdHex = groupIdHex
            self.readRecipients = readRecipients
            self.beginOriginal = beginOriginal
            self.isCurrent = isCurrent
        }
        private func checkActive() throws {
            try Task.checkCancellation()
            guard isActive else {
                cancel()
                throw MarmotKitError.HistoryTransferClosed
            }
        }
        private func startAction() throws {
            try checkActive()
            guard !isWorking else { throw MarmotKitError.HistoryTransferNotReady }
            isWorking = true
            failed = false
        }
        func loadRecipients() async throws {
            try startAction()
            defer { isWorking = false }
            guard original == nil else { throw MarmotKitError.HistoryTransferNotReady }
            recipients = []
            selectedDevice = nil
            loaded = false
            do {
                let values = try await readRecipients()
                try checkActive()
                guard values.count <= 128, values.allSatisfy({ $0.device.count == 32 }),
                    Set(values.map(\.device)).count == values.count,
                    Set(values.map(\.leafIndex)).count == values.count
                else { throw MarmotKitError.HistoryTransferNotReady }
                recipients = values
                loaded = true
            } catch {
                failed = isActive && !Task.isCancelled
                throw error
            }
        }
        func select(device: Data) throws {
            try checkActive()
            guard !isWorking, original == nil, loaded, recipients.contains(where: { $0.device == device }) else {
                throw MarmotKitError.HistoryTransferNotReady
            }
            selectedDevice = device
        }
        func begin() async throws {
            try startAction()
            defer { isWorking = false }
            guard original == nil, loaded, let selectedDevice,
                recipients.contains(where: { $0.device == selectedDevice })
            else { throw MarmotKitError.HistoryTransferNotReady }
            let task = Task { try await beginOriginal(selectedDevice) }
            pending = task
            defer { pending = nil }
            do {
                let value = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                guard isActive, !Task.isCancelled else {
                    value.cancel()
                    throw MarmotKitError.HistoryTransferClosed
                }
                original = value
                _ = try await readSnapshot()
            } catch {
                review = nil
                if Task.isCancelled || !isCurrent() { cancel() }
                failed = isActive && !Task.isCancelled
                throw error
            }
        }
        func refresh() async throws {
            try startAction()
            defer { isWorking = false }
            do { _ = try await readSnapshot() } catch {
                review = nil
                if Task.isCancelled || !isCurrent() { cancel() }
                failed = isActive && !Task.isCancelled
                throw error
            }
        }
        func continueTransfer(displayedRevision: UInt64) async throws {
            try checkActive()
            guard let original, review?.revision == displayedRevision else {
                throw MarmotKitError.HistoryTransferStaleRevision
            }
            try startAction()
            defer { isWorking = false }
            do {
                try await withTaskCancellationHandler {
                    try await original.continueTransfer(revision: displayedRevision)
                } onCancel: {
                    original.cancel()
                }
                try checkActive()
                _ = try await readSnapshot()
            } catch {
                review = nil
                if Task.isCancelled || !isCurrent() { cancel() }
                failed = isActive && !Task.isCancelled
                throw error
            }
        }
        func cancel() {
            retired = true
            pending?.cancel()
            original?.cancel()
            original = nil
            review = nil
            recipients = []
            selectedDevice = nil
            loaded = false
        }
        func retryCleanup() throws {
            guard pending == nil else { throw MarmotKitError.HistoryTransferNotReady }
        }
        private func readSnapshot() async throws -> HistoryTransferSnapshotFfi {
            guard let original else { throw MarmotKitError.HistoryTransferNotReady }
            let value = try await withTaskCancellationHandler {
                try await original.snapshot()
            } onCancel: {
                original.cancel()
            }
            try checkActive()
            guard value.groupIdHex == groupIdHex, value.sourceDevice.count == 32,
                value.recipientDevice == selectedDevice,
                selection.map({ sameSelection($0, value) }) ?? true
            else {
                cancel()
                throw MarmotKitError.HistoryTransferNotReady
            }
            if selection == nil { selection = value }
            review = value
            return value
        }
        private func sameSelection(_ first: HistoryTransferSnapshotFfi, _ next: HistoryTransferSnapshotFfi) -> Bool {
            first.groupIdHex == next.groupIdHex && first.sourceDevice == next.sourceDevice
                && first.recipientDevice == next.recipientDevice
                && first.snapshotTimestampCeiling == next.snapshotTimestampCeiling
                && first.recordCount == next.recordCount && first.encodedBytes == next.encodedBytes
                && first.fragmentCount == next.fragmentCount
        }
    }
#endif
