import Foundation
import MarmotKit
import Observation

#if WN_EXPERIMENTAL_DEVICE_SYNC
    enum AutomaticChatPresentationError: Error, Equatable {
        case unavailable
        case invalidSnapshot
        case retired
    }

    /// Adds only missing paired observations. The ordinary model keeps paging/search/filter authority.
    @MainActor
    @Observable
    final class AccountChatListViewModel {
        let accountRef: String
        private(set) var snapshot: AccountChatListWindowSnapshotFfi?
        private(set) var isLoading = false
        private(set) var error: AutomaticChatPresentationError?
        @ObservationIgnored private let runtime: any AccountChatObserving
        @ObservationIgnored private var task: Task<Void, Never>?
        @ObservationIgnored private var owner: (any AccountChatListObserving)?
        @ObservationIgnored private var pageTicket: UUID?
        @ObservationIgnored private var pairedBoundaryVisible = false
        @ObservationIgnored private var scrollPageArmed = false
        private var pageStarts: [String?] = [nil]
        @ObservationIgnored private var retired = false
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool

        init(accountRef: String, runtime: any AccountChatObserving, isCurrent: @escaping @MainActor () -> Bool) {
            self.isCurrent = isCurrent
            self.accountRef = accountRef
            self.runtime = runtime
        }

        /// Reads the one bounded visible lane, never concatenates the ordinary metadata rows.
        var pairedRows: [PairedChatSummaryFfi] {
            snapshot?.rows.compactMap { row in
                if case .pairedSource(let value) = row { return value }
                return nil
            } ?? []
        }

        func start() {
            guard !retired, isCurrent(), task == nil else { return }
            isLoading = true
            task = Task { [weak self] in await self?.observe() }
        }

        func invalidate() {
            retired = true
            pageTicket = nil
            pairedBoundaryVisible = false
            scrollPageArmed = false
            pageStarts = [nil]
            task?.cancel()
            task = nil
            owner?.cancel()
            owner = nil
            snapshot = nil
            error = nil
            isLoading = false
        }

        var hasPreviousPairedPage: Bool { pageStarts.count > 1 }

        /// Layout changes cannot arm paging; only the containing scroll view's user gesture can.
        func pairedUserScrollChanged(_ active: Bool) async {
            scrollPageArmed = active
            if active && pairedBoundaryVisible {
                scrollPageArmed = false
                await loadMorePaired()
            }
        }

        func pairedBoundaryVisibilityChanged(_ visible: Bool) async {
            let entered = visible && !pairedBoundaryVisible
            pairedBoundaryVisible = visible
            guard entered, scrollPageArmed else { return }
            scrollPageArmed = false
            await loadMorePaired()
        }

        func loadMorePaired() async {
            guard let cursor = snapshot?.nextPairedGroupIdHex else { return }
            await requestPairedPage(after: cursor, backwards: false)
        }

        func loadPreviousPaired() async {
            guard pageStarts.count > 1 else { return }
            await requestPairedPage(after: pageStarts[pageStarts.count - 2], backwards: true)
        }

        private func requestPairedPage(after cursor: String?, backwards: Bool) async {
            guard !retired, isCurrent(), pageTicket == nil, let original = owner, let current = snapshot else { return }
            let ticket = UUID()
            pageTicket = ticket
            defer { if pageTicket == ticket { pageTicket = nil } }
            do {
                let replacement = try await original.pairedPage(sequence: current.sequence, afterGroupIdHex: cursor)
                guard !retired, isCurrent(), !Task.isCancelled, owner === original else { return }
                guard snapshot?.sequence == current.sequence || snapshot?.sequence == replacement.sequence else { return }
                guard replacement.sequence > current.sequence else { throw AutomaticChatPresentationError.invalidSnapshot }
                try install(replacement)
                if backwards {
                    pageStarts.removeLast()
                } else {
                    // Keep the first-page reset plus a bounded recent cursor trail, never old rows.
                    if pageStarts.count == 128 { pageStarts.remove(at: 1) }
                    pageStarts.append(cursor)
                }
            } catch {
                guard !retired, isCurrent(), owner === original, snapshot?.sequence == current.sequence else { return }
                refuse(original)
            }
        }

        private func observe() async {
            while !retired, isCurrent(), !Task.isCancelled {
                await observeOnce()
                guard !retired, isCurrent(), !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }

        private func observeOnce() async {
            do {
                let original = try await runtime.openAccountChatList(accountRef: accountRef, initialRows: 128)
                guard !retired, isCurrent(), !Task.isCancelled else {
                    original.cancel()
                    return
                }
                owner = original
                pageStarts = [nil]
                guard let initial = original.snapshot() else { throw AutomaticChatPresentationError.invalidSnapshot }
                try install(initial)
                while let replacement = try await original.next() {
                    guard !retired, isCurrent(), !Task.isCancelled, owner === original else {
                        original.cancel()
                        return
                    }
                    try install(replacement)
                }
                guard !retired, isCurrent(), owner === original else { return }
                refuse(original)
            } catch {
                guard !retired, isCurrent(), !Task.isCancelled else { return }
                if let original = owner {
                    refuse(original)
                } else {
                    snapshot = nil
                    self.error = .unavailable
                    isLoading = false
                }
            }
        }

        private func install(_ replacement: AccountChatListWindowSnapshotFfi) throws {
            guard !replacement.generation.isEmpty, replacement.rows.count <= 128 else {
                throw AutomaticChatPresentationError.invalidSnapshot
            }
            if let current = snapshot {
                guard replacement.generation == current.generation, replacement.sequence >= current.sequence else {
                    throw AutomaticChatPresentationError.invalidSnapshot
                }
                if replacement.sequence == current.sequence { return }
            }
            snapshot = replacement
            isLoading = false
            error = nil
        }

        private func refuse(_ original: any AccountChatListObserving) {
            pageStarts = [nil]
            scrollPageArmed = false
            original.cancel()
            owner = nil
            snapshot = nil
            isLoading = false
            error = .unavailable
        }
    }
#endif
