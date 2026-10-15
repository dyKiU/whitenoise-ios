import Foundation
import MarmotKit
import Synchronization
import XCTest

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
  private enum NativeSwitchFailure: Error { case invalidRoot, deadline, unexpectedWrite }

  /// Existing encrypted task credentials stay read-only. Only fresh SDK-created accounts enter memory.
  nonisolated private final class NativeSwitchSecretStore: SecretStore, Sendable {
    private struct State {
      var secrets: [String: String] = [:]
      var labels: Set<String> = []
    }
    private let state = Mutex(State())
    private let original: ImportedHistoryReadOnlyStore
    init(root: URL) throws { original = try ImportedHistoryReadOnlyStore(root: root) }
    func hasSecretForLabel(label: String) throws -> Bool {
      try state.withLock { $0.labels.contains(label) } || original.hasSecretForLabel(label: label)
    }
    func hasSecretForAccountId(accountIdHex: String) throws -> Bool {
      try state.withLock { $0.secrets[accountIdHex] != nil }
        || original.hasSecretForAccountId(accountIdHex: accountIdHex)
    }
    func loadSecret(label: String, accountIdHex: String) throws -> String {
      if let value = state.withLock({ $0.secrets[accountIdHex] }) { return value }
      return try original.loadSecret(label: label, accountIdHex: accountIdHex)
    }
    func writeSecret(label: String, accountIdHex: String, secretKeyHex: String) throws {
      guard try !original.hasSecretForAccountId(accountIdHex: accountIdHex) else {
        throw NativeSwitchFailure.unexpectedWrite
      }
      state.withLock {
        $0.secrets[accountIdHex] = secretKeyHex
        $0.labels.insert(label)
      }
    }
    func removeSecret(label: String, accountIdHex: String) throws {
      guard try !original.hasSecretForAccountId(accountIdHex: accountIdHex) else {
        throw NativeSwitchFailure.unexpectedWrite
      }
      state.withLock {
        $0.secrets.removeValue(forKey: accountIdHex)
        $0.labels.remove(label)
      }
    }
  }

  @MainActor final class GenuineAutomaticAccountSwitchTests: XCTestCase {
    private func taskRoot() throws -> URL {
      guard let path = ProcessInfo.processInfo.environment["WN_AUTOMATIC_SWITCH_ROOT"] else {
        throw XCTSkip("Requires a fresh positively closed synthetic paired native root")
      }
      let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
      guard root.path.hasPrefix("/Users/pj/project/build/automatic-host-switch-"),
        try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
          == 0o700,
        try Data(contentsOf: root.appendingPathComponent(".native-acceptance"))
          == Data("native-sdk83-test-only-v1\n".utf8)
      else { throw NativeSwitchFailure.invalidRoot }
      return root
    }
    private func eventually(_ predicate: @MainActor () -> Bool) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(30))
      while !predicate() {
        guard ContinuousClock.now < deadline else { throw NativeSwitchFailure.deadline }
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    private func refusesSend(_ model: AccountConversationViewModel) async {
      do {
        _ = try await model.sendText("isolated retired owner must refuse")
        XCTFail("Retired owner admitted a send")
      } catch {
        XCTAssertTrue((error as? AutomaticChatPresentationError) == .retired)
      }
      XCTAssertTrue(model.pendingTexts.isEmpty)
      XCTAssertNil(model.snapshot)
      XCTAssertTrue(model.pairedMessages.isEmpty)
    }

    func testActualAccountsReplacePairedOwnersAndSceneSuspensionClosesRuntime() async throws {
      let root = try taskRoot()
      let client = try MarmotClient(
        rootPath: root.appendingPathComponent("runtime").path,
        relayUrls: ["ws://127.0.0.1:18181"], cursorPersistence: .advance,
        telemetryConfig: .current(), secretStore: try NativeSwitchSecretStore(root: root),
        relayPolicy: .allowLoopback)
      let defaultsName = "GenuineAutomaticSwitch-\(UUID())"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
      defer { defaults.removePersistentDomain(forName: defaultsName) }
      let app = AppState.test(client: client, accountDefaults: defaults)
      do {
        app.setAppSceneActive(true)
        await app.bootstrap()
        let initialAccounts = try await client.listAccounts()
        XCTAssertEqual(initialAccounts.count, 1)
        let firstAccount = try XCTUnwrap(initialAccounts.first)
        XCTAssertEqual(app.activeAccountRef, firstAccount.label)
        let secondAccount = try await client.marmot.createIdentity(
          defaultRelays: ["ws://127.0.0.1:18181"],
          bootstrapRelays: ["ws://127.0.0.1:18181"], inboxRelays: ["ws://127.0.0.1:18181"])
        try await app.refreshAccounts()
        XCTAssertEqual(app.accounts.count, 2)
        XCTAssertNotEqual(firstAccount.accountIdHex, secondAccount.accountIdHex)
        let firstOwner = try app.makeAutomaticChatListModel()
        firstOwner.start()
        try await eventually { !firstOwner.pairedRows.isEmpty }
        let group = try XCTUnwrap(firstOwner.pairedRows.first).groupIdHex
        let firstConversation = try app.makeAutomaticConversationModel(groupIdHex: group)
        firstConversation.start()
        try await eventually { !firstConversation.pairedMessages.isEmpty }
        let observedEvent = try XCTUnwrap(firstConversation.pairedMessages.first).messageIdHex
        XCTAssertEqual(observedEvent.utf8.count, 64)
        await app.activateAccount(secondAccount.label)
        XCTAssertEqual(app.activeAccountRef, secondAccount.label)
        XCTAssertFalse(firstOwner.isCurrentOwner)
        XCTAssertNil(firstOwner.snapshot)
        XCTAssertTrue(firstOwner.pairedRows.isEmpty)
        XCTAssertFalse(firstConversation.isCurrentOwner)
        await refusesSend(firstConversation)
        let secondOwner = try app.makeAutomaticChatListModel()
        secondOwner.start()
        XCTAssertFalse(secondOwner === firstOwner)
        XCTAssertEqual(secondOwner.accountRef, secondAccount.label)
        try await eventually { secondOwner.snapshot != nil }
        XCTAssertTrue(secondOwner.pairedRows.isEmpty)
        let foreignConversation = try app.makeAutomaticConversationModel(groupIdHex: group)
        foreignConversation.start()
        try await eventually { !foreignConversation.isLoading }
        XCTAssertNil(foreignConversation.pairedHeader)
        await refusesSend(foreignConversation)
        await app.activateAccount(firstAccount.label)
        XCTAssertEqual(app.activeAccountRef, firstAccount.label)
        XCTAssertFalse(secondOwner.isCurrentOwner)
        XCTAssertNil(secondOwner.snapshot)
        let returnedOwner = try app.makeAutomaticChatListModel()
        returnedOwner.start()
        XCTAssertFalse(returnedOwner === firstOwner)
        try await eventually { returnedOwner.pairedRows.contains { $0.groupIdHex == group } }
        let returnedConversation = try app.makeAutomaticConversationModel(groupIdHex: group)
        returnedConversation.start()
        XCTAssertFalse(returnedConversation === firstConversation)
        try await eventually {
          returnedConversation.pairedMessages.contains { $0.messageIdHex == observedEvent }
        }
        await refusesSend(firstConversation)
        app.setAppSceneActive(false)
        XCTAssertFalse(returnedOwner.isCurrentOwner)
        XCTAssertThrowsError(try app.makeAutomaticChatListModel())
        await app.startRuntimeSuspension().value
        XCTAssertNil(app.client)
        XCTAssertTrue(client.marmot.storageIsClosed())
        XCTAssertNil(returnedOwner.snapshot)
        await refusesSend(returnedConversation)
      } catch {
        app.setAppSceneActive(false)
        await app.startRuntimeSuspension().value
        XCTAssertTrue(client.marmot.storageIsClosed())
        throw error
      }
    }
  }
#endif
