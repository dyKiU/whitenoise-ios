#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    /// Cleanup always retains the exact original SDK handle, including failed retries.
    @MainActor @Observable private final class SelectedChatLifetime {
        private(set) var isActive = true
        private(set) var cleanupError: Error?
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        @ObservationIgnored private let cancelOriginal: @MainActor () async throws -> Void
        @ObservationIgnored private var cleanup: Task<Void, Error>?

        init(isCurrent: @escaping @MainActor () -> Bool, cancel: @escaping @MainActor () async throws -> Void) {
            self.isCurrent = isCurrent
            cancelOriginal = cancel
        }
        var isLive: Bool { isActive && isCurrent() }
        func checkActive() throws {
            try Task.checkCancellation()
            guard isLive else { throw MarmotKitError.SelectedChatCopyClosed }
        }
        func invalidate() { isActive = false }
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
    }

    /// One original SDK request. Snapshot records can never construct its authority.
    @MainActor @Observable final class SelectedChatCopyScope {
        let accountRef: String
        @ObservationIgnored private let original: any SelectedChatCopyProtocol
        private let lifetime: SelectedChatLifetime
        var isActive: Bool { lifetime.isLive }
        var cleanupError: Error? { lifetime.cleanupError }

        init(
            accountRef: String, original: any SelectedChatCopyProtocol,
            isCurrent: @escaping @MainActor () -> Bool = { true }
        ) {
            self.accountRef = accountRef
            self.original = original
            lifetime = SelectedChatLifetime(isCurrent: isCurrent) { try await original.cancel() }
        }
        func snapshot() async throws -> SelectedChatCopySnapshotFfi {
            try lifetime.checkActive()
            let value = try await original.snapshot()
            try lifetime.checkActive()
            return value
        }
        func requestPacket(displayedRevision: UInt64) async throws -> Data {
            try lifetime.checkActive()
            let value = try await original.requestPacket(revision: displayedRevision)
            try lifetime.checkActive()
            return value
        }
        func receiveConsentPacket(displayedRevision: UInt64, packet: Data) async throws {
            try lifetime.checkActive()
            try await original.receiveConsentPacket(revision: displayedRevision, packet: packet)
            try lifetime.checkActive()
        }
        func receiveOfferPacket(displayedRevision: UInt64, packet: Data) async throws {
            try lifetime.checkActive()
            try await original.receiveOfferPacket(revision: displayedRevision, packet: packet)
            try lifetime.checkActive()
        }
        func continueCopy(displayedRevision: UInt64) async throws {
            try lifetime.checkActive()
            try await original.continueCopy(revision: displayedRevision)
            try lifetime.checkActive()
        }
        func invalidate() { lifetime.invalidate() }
        func cancel() async throws { try await lifetime.cancel() }
    }

    /// One original recipient consent, independent of protected-device enrollment.
    @MainActor @Observable final class SelectedChatConsentScope {
        let accountRef: String
        @ObservationIgnored private let original: any SelectedChatConsentProtocol
        private let lifetime: SelectedChatLifetime
        var isActive: Bool { lifetime.isLive }
        var cleanupError: Error? { lifetime.cleanupError }

        init(
            accountRef: String, original: any SelectedChatConsentProtocol,
            isCurrent: @escaping @MainActor () -> Bool = { true }
        ) {
            self.accountRef = accountRef
            self.original = original
            lifetime = SelectedChatLifetime(isCurrent: isCurrent) { try await original.cancel() }
        }
        func snapshot() async throws -> SelectedChatConsentSnapshotFfi {
            try lifetime.checkActive()
            let value = try await original.snapshot()
            try lifetime.checkActive()
            return value
        }
        func approve(displayedRevision: UInt64) async throws {
            try lifetime.checkActive()
            try await original.approve(revision: displayedRevision)
            try lifetime.checkActive()
        }
        func responsePacket(displayedRevision: UInt64) async throws -> Data {
            try lifetime.checkActive()
            let value = try await original.responsePacket(revision: displayedRevision)
            try lifetime.checkActive()
            return value
        }
        func offerPacket(displayedRevision: UInt64) async throws -> Data {
            try lifetime.checkActive()
            let value = try await original.offerPacket(revision: displayedRevision)
            try lifetime.checkActive()
            return value
        }
        func invalidate() { lifetime.invalidate() }
        func cancel() async throws { try await lifetime.cancel() }
    }
#endif
