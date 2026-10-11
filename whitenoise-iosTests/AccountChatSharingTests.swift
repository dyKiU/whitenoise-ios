import Foundation
import MarmotKit
import Synchronization
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // These controls exercise native presentation/lifetime only, never SDK permission.
    nonisolated private final class SharingOriginal: AccountSharingOriginal, Sendable {
        nonisolated private struct State: Sendable {
            var value = sharingSnapshot()
            var approvals: [UInt64] = []
            var cancellations = 0
        }
        private let state = Mutex(State())
        var approved: [UInt64] { state.withLock { $0.approvals } }
        var cancelCount: Int { state.withLock { $0.cancellations } }
        func snapshot() throws -> AccountSharingSnapshotFfi { state.withLock { $0.value } }
        func setSnapshot(_ value: AccountSharingSnapshotFfi) { state.withLock { $0.value = value } }
        func approve(displayedRevision: UInt64) async throws {
            state.withLock { $0.approvals.append(displayedRevision) }
        }
        func cancel() { state.withLock { $0.cancellations += 1 } }
    }
    nonisolated private func sharingSnapshot(group: String = "0102", revision: UInt64 = 7) -> AccountSharingSnapshotFfi
    {
        .init(
            protectedGroupIdHex: group, protectedEpoch: 1,
            sourceDevice: Data(repeating: 1, count: 32), recipientDevice: Data(repeating: 2, count: 32),
            revision: revision, approved: false, complete: false)
    }
    @MainActor private final class SharingFactoryGate {
        var continuation: CheckedContinuation<[any AccountSharingOriginal], Never>?
        func result() async -> [any AccountSharingOriginal] {
            await withCheckedContinuation { continuation = $0 }
        }
        func finish(_ originals: [any AccountSharingOriginal]) {
            let old = continuation
            continuation = nil
            old?.resume(returning: originals)
        }
    }
    @MainActor @Suite struct AccountChatSharingTests {
        @Test func targetsAndRequestNeverApproveAndReviewUsesExactRevision() async throws {
            let sdk = SharingOriginal()
            let held = NativeAccountSharingScope(original: sdk, isCurrent: { true })
            var recipients: [Data] = []
            let model = AccountChatSharingViewModel(
                readTargets: {
                    .init(
                        protectedGroupIdHex: "0102", protectedEpoch: 1,
                        targets: [.init(leafIndex: 2, device: Data(repeating: 2, count: 32))])
                },
                begin: {
                    recipients.append($0)
                    return held
                }, readPending: { [held] }, isCurrent: { true })
            try await model.loadTargets()
            try model.select(device: Data(repeating: 2, count: 32))
            #expect(sdk.approved.isEmpty)
            try await model.requestSharing()
            #expect(recipients == [Data(repeating: 2, count: 32)])
            #expect(sdk.approved.isEmpty)
            await #expect(throws: MarmotKitError.AccountSharingStaleRevision) {
                try await model.approveSharing(displayedRevision: 8)
            }
            #expect(sdk.approved.isEmpty)
            try await model.approveSharing(displayedRevision: 7)
            #expect(sdk.approved == [7])
            model.invalidate()
            await #expect(throws: MarmotKitError.AccountSharingClosed) {
                try await model.approveSharing(displayedRevision: 7)
            }
            #expect(sdk.approved == [7])
        }
        @Test func malformedChangedOriginalScopeCancelsRatherThanCreatingReview() throws {
            let sdk = SharingOriginal()
            let held = NativeAccountSharingScope(original: sdk, isCurrent: { true })
            try held.refresh()
            sdk.setSnapshot(sharingSnapshot(group: "0304"))
            #expect(throws: MarmotKitError.AccountSharingNotReady) { try held.refresh() }
            #expect(!held.isActive)
            #expect(held.snapshot == nil)
            #expect(sdk.cancelCount == 1)
            #expect(sdk.approved.isEmpty)
        }
        @Test func cancelledPendingFactoryFencesFreshAcquisitionAndRetiresExactLateOriginal() async throws {
            let gate = SharingFactoryGate()
            let lifetime = AccountSharingAccountLifetime()
            let owner = try lifetime.currentOwner(isCurrent: { true })
            let sdk = SharingOriginal()
            let task = Task { try? await owner.acquire { await gate.result() } }
            for _ in 0..<200 {
                if gate.continuation != nil { break }
                await Task.yield()
            }
            try #require(gate.continuation != nil)
            lifetime.invalidate()
            #expect(throws: MarmotKitError.AccountSharingNotReady) { try lifetime.retryCleanup() }
            #expect(throws: MarmotKitError.AccountSharingNotReady) {
                _ = try lifetime.currentOwner(isCurrent: { true })
            }
            gate.finish([sdk])
            #expect(await task.value == nil)
            #expect(sdk.cancelCount == 1)
            try lifetime.retryCleanup()
            #expect(sdk.approved.isEmpty)
        }
        @Test func realAccountReplacementAndReturnRetiresLateSharingOriginal() async throws {
            let store = AccountStore(defaults: IsolatedAccountDefaults.make())
            store.activeAccountRef = "A"
            let epoch = store.deviceLinkingOwnershipIdentity
            let owner = try store.accountSharingLifetime.currentOwner(isCurrent: {
                store.activeAccountRef == "A" && store.deviceLinkingOwnershipIdentity == epoch
            })
            let sdk = SharingOriginal()
            let gate = SharingFactoryGate()
            let task = Task { try? await owner.acquire { await gate.result() } }
            for _ in 0..<200 {
                if gate.continuation != nil { break }
                await Task.yield()
            }
            try #require(gate.continuation != nil)
            store.activeAccountRef = "B"
            store.activeAccountRef = "A"
            #expect(throws: MarmotKitError.AccountSharingNotReady) { try store.accountSharingLifetime.retryCleanup() }
            gate.finish([sdk])
            #expect(await task.value == nil)
            #expect(sdk.cancelCount == 1)
            #expect(sdk.approved.isEmpty)
            try store.accountSharingLifetime.retryCleanup()
        }

        @Test func repeatedPendingListingReusesOriginalWithoutFreshFactory() async throws {
            let owner = AccountSharingAccountOwner(isCurrent: { true })
            let sdk = SharingOriginal()
            var calls = 0
            let first = try await owner.acquire {
                calls += 1
                return [sdk]
            }
            let second = try await owner.acquire {
                calls += 1
                return []
            }
            #expect(calls == 1)
            #expect(first.first === second.first)
            owner.invalidate()
            #expect(sdk.cancelCount == 1)
        }
    }
#endif
