#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    @MainActor protocol SelectedChatHandle: AnyObject {
        func invalidate()
        func cancel() async throws
    }
    extension SelectedChatCopyScope: SelectedChatHandle {}
    extension SelectedChatConsentScope: SelectedChatHandle {}

    /// One account/runtime lifetime. A retired owner never becomes active again.
    @MainActor @Observable final class SelectedChatAccountOwner {
        private(set) var isActive = true
        private(set) var copy: SelectedChatCopyScope?
        private(set) var consent: SelectedChatConsentScope?
        @ObservationIgnored private let accountRef: String
        @ObservationIgnored private let runtime: MarmotClient
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        @ObservationIgnored private var cancelFactory: (() -> Void)?
        @ObservationIgnored private var retiring: [any SelectedChatHandle] = []
        @ObservationIgnored private var cleanup: Task<Void, Error>?

        init(accountRef: String, runtime: MarmotClient, isCurrent: @escaping @MainActor () -> Bool) {
            self.accountRef = accountRef
            self.runtime = runtime
            self.isCurrent = isCurrent
        }
        var isCurrentOwner: Bool { isActive && isCurrent() }
        func matches(accountRef: String, runtime: MarmotClient) -> Bool {
            self.accountRef == accountRef && self.runtime === runtime && isCurrentOwner
        }

        func adoptCopy(
            _ factory: @escaping @MainActor (MarmotClient, String) async throws -> any SelectedChatCopyProtocol
        ) async throws -> SelectedChatCopyScope {
            guard isCurrentOwner else { throw MarmotKitError.SelectedChatCopyClosed }
            if let copy {
                guard !copy.isActive else { throw MarmotKitError.SelectedChatCopyBusy }
                try await copy.cancel()
                self.copy = nil
            }
            return try await adopt(
                factory,
                make: {
                    SelectedChatCopyScope(
                        accountRef: self.accountRef, original: $0,
                        isCurrent: { [weak self] in self?.isCurrentOwner == true })
                },
                install: { self.copy = $0 })
        }

        func adoptConsent(
            _ factory: @escaping @MainActor (MarmotClient, String) async throws -> any SelectedChatConsentProtocol
        ) async throws -> SelectedChatConsentScope {
            guard isCurrentOwner else { throw MarmotKitError.SelectedChatCopyClosed }
            if let consent {
                guard !consent.isActive else { throw MarmotKitError.SelectedChatCopyBusy }
                try await consent.cancel()
                self.consent = nil
            }
            return try await adopt(
                factory,
                make: {
                    SelectedChatConsentScope(
                        accountRef: self.accountRef, original: $0,
                        isCurrent: { [weak self] in self?.isCurrentOwner == true })
                },
                install: { self.consent = $0 })
        }

        private func adopt<Original: Sendable, Handle: SelectedChatHandle>(
            _ factory: @escaping @MainActor (MarmotClient, String) async throws -> Original,
            make: (Original) -> Handle,
            install: (Handle) -> Void
        ) async throws -> Handle {
            try Task.checkCancellation()
            guard isCurrentOwner else { throw MarmotKitError.SelectedChatCopyClosed }
            guard cancelFactory == nil else { throw MarmotKitError.SelectedChatCopyBusy }
            // A cancelled caller can leave its late original here while this account remains active.
            try await finishCleanup()
            try Task.checkCancellation()
            guard isCurrentOwner else { throw MarmotKitError.SelectedChatCopyClosed }
            guard cancelFactory == nil else { throw MarmotKitError.SelectedChatCopyBusy }
            let task = Task {
                try Task.checkCancellation()
                return try await factory(runtime, accountRef)
            }
            cancelFactory = { task.cancel() }
            defer { cancelFactory = nil }
            let original = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            let held = make(original)
            guard isCurrentOwner, !Task.isCancelled else {
                held.invalidate()
                retiring.append(held)
                try await finishCleanup()
                throw MarmotKitError.SelectedChatCopyClosed
            }
            install(held)
            return held
        }

        func invalidate() {
            guard isActive else { return }
            isActive = false
            cancelFactory?()
            if let copy {
                copy.invalidate()
                retiring.append(copy)
            }
            if let consent {
                consent.invalidate()
                retiring.append(consent)
            }
            copy = nil
            consent = nil
            if !retiring.isEmpty { cleanup = Task { try await cleanupRetired() } }
        }

        /// An ignored-cancellation factory still owns its future result and fences Core teardown.
        func retryCleanup() async throws {
            var firstError: Error?
            if let copy, !copy.isActive {
                do {
                    try await copy.cancel()
                    self.copy = nil
                } catch { firstError = error }
            }
            if let consent, !consent.isActive {
                do {
                    try await consent.cancel()
                    self.consent = nil
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            do { try await finishCleanup() } catch { if firstError == nil { firstError = error } }
            if let firstError { throw firstError }
            guard cancelFactory == nil else { throw MarmotKitError.SelectedChatCopyBusy }
        }

        private func finishCleanup() async throws {
            while !retiring.isEmpty {
                let task: Task<Void, Error>
                if let cleanup {
                    task = cleanup
                } else {
                    task = Task { try await cleanupRetired() }
                    cleanup = task
                }
                do {
                    try await task.value
                    cleanup = nil
                } catch {
                    cleanup = nil
                    throw error
                }
            }
        }

        private func cleanupRetired() async throws {
            var firstError: Error?
            for held in retiring {
                do {
                    try await held.cancel()
                    retiring.removeAll { $0 === held }
                } catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }
    }
#endif
