#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit

    /// Negative custody of a bounded SDK-returned batch, never a native consent ledger.
    @MainActor final class HistoryConsentAccountOwner {
        private let accountRef: String
        private let runtime: MarmotClient
        private let isCurrent: @MainActor () -> Bool
        private var isActive = true
        private var batch: [NativeHistoryConsentScope]?
        private var sourceModel: HistorySourcePickerModel?
        private var retiringSourceModels: [HistorySourcePickerModel] = []
        private var pending: Task<[any HistoryConsentProtocol], Error>?

        init(accountRef: String, runtime: MarmotClient, isCurrent: @escaping @MainActor () -> Bool) {
            self.accountRef = accountRef
            self.runtime = runtime
            self.isCurrent = isCurrent
        }
        private var isCurrentOwner: Bool { isActive && isCurrent() }
        func matches(accountRef: String, runtime: MarmotClient) -> Bool {
            self.accountRef == accountRef && self.runtime === runtime && isCurrentOwner
        }
        func pendingConsents(
            _ factory: @escaping @MainActor (MarmotClient, String) async throws -> [any HistoryConsentProtocol]
        ) async throws -> [NativeHistoryConsentScope] {
            try Task.checkCancellation()
            guard isCurrentOwner else { throw MarmotKitError.HistoryTransferClosed }
            guard pending == nil else { throw MarmotKitError.HistoryTransferNotReady }
            if let batch, batch.contains(where: { $0.isActive }) { return batch }
            self.batch = nil
            let task = Task { try await factory(runtime, accountRef) }
            pending = task
            defer { pending = nil }
            let originals = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard isCurrentOwner, !Task.isCancelled else {
                // Preserve every late original until its exact synchronous negative cleanup finishes.
                for original in originals { original.cancel() }
                throw MarmotKitError.HistoryTransferClosed
            }
            // Current SDK MAX_HISTORY_OWNERS is 128. A broken return contract cannot be adopted.
            guard originals.count <= 128 else {
                for original in originals { original.cancel() }
                throw MarmotKitError.HistoryTransferNotReady
            }
            let held = originals.map {
                NativeHistoryConsentScope(original: $0, isCurrent: { [weak self] in self?.isCurrentOwner == true })
            }
            if !held.isEmpty { batch = held }
            return held
        }
        func sourcePicker(
            groupIdHex: String,
            readRecipients: @escaping @MainActor () async throws -> [HistoryTransferRecipientFfi],
            beginOriginal: @escaping @MainActor (Data) async throws -> any HistoryTransferProtocol
        ) throws -> HistorySourcePickerModel {
            guard isCurrentOwner else { throw MarmotKitError.HistoryTransferClosed }
            if let sourceModel, sourceModel.isActive, sourceModel.groupIdHex == groupIdHex { return sourceModel }
            if let sourceModel {
                sourceModel.cancel()
                retiringSourceModels.append(sourceModel)
                self.sourceModel = nil
            }
            try retryCleanup()
            let model = HistorySourcePickerModel(
                groupIdHex: groupIdHex, readRecipients: readRecipients, beginOriginal: beginOriginal,
                isCurrent: { [weak self] in self?.isCurrentOwner == true })
            sourceModel = model
            return model
        }
        func releaseSourcePicker(_ model: HistorySourcePickerModel) {
            guard sourceModel === model else { return }
            model.cancel()
            retiringSourceModels.append(model)
            sourceModel = nil
        }
        func invalidate() {
            isActive = false
            if let sourceModel {
                sourceModel.cancel()
                retiringSourceModels.append(sourceModel)
                self.sourceModel = nil
            }
            pending?.cancel()
            for scope in batch ?? [] { scope.cancel() }
            batch = nil
        }
        func retryCleanup() throws {
            // A factory ignoring cancellation still owns a future original. Destructive exit must retry.
            guard pending == nil else { throw MarmotKitError.HistoryTransferNotReady }
            try sourceModel?.retryCleanup()
            for model in retiringSourceModels { try model.retryCleanup() }
            retiringSourceModels.removeAll()
        }
    }

    @MainActor final class HistoryConsentAccountLifetime {
        private var owner: HistoryConsentAccountOwner?
        private var retiring: [HistoryConsentAccountOwner] = []
        func currentOwner(accountRef: String, client: MarmotClient, isCurrent: @escaping @MainActor () -> Bool) throws
            -> HistoryConsentAccountOwner
        {
            try Task.checkCancellation()
            guard isCurrent() else { throw MarmotKitError.HistoryTransferClosed }
            if let owner {
                guard owner.matches(accountRef: accountRef, runtime: client) else {
                    throw MarmotKitError.HistoryTransferClosed
                }
                return owner
            }
            let value = HistoryConsentAccountOwner(accountRef: accountRef, runtime: client, isCurrent: isCurrent)
            owner = value
            return value
        }
        func releaseSourcePicker(_ model: HistorySourcePickerModel) { owner?.releaseSourcePicker(model) }
        func invalidate() {
            guard let owner else { return }
            owner.invalidate()
            retiring.append(owner)
            self.owner = nil
        }
        func retryCleanup() throws {
            var firstError: Error?
            if let owner {
                do { try owner.retryCleanup() } catch { firstError = error }
            }
            for value in retiring {
                do {
                    try value.retryCleanup()
                    retiring.removeAll { $0 === value }
                } catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }
    }
#endif
