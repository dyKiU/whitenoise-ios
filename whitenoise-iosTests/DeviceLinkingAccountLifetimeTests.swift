import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    nonisolated private final class LifetimeSubscription: DeviceLinkingSubscription, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: CheckedContinuation<DeviceLinkingSnapshotFfi, Error>?
        private var closes = 0
        private var reads = 0
        var readCount: Int { lock.withLock { reads } }
        var closeCount: Int { lock.withLock { closes } }
        var isWaiting: Bool { lock.withLock { pending != nil } }
        override func close() { lock.withLock { closes += 1 } }
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
    nonisolated private final class LifetimeSession: DeviceLinkingSession, @unchecked Sendable {
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

    @MainActor @Suite struct DeviceLinkingAccountLifetimeTests {
        private func defaults() -> UserDefaults {
            IsolatedAccountDefaults.make()
        }
        private func waitFor(_ condition: () -> Bool) async {
            for _ in 0..<200 {
                if condition() { return }
                await Task.yield()
            }
        }

        @Test func accountReplacementCancelsExactOldSessionAndClosesStream() async throws {
            let store = AccountStore(defaults: defaults())
            store.activeAccountRef = "old"
            let session = LifetimeSession(noPointer: .init())
            let old = try await store.holdDeviceLinkingSession(session, accountRef: "old")
            await waitFor { session.stream.isWaiting }
            store.activeAccountRef = "new"
            await waitFor { session.cancelCount == 1 }
            #expect(session.cancelCount == 1)
            #expect(session.stream.closeCount == 1)
            #expect(store.deviceLinkingScope == nil)
            session.stream.deliverDelayedSnapshot()
            await Task.yield()
            #expect(old.latestSnapshot == nil)
            try await old.cancel()
        }

        @Test func runtimeSuspensionCancelsExactSessionBeforeStorageRelease() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LinkingLifetime-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = try MarmotClient(rootPath: directory.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(client: client, accountDefaults: defaults())
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "old"
            let session = LifetimeSession(noPointer: .init())
            let old = try await app.accountStore.holdDeviceLinkingSession(session, accountRef: "old")
            await waitFor { session.stream.isWaiting }
            app.setAppSceneActive(false)
            await app.startRuntimeSuspension().value
            #expect(app.runtimeSuspendedForBackground)
            #expect(session.cancelCount == 1)
            #expect(session.stream.closeCount == 1)
            session.stream.deliverDelayedSnapshot()
            await Task.yield()
            #expect(old.latestSnapshot == nil)
            try await old.cancel()
        }

        @Test func failedCleanupRetainsExactOwnerForRetryAndRejectsLateSnapshot() async throws {
            let store = AccountStore(defaults: defaults())
            store.activeAccountRef = "old"
            let oldSession = LifetimeSession(noPointer: .init())
            oldSession.setCancellationFailure(true)
            let old = try await store.holdDeviceLinkingSession(oldSession, accountRef: "old")
            await waitFor { oldSession.stream.isWaiting }
            store.activeAccountRef = "new"
            await waitFor { old.cleanupError != nil }
            #expect(store.retiringDeviceLinkingScope === old)
            let replacement = LifetimeSession(noPointer: .init())
            await #expect(throws: CancellationError.self) {
                _ = try await store.holdDeviceLinkingSession(replacement, accountRef: "new")
            }
            #expect(store.deviceLinkingScope == nil)
            #expect(store.retiringDeviceLinkingScope === old)
            #expect(old.cleanupError != nil)
            oldSession.stream.deliverDelayedSnapshot()
            await Task.yield()
            #expect(old.latestSnapshot == nil)
            oldSession.setCancellationFailure(false)
            let fresh = try await store.holdDeviceLinkingSession(replacement, accountRef: "new")
            #expect(store.retiringDeviceLinkingScope == nil)
            #expect(fresh.latestSnapshot == nil)
            try await store.cancelDeviceLinking()
            replacement.stream.deliverDelayedSnapshot()
            #expect(oldSession.stream.closeCount == 1)
            #expect(replacement.cancelCount == 1)
        }

        @Test func foreignAttachmentCannotReplaceOriginalSession() async throws {
            let store = AccountStore(defaults: defaults())
            store.activeAccountRef = "original"
            let session = LifetimeSession(noPointer: .init())
            let original = try await store.holdDeviceLinkingSession(session, accountRef: "original")
            let foreign = LifetimeSession(noPointer: .init())
            await #expect(throws: CancellationError.self) {
                _ = try await store.holdDeviceLinkingSession(foreign, accountRef: "foreign")
            }
            #expect(store.deviceLinkingScope === original)
            #expect(session.cancelCount == 0)
            try await store.cancelDeviceLinking()
            session.stream.deliverDelayedSnapshot()
        }

        @Test(arguments: [false, true])
        func signOutAndWipeRefuseAccountMutationWhenOriginalCleanupFails(wipe: Bool) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LinkingExit-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = try MarmotClient(rootPath: directory.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(client: client, accountDefaults: defaults())
            app.setPhase(.ready)
            app.setAppSceneActive(true)
            app.activeAccountRef = "original"
            let session = LifetimeSession(noPointer: .init())
            session.setCancellationFailure(true)
            let original = try await app.accountStore.holdDeviceLinkingSession(session, accountRef: "original")
            let result = wipe ? await app.signOutAndWipeActiveAccount() : await app.signOut()
            #expect(!result)
            #expect(app.activeAccountRef == "original")
            #expect(app.accountStore.deviceLinkingScope == nil)
            #expect(app.accountStore.retiringDeviceLinkingScope === original)
            #expect(original.cleanupError != nil)
            #expect(session.cancelCount == 1)
            #expect(session.stream.closeCount == 1)
            #expect(try client.marmot.listAccounts().isEmpty)
            session.setCancellationFailure(false)
            app.setAppSceneActive(false)
            await app.startRuntimeSuspension().value
            session.stream.deliverDelayedSnapshot()
            #expect(app.client == nil)
        }
        @Test func suspensionWaitsForExactCancellationBeforeClosingRuntime() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LinkingOrder-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = try MarmotClient(rootPath: directory.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(client: client, accountDefaults: defaults())
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "original"
            let session = LifetimeSession(noPointer: .init())
            session.pauseNextCancellation()
            _ = try await app.accountStore.holdDeviceLinkingSession(session, accountRef: "original")
            app.setAppSceneActive(false)
            let suspension = app.startRuntimeSuspension()
            await waitFor { session.cancellationIsWaiting }
            #expect(session.cancellationIsWaiting)
            #expect(app.client != nil)
            #expect(!app.runtimeSuspendedForBackground)
            #expect(session.stream.closeCount == 1)
            session.completeCancellation()
            await suspension.value
            session.stream.deliverDelayedSnapshot()
            #expect(app.client == nil)
            #expect(app.runtimeSuspendedForBackground)
            #expect(session.cancelCount == 1)
        }
        @Test func closedStreamStopsWithoutRepolling() async throws {
            let store = AccountStore(defaults: defaults())
            store.activeAccountRef = "original"
            let session = LifetimeSession(noPointer: .init())
            let scope = try await store.holdDeviceLinkingSession(session, accountRef: "original")
            await waitFor { session.stream.isWaiting }
            session.stream.finishWithClosed()
            await waitFor { scope.observationError != nil }
            #expect(scope.observationError != nil)
            for _ in 0..<20 { await Task.yield() }
            #expect(session.stream.readCount == 1)
            #expect(scope.latestSnapshot == nil)
            try await store.cancelDeviceLinking()
        }

        @Test func concurrentWipeCannotEnterWhileSignOutAwaitsOriginalCancellation() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "LinkingConcurrentExit-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = try MarmotClient(rootPath: directory.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(client: client, accountDefaults: defaults())
            app.setPhase(.ready)
            app.setAppSceneActive(true)
            app.activeAccountRef = "original"
            let session = LifetimeSession(noPointer: .init())
            session.pauseNextCancellation()
            session.setCancellationFailure(true)
            _ = try await app.accountStore.holdDeviceLinkingSession(session, accountRef: "original")
            let signOut = Task { await app.signOut() }
            await waitFor { session.cancellationIsWaiting }
            #expect(session.cancellationIsWaiting)
            var wipeResult: Bool?
            let wipe = Task { wipeResult = await app.signOutAndWipeActiveAccount() }
            await waitFor { wipeResult != nil }
            #expect(wipeResult == false)
            #expect(session.cancelCount == 1)
            session.completeCancellation()
            #expect(await signOut.value == false)
            await wipe.value
            #expect(await app.signOutAndWipeActiveAccount() == false)
            #expect(session.cancelCount == 2)
            #expect(app.activeAccountRef == "original")
            #expect(try client.marmot.listAccounts().isEmpty)
            session.setCancellationFailure(false)
            app.setAppSceneActive(false)
            await app.startRuntimeSuspension().value
            session.stream.deliverDelayedSnapshot()
        }

        @Test(arguments: [false, true]) func pendingFactoryCannotAttachAfterAccountOrRuntimeReplacement(
            suspend: Bool
        ) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LinkingFactory-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = try MarmotClient(rootPath: directory.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(client: client, accountDefaults: defaults())
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "original"
            let session = LifetimeSession(noPointer: .init())
            var returnSession: CheckedContinuation<any DeviceLinkingSessionProtocol, Never>?
            let pending = Task {
                do {
                    _ = try await app.adoptDeviceLinkingFactory { exactClient, exactAccount in
                        #expect(exactClient === client)
                        #expect(exactAccount == "original")
                        return await withCheckedContinuation { returnSession = $0 }
                    }
                    return true
                } catch { return false }
            }
            await waitFor { returnSession != nil }
            #expect(returnSession != nil)
            if suspend {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                #expect(app.client == nil)
            } else {
                app.activeAccountRef = "replacement"
                app.activeAccountRef = "original"
            }
            returnSession?.resume(returning: session)
            #expect(await pending.value == false)
            #expect(app.accountStore.deviceLinkingScope == nil)
            #expect(session.cancelCount == 1)
            #expect(session.stream.closeCount == 1)
            try await app.accountStore.cancelDeviceLinking()
            session.stream.deliverDelayedSnapshot()
            if !suspend {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
            }
        }

        private func withFactoryRuntime(_ body: (AppState, MarmotClient) async throws -> Void) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "LinkingFactoryControl-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = try MarmotClient(rootPath: directory.path, relayUrls: ["wss://relay.example.invalid"])
            let app = AppState.test(client: client, accountDefaults: defaults())
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "original"
            do {
                try await body(app, client)
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
            } catch {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                throw error
            }
        }

        @Test func pendingFactoryCannotAttachToSameAccountAfterRealRuntimeRestart() async throws {
            try await withFactoryRuntime { app, oldClient in
                let generation = app.runtimeGeneration
                let session = LifetimeSession(noPointer: .init())
                var result: CheckedContinuation<any DeviceLinkingSessionProtocol, Never>?
                let pending = Task {
                    do {
                        _ = try await app.adoptDeviceLinkingFactory { _, _ in
                            await withCheckedContinuation { result = $0 }
                        }
                        return true
                    } catch { return false }
                }
                await waitFor { result != nil }
                #expect(result != nil)
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                #expect(app.client == nil)
                app.setAppSceneActive(true)
                await app.startForegroundActivation().value
                #expect(app.client != nil)
                #expect(app.client !== oldClient)
                #expect(app.runtimeGeneration > generation)
                app.activeAccountRef = "original"
                result?.resume(returning: session)
                #expect(await pending.value == false)
                #expect(app.accountStore.deviceLinkingScope == nil)
                #expect(session.cancelCount == 1)
                #expect(session.stream.closeCount == 1)
                session.stream.deliverDelayedSnapshot()
            }
        }

        @Test func lateFactoryCleanupFailureRetainsExactSessionForRetry() async throws {
            try await withFactoryRuntime { app, _ in
                let session = LifetimeSession(noPointer: .init())
                session.setCancellationFailure(true)
                var result: CheckedContinuation<any DeviceLinkingSessionProtocol, Never>?
                let pending = Task {
                    do {
                        _ = try await app.adoptDeviceLinkingFactory { _, _ in
                            await withCheckedContinuation { result = $0 }
                        }
                        return true
                    } catch { return false }
                }
                await waitFor { result != nil }
                #expect(result != nil)
                app.activeAccountRef = "replacement"
                result?.resume(returning: session)
                #expect(await pending.value == false)
                let retired = app.accountStore.retiringDeviceLinkingScope
                #expect(retired != nil)
                #expect(retired?.cleanupError != nil)
                #expect(app.accountStore.deviceLinkingScope == nil)
                #expect(session.cancelCount == 1)
                #expect(session.stream.closeCount == 1)
                session.setCancellationFailure(false)
                try await app.accountStore.cancelDeviceLinking()
                #expect(session.cancelCount == 2)
                #expect(session.stream.closeCount == 1)
                #expect(app.accountStore.retiringDeviceLinkingScope == nil)
                session.stream.deliverDelayedSnapshot()
                #expect(retired?.latestSnapshot == nil)
            }
        }

        @Test func pendingFactoryIsBoundedAndCurrentOriginalResultIsAdopted() async throws {
            try await withFactoryRuntime { app, _ in
                let session = LifetimeSession(noPointer: .init())
                var result: CheckedContinuation<any DeviceLinkingSessionProtocol, Never>?
                let pending = Task {
                    try await app.adoptDeviceLinkingFactory { _, _ in
                        await withCheckedContinuation { result = $0 }
                    }
                }
                await waitFor { result != nil }
                #expect(result != nil)
                var competingFactoryCalled = false
                await #expect(throws: CancellationError.self) {
                    _ = try await app.adoptDeviceLinkingFactory { _, _ in
                        competingFactoryCalled = true
                        return LifetimeSession(noPointer: .init())
                    }
                }
                #expect(!competingFactoryCalled)
                result?.resume(returning: session)
                let scope = try await pending.value
                #expect(app.accountStore.deviceLinkingScope === scope)
                #expect(scope.accountRef == "original")
                #expect(session.cancelCount == 0)
                await waitFor { session.stream.isWaiting }
                session.stream.deliverDelayedSnapshot()
                await waitFor { scope.latestSnapshot?.revision == 7 }
                #expect(scope.latestSnapshot?.revision == 7)
                try await app.accountStore.cancelDeviceLinking()
                session.stream.deliverDelayedSnapshot()
                #expect(session.cancelCount == 1)
                #expect(session.stream.closeCount == 1)
            }
        }

        @Test func ownedAppFactoriesUseRealWrappersAndReleaseFailedReservations() async throws {
            try await withFactoryRuntime { app, client in
                await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                    _ = try await app.beginOwnedDeviceLinkingSession()
                }
                await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                    _ = try await app.approveOwnedDeviceLinkingSession(request: Data(), target: nil)
                }
                #expect(app.accountStore.deviceLinkingScope == nil)
                #expect(app.accountStore.retiringDeviceLinkingScope == nil)
                let actualAccounts = try client.marmot.listAccounts()
                #expect(actualAccounts.isEmpty)
            }
        }
    }
#endif
