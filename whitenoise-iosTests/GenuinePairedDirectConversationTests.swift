#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Darwin
    import Foundation
    import MarmotKit
    import XCTest

    @testable import whitenoise_ios

    private enum PairedDirectFixtureError: Error { case invalidFixture }
    private struct PairedDirectFixture: Decodable {
        let version: Int
        let root: String
        let account: String
        let peer: String
        let group: String
        let bridge: String
    }

    @MainActor final class GenuinePairedDirectConversationTests: XCTestCase {
        func testRealMarmotClientReusesPairedSourceWithoutLocalMembershipOrInvitation() async throws {
            continueAfterFailure = false
            guard let path = ProcessInfo.processInfo.environment["WN_PAIRED_DIRECT_FIXTURE"] else {
                throw XCTSkip("Requires a positively closed genuine paired direct-conversation recipient")
            }
            let descriptor = URL(fileURLWithPath: path)
            let descriptorAttributes = try FileManager.default.attributesOfItem(atPath: descriptor.path)
            let bytes = try Data(contentsOf: descriptor)
            guard descriptor.standardizedFileURL == descriptor.resolvingSymlinksInPath(),
                descriptorAttributes[.type] as? FileAttributeType == .typeRegular,
                (descriptorAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                (descriptorAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                bytes.count <= 4096
            else { throw PairedDirectFixtureError.invalidFixture }
            let fixture = try JSONDecoder().decode(PairedDirectFixture.self, from: bytes)
            let root = URL(fileURLWithPath: fixture.root, isDirectory: true)
            let bridge = URL(fileURLWithPath: fixture.bridge, isDirectory: true)
            let attributes = try FileManager.default.attributesOfItem(atPath: bridge.path)
            guard fixture.version == 1, root == root.resolvingSymlinksInPath(),
                try HostedNativeFixtureRoot.accepts(root, prefix: "native-"),
                bridge == root.deletingLastPathComponent().appendingPathComponent("private-bridge", isDirectory: true),
                bridge == bridge.resolvingSymlinksInPath(),
                (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                fixture.account.utf8.count == 64, fixture.peer.utf8.count == 64,
                fixture.account != fixture.peer, !fixture.group.isEmpty, fixture.group.utf8.count <= 512
            else { throw PairedDirectFixtureError.invalidFixture }
            let client = try MarmotClient(
                rootPath: root.appendingPathComponent("runtime", isDirectory: true).path,
                relayUrls: ["ws://127.0.0.1:18181"], cursorPersistence: .advance,
                telemetryConfig: .current(), secretStore: try ImportedHistoryReadOnlyStore(root: root),
                relayPolicy: .allowLoopback)
            do {
                let accounts = try await client.listAccounts()
                XCTAssertEqual(accounts.count, 1)
                let account = try XCTUnwrap(accounts.first)
                XCTAssertEqual(account.accountIdHex, fixture.account)
                try await client.startRuntime()
                let localBefore = try await client.marmot.existingDirectConversation(
                    accountRef: account.label, peerAccountId: fixture.peer)
                XCTAssertNil(localBefore, "The paired recipient must have no local direct-chat membership")
                let nativeValue = try await client.marmot.existingAccountDirectConversation(
                    accountRef: account.label, peerAccountId: fixture.peer)
                let native = try XCTUnwrap(nativeValue)
                guard case .pairedSource(let source) = native else {
                    throw PairedDirectFixtureError.invalidFixture
                }
                XCTAssertEqual(source.groupIdHex, fixture.group)
                let before = try await client.chatList(accountRef: account.label, includeArchived: true)
                XCTAssertTrue(before.isEmpty, "No ordinary chat is present in this source-only recipient")
                for _ in 0..<3 {
                    let found = try await client.existingDirectConversation(
                        accountRef: account.label, peerAccountId: fixture.peer)
                    guard let destination = found, case .pairedSource(let observed) = destination else {
                        try await client.marmot.shutdownAndClose()
                        try writeObservation(["runtime_closed": true], named: "paired-direct-closed.json", bridge: bridge)
                        XCTFail("paired-direct-adapter-destination")
                        return
                    }
                    XCTAssertEqual(observed, source)
                    XCTAssertEqual(destination.groupIdHex, fixture.group)
                    XCTAssertTrue(destination.reusable)
                    XCTAssertTrue(destination.isPaired)
                }
                let after = try await client.chatList(accountRef: account.label, includeArchived: true)
                XCTAssertTrue(after.isEmpty, "Direct lookup must not create another ordinary conversation")
                let localAfter = try await client.marmot.existingDirectConversation(
                    accountRef: account.label, peerAccountId: fixture.peer)
                XCTAssertNil(localAfter, "Direct lookup must not claim local MLS membership")
                try await client.marmot.shutdownAndClose()
                try writeObservation(["runtime_closed": true], named: "paired-direct-closed.json", bridge: bridge)
                try writeObservation([
                    "paired_destination": true, "same_group": true, "lookup_count": 3,
                    "no_local_membership": true, "no_new_ordinary_chat": true, "runtime_closed": true,
                ], named: "paired-direct-complete.json", bridge: bridge)
            } catch {
                try await client.marmot.shutdownAndClose()
                try writeObservation(["runtime_closed": true], named: "paired-direct-closed.json", bridge: bridge)
                throw error
            }
        }

        private func writeObservation(_ value: [String: Any], named name: String, bridge: URL) throws {
            let output = bridge.appendingPathComponent(name)
            let descriptor = open(output.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw PairedDirectFixtureError.invalidFixture }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: value))
            try handle.close()
        }
    }
#endif
