import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    @Suite @MainActor
    struct NativeHistoryRecipientQueryTests {
        @Test func malformedGroupRetainsNativeTypedRefusalWithoutAccountEffects() async throws {
            try await withClient { client in
                for group in ["", "invalid", String(repeating: "ab", count: 256)] {
                    await #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                        _ = try await client.historyTransferRecipients(accountRef: "missing", groupIdHex: group)
                    }
                }
                let accounts = try client.marmot.listAccounts()
                #expect(accounts.isEmpty)
            }
        }

        @Test func validGroupMissingAccountRetainsRuntimeRefusalWithoutAccountEffects() async throws {
            try await withClient { client in
                await #expect(throws: MarmotKitError.HistoryTransferRuntimeUnavailable) {
                    _ = try await client.historyTransferRecipients(
                        accountRef: "missing", groupIdHex: String(repeating: "ab", count: 16))
                }
                let accounts = try client.marmot.listAccounts()
                #expect(accounts.isEmpty)
            }
        }

        private func withClient(_ body: (MarmotClient) async throws -> Void) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryRecipientQuery-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try MarmotClient(rootPath: root.path, relayUrls: ["wss://relay.example.invalid"])
            do {
                try await body(client)
            } catch {
                try await client.marmot.shutdownAndClose()
                throw error
            }
            try await client.marmot.shutdownAndClose()
        }
    }
#endif
