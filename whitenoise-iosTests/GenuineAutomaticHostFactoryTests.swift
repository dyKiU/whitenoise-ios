// Real SDK-backed automatic factory and ownership acceptance.
#if WN_EXPERIMENTAL_DEVICE_SYNC
import Foundation
import MarmotKit
import Synchronization
import XCTest
#if os(macOS)
@testable import whitenoise_mac
private typealias FactoryOwner = DeviceLinkingScope
#else
@testable import whitenoise_ios
private typealias FactoryOwner = DeviceLinkingAccountScope
#endif

private enum FactoryFailure: Error { case unavailable, deadline, invariant, secretMissing }

// Same memory-only SecretStore pattern as NativePairingQRCodeTests. No system keychain or fixture credential writes.
nonisolated private final class FactorySecrets: SecretStore, Sendable {
    private struct State { var values: [String: String] = [:]; var labels: Set<String> = [] }
    private let state = Mutex(State())
    func hasSecretForLabel(label: String) throws -> Bool { state.withLock { $0.labels.contains(label) } }
    func hasSecretForAccountId(accountIdHex: String) throws -> Bool { state.withLock { $0.values[accountIdHex] != nil } }
    func writeSecret(label: String, accountIdHex: String, secretKeyHex: String) throws {
        state.withLock { $0.values[accountIdHex] = secretKeyHex; $0.labels.insert(label) }
    }
    func loadSecret(label: String, accountIdHex: String) throws -> String {
        try state.withLock {
            guard let value = $0.values[accountIdHex] else { throw FactoryFailure.secretMissing }
            return value
        }
    }
    func removeSecret(label: String, accountIdHex: String) throws {
        state.withLock { $0.values.removeValue(forKey: accountIdHex); $0.labels.remove(label) }
    }
}

@MainActor private final class FactoryHost {
    let client: MarmotClient
    let secrets: FactorySecrets
    var account: AccountSummaryFfi?
    private var closed = false
    #if os(macOS)
    let state = SessionState()
    #else
    let state: AppState
    private let defaults: UserDefaults
    private let defaultsName: String
    #endif
    var owner: FactoryOwner? {
        #if os(macOS)
        state.deviceLinkingScope
        #else
        state.accountStore.deviceLinkingScope
        #endif
    }
    init(root: URL) throws {
        let memory = FactorySecrets()
        secrets = memory
        #if os(macOS)
        client = try MarmotClient(rootPath: root.path, relayUrls: [Self.relay],
            storageProfile: .testHost, secretStore: memory, relayPolicy: .allowLoopback)
        #else
        client = try MarmotClient(rootPath: root.path, relayUrls: [Self.relay],
            cursorPersistence: .advance, telemetryConfig: .current(), secretStore: memory, relayPolicy: .allowLoopback)
        defaultsName = "AutomaticHostFactory-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        state = AppState.test(client: client, accountDefaults: defaults)
        #endif
    }
    static let relay = "ws://127.0.0.1:18181"
    func start() async throws {
        #if os(macOS)
        try await client.marmot.start()
        #else
        state.setAppSceneActive(true)
        await state.bootstrap()
        #endif
    }
    func select(_ selected: AccountSummaryFfi) async throws {
        account = selected
        #if os(macOS)
        await state.activate(account: AccountItem(summary: selected), runtime: client, connectivityAvailable: true)
        #else
        try await state.refreshAccounts()
        await state.activateAccount(selected.label)
        guard state.activeAccountRef == selected.label else { throw FactoryFailure.invariant }
        #endif
    }
    func begin() async throws -> FactoryOwner {
        #if os(macOS)
        try await state.beginDeviceLinkingSession()
        #else
        try await state.beginOwnedDeviceLinkingSession()
        #endif
    }
    func scan(_ code: Data) async throws -> FactoryOwner {
        #if os(macOS)
        try await state.approveDeviceLinkingSession(request: code, target: nil)
        #else
        try await state.approveOwnedDeviceLinkingSession(request: code, target: nil)
        #endif
    }
    func cancel() async throws {
        #if os(macOS)
        try await state.cancelDeviceLinking()
        #else
        try await state.accountStore.cancelDeviceLinking(preservingConversationState: true)
        #endif
    }
    func adopt(_ factory: @escaping @MainActor (MarmotClient, String) async throws -> any DeviceLinkingSessionProtocol)
        async throws -> FactoryOwner {
        #if os(macOS)
        return try await state.adoptDeviceLinkingFactory { runtime, account in
            guard let real = runtime as? MarmotClient, real === self.client else { throw FactoryFailure.invariant }
            return try await factory(real, account)
        }
        #else
        return try await state.adoptDeviceLinkingFactory(factory)
        #endif
    }
    func close() async throws {
        if closed { return }
        // Retire original owners before touching the explicitly supplied credential callback.
        #if os(macOS)
        try await state.prepareForAccountExit()
        await state.deactivate()
        #else
        try await state.accountStore.cancelDeviceLinking(preservingConversationState: true)
        #endif
        // Enumerate actual SDK accounts; a refused removal throws before storage close or root deletion.
        for account in try client.marmot.listAccounts() {
            try secrets.removeSecret(label: account.label, accountIdHex: account.accountIdHex)
        }
        #if os(macOS)
        try await client.marmot.shutdownAndClose()
        #else
        state.setAppSceneActive(false)
        await state.startRuntimeSuspension().value
        guard state.client == nil else { throw FactoryFailure.invariant }
        defaults.removePersistentDomain(forName: defaultsName)
        #endif
        guard client.marmot.storageIsClosed(), owner == nil else { throw FactoryFailure.invariant }
        closed = true
    }
}

// Opening is permanent, so timeout/cancellation cannot strand a later real factory result.
@MainActor private final class FactoryReturnGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor final class GenuineAutomaticHostFactoryTests: XCTestCase {
    private func wait(_ ready: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !(try await ready()) {
            guard ContinuousClock.now < deadline else { throw FactoryFailure.deadline }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    private func fixture(_ body: @MainActor ([FactoryHost]) async throws -> Void) async throws {
        guard ProcessInfo.processInfo.environment["WN_AUTOMATIC_HOST_FACTORY_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires the separately selected real automatic host-factory relay gate")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutomaticHostFactory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var hosts: [FactoryHost] = []
        var failure: Error?
        do {
            for index in 0..<2 {
                let host = try FactoryHost(root: root.appendingPathComponent(String(index)))
                hosts.append(host)
                try await host.start()
            }
            let first = try await hosts[0].client.marmot.createIdentity(
                defaultRelays: [FactoryHost.relay], bootstrapRelays: [FactoryHost.relay], inboxRelays: [FactoryHost.relay])
            let secret = try hosts[0].secrets.loadSecret(label: first.label, accountIdHex: first.accountIdHex)
            try await onboard(hosts[1], secret: secret, expected: first.accountIdHex)
            try await hosts[0].select(first)
            let second = try XCTUnwrap(try hosts[1].client.marmot.listAccounts().only)
            guard first.accountIdHex == second.accountIdHex else { throw FactoryFailure.invariant }
            try await hosts[1].select(second)
            try await body(hosts)
        } catch { failure = error }
        // Every original host must close even when another close fails. Cleanup failures remain failures.
        for host in hosts {
            do { try await host.close() } catch { if failure == nil { failure = error } }
        }
        if failure != nil {
            XCTFail("Automatic host factory runtime or exact cleanup failed")
            return
        }
        try FileManager.default.removeItem(at: root)
    }
    private func onboard(_ host: FactoryHost, secret: String, expected: String) async throws {
        // Reuses the bounded real onboarding algorithm from NativePairingQRControls.onboard;
        // no forged roster, permission, verification, or account state.
        let runtime = host.client.marmot
        var value = try await runtime.beginOnboarding(nsec: secret,
            options: OnboardingOptionsFfi(defaultRelays: [FactoryHost.relay], discoveryRelays: [FactoryHost.relay], inboxRelays: [FactoryHost.relay]))
        for _ in 0..<32 {
            if value.ready { break }
            value = try await runtime.runOnboarding(accountRef: value.accountIdHex)
            if value.ready { break }
            guard let blocked = value.steps.first(where: { $0.status == .needsInput || $0.status == .retryableFailure }) else {
                try await Task.sleep(for: .milliseconds(100)); continue
            }
            if blocked.actions.contains(.continueWithout) {
                value = try await runtime.continueOnboardingWithout(accountRef: value.accountIdHex, step: blocked.step)
            } else if blocked.step == .singleDevice && blocked.actions.contains(.continueAnyway) {
                value = try await runtime.acknowledgeOnboardingSingleDevice(accountRef: value.accountIdHex, revision: value.revision)
            } else if blocked.step == .relays || blocked.step == .inboxRelays {
                let proposal = try await runtime.proposeOnboardingRelays(accountRef: value.accountIdHex,
                    step: blocked.step, readRelays: [FactoryHost.relay], writeRelays: [FactoryHost.relay])
                value = try await runtime.approveOnboardingRepair(accountRef: value.accountIdHex, revision: proposal.revision)
            } else { throw FactoryFailure.unavailable }
        }
        guard value.ready, value.accountIdHex == expected else { throw FactoryFailure.invariant }
    }
    private func paired(_ host: FactoryHost, group: String, text: String) async throws -> Bool {
        let account = try XCTUnwrap(host.account)
        let window = try await host.client.marmot.openAccountConversationWindow(
            accountRef: account.accountIdHex, groupIdHex: group, initialRows: 128)
        defer { window.cancel() }
        guard let value = window.snapshot() else { return false }
        guard case .pairedSource = value.header else { return false }
        return value.rows.contains { row in
            if case .pairedSource(let actual) = row { return actual.content == text && !actual.deleted }
            return false
        }
    }
    private func hasPairedChat(_ host: FactoryHost, group: String) async throws -> Bool {
        let account = try XCTUnwrap(host.account)
        let window = try await host.client.marmot.openAccountChatListWindow(accountRef: account.accountIdHex, initialRows: 128)
        defer { window.cancel() }
        guard let snapshot = window.snapshot() else { return false }
        return snapshot.rows.contains { if case .pairedSource(let row) = $0 { return row.groupIdHex == group }; return false }
    }
    private func pair(_ hosts: [FactoryHost], reverse: Bool) async throws {
        var groups: [String] = []
        let texts = ["Synthetic prior history A", "Synthetic prior history B"]
        for (index, host) in hosts.enumerated() {
            let account = try XCTUnwrap(host.account)
            let group = try await host.client.marmot.createGroup(
                accountRef: account.accountIdHex, name: "Synthetic prior chat", memberRefs: [], description: nil)
            groups.append(group)
            _ = try await host.client.marmot.sendTextWithClientToken(accountRef: account.accountIdHex,
                groupIdHex: group, text: texts[index], clientToken: "host-factory-prior-\(index)")
            try await wait {
                guard let status = try host.client.marmot.localSendStatus(accountRef: account.accountIdHex,
                    groupIdHex: group, clientToken: "host-factory-prior-\(index)") else { return false }
                if case .completed(let receipt) = status { return !receipt.messageIds.isEmpty }
                return false
            }
        }
        for index in 0..<2 {
            let alreadyShared = try await hasPairedChat(hosts[index], group: groups[1 - index])
            XCTAssertFalse(alreadyShared)
        }
        let display = hosts[reverse ? 1 : 0]
        let scanner = hosts[reverse ? 0 : 1]
        let left = try await display.begin()
        let code = try left.setupPacket()
        // Actual app QR decoder remains in the app scan flow; the owner receives its exact decoded bytes.
        guard String(data: code, encoding: .utf8)?.hasPrefix("WNPAIR1:") == true else { throw FactoryFailure.invariant }
        let right = try await scanner.scan(code)
        try await wait { left.latestSnapshot?.phase == .comparisonAvailable && right.latestSnapshot?.phase == .comparisonAvailable }
        let a = try XCTUnwrap(left.latestSnapshot)
        let b = try XCTUnwrap(right.latestSnapshot)
        let ac = try XCTUnwrap(a.decimals)
        let bc = try XCTUnwrap(b.decimals)
        XCTAssertEqual(ac.first, bc.first); XCTAssertEqual(ac.second, bc.second); XCTAssertEqual(ac.third, bc.third)
        guard ac.first == bc.first, ac.second == bc.second, ac.third == bc.third else {
            throw FactoryFailure.invariant
        }
        try await left.confirmComparison(displayedRevision: a.revision)
        // One-sided comparison must not grant enrollment or chat sharing.
        XCTAssertNotEqual(right.latestSnapshot?.phase, .enrollmentComplete)
        try await right.confirmComparison(displayedRevision: b.revision)
        try await wait { left.latestSnapshot?.phase == .verificationCompleteEnrollmentPending && right.latestSnapshot?.phase == .verificationCompleteEnrollmentPending }
        try await left.continueLinkingAndShareChats(displayedRevision: try XCTUnwrap(left.latestSnapshot).revision)
        for index in 0..<2 {
            let alreadyShared = try await hasPairedChat(hosts[index], group: groups[1 - index])
            XCTAssertFalse(alreadyShared)
        }
        try await right.continueLinkingAndShareChats(displayedRevision: try XCTUnwrap(right.latestSnapshot).revision)
        try await wait { left.latestSnapshot?.phase == .enrollmentComplete && right.latestSnapshot?.phase == .enrollmentComplete }
        for index in 0..<2 {
            try await wait {
                let found = try await self.hasPairedChat(hosts[index], group: groups[1 - index])
                guard found else { return false }
                return try await self.paired(hosts[index], group: groups[1 - index], text: texts[1 - index])
            }
        }
        try await display.cancel(); try await scanner.cancel()
        XCTAssertNil(display.owner); XCTAssertNil(scanner.owner)
        XCTAssertNil(left.latestSnapshot); XCTAssertNil(right.latestSnapshot)
    }
    func testForwardFactoriesShareBothPreviouslyAbsentChats() async throws { try await fixture { try await self.pair($0, reverse: false) } }
    func testReverseFactoriesShareBothPreviouslyAbsentChats() async throws { try await fixture { try await self.pair($0, reverse: true) } }

    private func retired(_ owner: FactoryOwner) async throws {
        XCTAssertNil(owner.latestSnapshot)
        do { _ = try owner.setupPacket(); XCTFail("Retired factory owner exported bootstrap") }
        catch is CancellationError { }
        catch MarmotKitError.DeviceLinkingClosed { }
        // cancel is idempotent on this exact original; no replacement object or inferred handle.
        try await owner.cancel()
        XCTAssertNil(owner.cleanupError)
    }
    func testActualFactoryCancellationRetiresOriginal() async throws {
        try await fixture { hosts in
            let original = try await hosts[0].begin()
            XCTAssertFalse(try original.setupPacket().isEmpty)
            try await hosts[0].cancel()
            XCTAssertNil(hosts[0].owner)
            try await self.retired(original)
        }
    }
    func testActualFactoryPlatformShutdownClosesStorageAndRetiresOriginal() async throws {
        try await fixture { hosts in
            let original = try await hosts[0].begin()
            try await hosts[0].close()
            XCTAssertTrue(hosts[0].client.marmot.storageIsClosed())
            try await self.retired(original)
        }
    }
    private func lateFactory(_ hosts: [FactoryHost], scan: Bool) async throws {
        let host = hosts[scan ? 1 : 0]
        let code = scan ? try await hosts[0].begin().setupPacket() : Data()
        var captured: (any DeviceLinkingSessionProtocol)?
        let gate = FactoryReturnGate()
        var finished = false
        var rejected = false
        let pending = Task { @MainActor in
            defer { finished = true }
            do {
                _ = try await host.adopt { real, account in
                    let original = scan
                        ? try await real.approveDeviceLinkingSession(accountRef: account, request: code, target: nil)
                        : try await real.beginDeviceLinkingSession(accountRef: account)
                    captured = original
                    // Hold only the return of an actual SDK original at the existing app adoption seam.
                    // No fabricated transport, permission, snapshot or enrollment is introduced.
                    await gate.wait()
                    return original
                }
            } catch is CancellationError { rejected = true }
            catch { rejected = false }
        }
        var failure: Error?
        do {
            try await wait { captured != nil && gate.waiting }
            let account = try await host.client.marmot.createIdentity(defaultRelays: [FactoryHost.relay],
                bootstrapRelays: [FactoryHost.relay], inboxRelays: [FactoryHost.relay])
            try await host.select(account)
            gate.open()
            try await wait { finished }
            XCTAssertTrue(rejected)
            XCTAssertNil(host.owner)
            guard let original = captured else { throw FactoryFailure.invariant }
            do { _ = try await original.automaticPairingCode(); XCTFail("Retired SDK original exported bootstrap") }
            catch MarmotKitError.DeviceLinkingClosed { }
            if let other = hosts[0].owner { try await hosts[0].cancel(); try await self.retired(other) }
        } catch { failure = error }
        // This join runs on every exit after task creation, including identity/select/wait failures.
        gate.open()
        pending.cancel()
        await pending.value
        if let failure { throw failure }

    }
    func testLateBeginFactoryCannotAdoptAcrossAccountReplacement() async throws { try await fixture { try await self.lateFactory($0, scan: false) } }
    func testLateScanFactoryCannotAdoptAcrossAccountReplacement() async throws { try await fixture { try await self.lateFactory($0, scan: true) } }
}
private extension Array { var only: Element? { count == 1 ? first : nil } }
#endif
