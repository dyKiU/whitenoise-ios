import Foundation
import MarmotKit

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // Generated superclass requires unchecked conformance; NSLock protects all mutable controls.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated final class LifetimeSubscription: DeviceLinkingSubscription, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: CheckedContinuation<DeviceLinkingSnapshotFfi, Error>?
        private var closes = 0
        private var reads = 0
        var readCount: Int { lock.withLock { reads } }
        var closeCount: Int { lock.withLock { closes } }
        var isWaiting: Bool { lock.withLock { pending != nil } }
        override func closeStream() { lock.withLock { closes += 1 } }
        override func next() async throws -> DeviceLinkingSnapshotFfi {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    reads += 1
                    pending = continuation
                }
            }
        }
        func finishWithClosed() {
            let continuation = lock.withLock {
                let result = pending
                pending = nil
                return result
            }
            continuation?.resume(throwing: MarmotKitError.DeviceLinkingClosed)
        }
        func deliverDelayedSnapshot() {
            let continuation = lock.withLock {
                let result = pending
                pending = nil
                return result
            }
            continuation?.resume(
                returning: DeviceLinkingSnapshotFfi(
                    revision: 7, phase: .comparisonAvailable, decimals: nil))
        }
    }
    // Generated superclass requires unchecked conformance; NSLock protects all mutable controls.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated final class LifetimeSession: DeviceLinkingSession, @unchecked Sendable {
        let stream = LifetimeSubscription(noPointer: .init())
        private let lock = NSLock()
        private var cancellations = 0
        private var shouldFail = false
        private var pauseCancellation = false
        private var waitingCancellation: CheckedContinuation<Void, Never>?
        var cancellationIsWaiting: Bool { lock.withLock { waitingCancellation != nil } }
        func pauseNextCancellation() { lock.withLock { pauseCancellation = true } }
        func completeCancellation() {
            let continuation = lock.withLock {
                pauseCancellation = false
                let result = waitingCancellation
                waitingCancellation = nil
                return result
            }
            continuation?.resume()
        }
        func setCancellationFailure(_ value: Bool) { lock.withLock { shouldFail = value } }
        var cancelCount: Int { lock.withLock { cancellations } }
        private var bootstrapWaiter: CheckedContinuation<Void, Never>?
        private var automaticChoices: [(UInt64, Bool)] = []
        var recordedAutomaticChoices: [(UInt64, Bool)] { lock.withLock { automaticChoices } }
        override func continueAutomaticLinking(displayedRevision: UInt64, shareChats: Bool) async throws {
            lock.withLock { automaticChoices.append((displayedRevision, shareChats)) }
        }
        var bootstrapIsWaiting: Bool { lock.withLock { bootstrapWaiter != nil } }
        override func automaticPairingCode() async throws -> String {
            await withCheckedContinuation { continuation in
                lock.withLock { bootstrapWaiter = continuation }
            }
            return "WNPAIR1:synthetic-bootstrap"
        }
        func finishBootstrap() {
            let continuation = lock.withLock {
                let result = bootstrapWaiter
                bootstrapWaiter = nil
                return result
            }
            continuation?.resume()
        }
        override func subscribe() -> DeviceLinkingSubscription { stream }
        override func cancel() async throws {
            lock.withLock { cancellations += 1 }
            if lock.withLock({ pauseCancellation }) {
                await withCheckedContinuation { continuation in
                    lock.withLock { waitingCancellation = continuation }
                }
            }
            if lock.withLock({ shouldFail }) { throw CancellationError() }
        }
    }

#endif
