import Foundation
import MarmotKit
import XCTest

@testable import whitenoise_ios

// Callback storage is isolated to this test; its lock protects actual SDK callback threads.
// swiftlint:disable:next no_unchecked_sendable
nonisolated private final class IsolatedNativeSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    private var labels: Set<String> = []
    private var writes = 0
    let refuseWrites: Bool
    init(refuseWrites: Bool = false) { self.refuseWrites = refuseWrites }
    var writeCount: Int { lock.withLock { writes } }
    func hasSecretForLabel(label: String) throws -> Bool { lock.withLock { labels.contains(label) } }
    func hasSecretForAccountId(accountIdHex: String) throws -> Bool { lock.withLock { secrets[accountIdHex] != nil } }
    func writeSecret(label: String, accountIdHex: String, secretKeyHex: String) throws {
        try lock.withLock {
            writes += 1
            guard !refuseWrites else { throw BoundaryFailure.refused }
            secrets[accountIdHex] = secretKeyHex
            labels.insert(label)
        }
    }
    func loadSecret(label: String, accountIdHex: String) throws -> String {
        try lock.withLock {
            guard let secret = secrets[accountIdHex] else { throw BoundaryFailure.refused }
            return secret
        }
    }
    func removeSecret(label: String, accountIdHex: String) throws {
        lock.withLock {
            secrets.removeValue(forKey: accountIdHex)
            labels.remove(label)
        }
    }
    private enum BoundaryFailure: Error { case refused }
}

@MainActor final class NativeSecretStoreBoundaryTests: XCTestCase {
    private var relayURL: String {
        ProcessInfo.processInfo.environment["WN_NATIVE_TEST_RELAY_URL"] ?? "ws://127.0.0.1:18181"
    }

    func testExplicitStoreReceivesActualIdentityAndSurvivesFreshRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeSecretStore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IsolatedNativeSecretStore()
        let client = try MarmotClient(
            rootPath: root.path, relayUrls: [relayURL], cursorPersistence: .advance,
            telemetryConfig: .current(), secretStore: store, relayPolicy: .allowLoopback)
        let account: String
        do {
            try await client.marmot.start()
            let identity = try await client.marmot.createIdentity(
                defaultRelays: [relayURL],
                bootstrapRelays: [relayURL], inboxRelays: [relayURL])
            account = identity.accountIdHex
            XCTAssertEqual(store.writeCount, 1)
            XCTAssertTrue(try store.hasSecretForAccountId(accountIdHex: account))
            try await client.marmot.shutdownAndClose()
        } catch {
            try await client.marmot.shutdownAndClose()
            throw error
        }
        let reopened = try client.freshRuntime()
        do {
            let accounts = try await reopened.listAccounts()
            XCTAssertEqual(accounts.map(\.accountIdHex), [account])
            let secret = try await reopened.revealNsec(accountRef: account)
            XCTAssertFalse(secret.isEmpty)
            XCTAssertEqual(store.writeCount, 1)
            try await reopened.marmot.removeAccount(accountRef: account)
            try await reopened.marmot.shutdownAndClose()
        } catch {
            try await reopened.marmot.shutdownAndClose()
            throw error
        }
    }

    func testExplicitStoreRefusalCannotFallBackToPlatformCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeSecretStoreRefusal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IsolatedNativeSecretStore(refuseWrites: true)
        let client = try MarmotClient(
            rootPath: root.path, relayUrls: [relayURL], cursorPersistence: .advance,
            telemetryConfig: .current(), secretStore: store, relayPolicy: .allowLoopback)
        do {
            try await client.marmot.start()
            let identity = try await client.marmot.createIdentity(
                defaultRelays: [relayURL],
                bootstrapRelays: [relayURL], inboxRelays: [relayURL])
            try await client.marmot.removeAccount(accountRef: identity.accountIdHex)
            XCTFail("Explicit callback refusal must not silently fall back to the platform store")
        } catch { XCTAssertEqual(store.writeCount, 1) }
        try await client.marmot.shutdownAndClose()
    }
    func testOmittedDependenciesKeepProductionRelayPolicyAcrossFreshRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeDefaultBoundary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try MarmotClient(rootPath: root.path, relayUrls: [])
        let before = await client.classifyRelayEndpoints([relayURL])
        XCTAssertEqual(before.count, 1)
        XCTAssertNotEqual(before.first?.policy, .allowed)
        let accounts = try await client.listAccounts()
        XCTAssertTrue(accounts.isEmpty)
        try await client.marmot.shutdownAndClose()
        let reopened = try client.freshRuntime()
        let after = await reopened.classifyRelayEndpoints([relayURL])
        XCTAssertEqual(after, before)
        let reopenedAccounts = try await reopened.listAccounts()
        XCTAssertTrue(reopenedAccounts.isEmpty)
        try await reopened.marmot.shutdownAndClose()
    }

}
