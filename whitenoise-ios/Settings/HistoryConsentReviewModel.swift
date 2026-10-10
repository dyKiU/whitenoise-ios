#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    /// Read-only review and explicit actions on the account's held originals.
    @MainActor @Observable final class HistoryConsentReviewModel {
        private(set) var scopes: [NativeHistoryConsentScope] = []
        private(set) var selected: NativeHistoryConsentScope?
        private(set) var review: HistoryTransferSnapshotFfi?
        private(set) var isWorking = false
        private(set) var failed = false
        private var retired = false
        @ObservationIgnored private let loadOriginals: @MainActor () async throws -> [NativeHistoryConsentScope]
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        var isActive: Bool { !retired && isCurrent() }

        init(
            loadOriginals: @escaping @MainActor () async throws -> [NativeHistoryConsentScope],
            isCurrent: @escaping @MainActor () -> Bool
        ) {
            self.loadOriginals = loadOriginals
            self.isCurrent = isCurrent
        }
        private func checkActive() throws {
            try Task.checkCancellation()
            guard isActive else {
                invalidate()
                throw MarmotKitError.HistoryTransferClosed
            }
        }
        private func startAction() throws {
            try checkActive()
            guard !isWorking else { throw MarmotKitError.HistoryTransferNotReady }
            isWorking = true
            failed = false
        }
        func loadPending() async throws {
            try startAction()
            defer { isWorking = false }
            selected = nil
            review = nil
            do {
                let originals = try await loadOriginals()
                try checkActive()
                guard originals.count <= 128 else { throw MarmotKitError.HistoryTransferNotReady }
                scopes = originals
                for scope in originals where scope.isActive {
                    do { _ = try await scope.refresh() } catch { failed = true }
                    try checkActive()
                }
            } catch {
                scopes = []
                failed = isActive && !Task.isCancelled
                throw error
            }
        }
        func select(id: UUID) async throws {
            try startAction()
            defer { isWorking = false }
            review = nil
            selected = nil
            guard let scope = scopes.first(where: { $0.id == id }), scope.isActive else {
                throw MarmotKitError.HistoryTransferNotReady
            }
            selected = scope
            do {
                let value = try await scope.refresh()
                try checkActive()
                guard selected === scope else { throw MarmotKitError.HistoryTransferClosed }
                review = value
            } catch {
                review = nil
                failed = isActive && !Task.isCancelled
                throw error
            }
        }
        func approve(displayedRevision: UInt64) async throws {
            try checkActive()
            guard let selected, let review else { throw MarmotKitError.HistoryTransferNotReady }
            guard review.revision == displayedRevision else { throw MarmotKitError.HistoryTransferStaleRevision }
            try startAction()
            defer { isWorking = false }
            do {
                try await selected.approve(displayedRevision: displayedRevision)
                try checkActive()
                self.review = selected.review
            } catch {
                self.review = nil
                failed = isActive && !Task.isCancelled
                throw error
            }
        }
        func cancelSelected() {
            selected?.cancel()
            selected = nil
            review = nil
        }
        func invalidate() {
            retired = true
            scopes = []
            selected = nil
            review = nil
        }
    }
#endif
