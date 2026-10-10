import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    private actor ScopedHistoryReadGate {
        private var entered = false
        private var entry: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        func pause() async {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
                entered = true
                entry?.resume()
                entry = nil
            }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { entry = $0 }
        }
        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    @MainActor struct SynchronizedHistoryAccountScopeTests {
        private func record() -> SynchronizedHistoryRecord {
            .init(
                id: String(repeating: "01", count: 32), authorPubkey: String(repeating: "02", count: 32),
                createdAt: 1, expiresAt: nil, deleted: false, content: "isolated source-attested history",
                tags: [], mediaAttachments: [], transferId: Data(repeating: 3, count: 32),
                sourceDevice: Data(repeating: 4, count: 32), manifestDigest: Data(repeating: 5, count: 32))
        }
        private func app(directory: URL) async throws -> AppState {
            let client = try MarmotClient(rootPath: directory.path, relayUrls: ["wss://relay.example.invalid"])
            let defaults = try #require(UserDefaults(suiteName: "HistoryScope-\(UUID())"))
            let app = AppState.test(client: client, accountDefaults: defaults)
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "alice"
            return app
        }
        private func close(_ app: AppState) async {
            app.setAppSceneActive(false)
            await app.startRuntimeSuspension().value
        }

        @Test func actualAccountAtoBtoARejectsLateOriginalRead() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryScope-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let app = try await app(directory: directory)
            let gate = ScopedHistoryReadGate()
            let value = record()
            let old = try app.makeSynchronizedHistoryModel(groupIdHex: "chat") { account, group, _, _ in
                #expect(account == "alice")
                #expect(group == "chat")
                await gate.pause()
                return .init(records: [value], nextMessageId: nil)
            }
            let loading = Task { await old.loadNextPage() }
            await gate.waitUntilEntered()
            app.activeAccountRef = "bob"
            app.activeAccountRef = "alice"
            #expect(!old.isActive)
            let fresh = try app.makeSynchronizedHistoryModel(groupIdHex: "chat") { _, _, _, _ in
                .init(records: [], nextMessageId: nil)
            }
            #expect(fresh !== old)
            await gate.release()
            await loading.value
            #expect(old.records.isEmpty)
            #expect(fresh.records.isEmpty)
            await close(app)
        }

        @Test func actualRuntimeSuspensionInvalidatesBeforeLateReadAndSameAccountRestart() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistorySuspend-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let app = try await app(directory: directory)
            let gate = ScopedHistoryReadGate()
            let value = record()
            let old = try app.makeSynchronizedHistoryModel(groupIdHex: "chat") { _, _, _, _ in
                await gate.pause()
                return .init(records: [value], nextMessageId: nil)
            }
            let loading = Task { await old.loadNextPage() }
            await gate.waitUntilEntered()
            await close(app)
            #expect(!old.isActive)
            #expect(app.client == nil)
            #expect(app.accountStore.synchronizedHistoryModels.isEmpty)
            await gate.release()
            await loading.value
            #expect(old.records.isEmpty)
            app.setAppSceneActive(true)
            await app.bootstrap()
            app.activeAccountRef = "alice"
            let fresh = try app.makeSynchronizedHistoryModel(groupIdHex: "chat") { _, _, _, _ in
                .init(records: [], nextMessageId: nil)
            }
            #expect(fresh !== old)
            await close(app)
        }

        @Test func exactChatReleaseDoesNotCancelAnotherOrReplacementReader() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryRelease-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let app = try await app(directory: directory)
            let read: SynchronizedHistoryViewModel.Reader = { _, _, _, _ in
                .init(records: [], nextMessageId: nil)
            }
            let first = try app.makeSynchronizedHistoryModel(groupIdHex: "first", read: read)
            let second = try app.makeSynchronizedHistoryModel(groupIdHex: "second", read: read)
            #expect(try app.makeSynchronizedHistoryModel(groupIdHex: "second", read: read) === second)
            app.releaseSynchronizedHistoryModel(first, groupIdHex: "second")
            #expect(second.isActive)
            app.releaseSynchronizedHistoryModel(first, groupIdHex: "first")
            #expect(!first.isActive)
            #expect(second.isActive)
            let replacement = try app.makeSynchronizedHistoryModel(groupIdHex: "first", read: read)
            app.releaseSynchronizedHistoryModel(first, groupIdHex: "first")
            #expect(replacement.isActive)
            await close(app)
        }

        @Test func nativeQueryMissingAccountFailsWithoutProjectionOrAccountCreation() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryQuery-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = try MarmotClient(rootPath: directory.path, relayUrls: ["wss://relay.example.invalid"])
            do {
                _ = try await client.synchronizedHistoryPage(
                    accountRef: "missing", groupIdHex: "01", afterMessageIdHex: nil, limit: 200)
                Issue.record("Missing native account must not produce an archive page")
            } catch {
                #expect(error is MarmotKitError)
            }
            #expect(try client.marmot.listAccounts().isEmpty)
            try await client.marmot.shutdownAndClose()
        }
    }
#endif
