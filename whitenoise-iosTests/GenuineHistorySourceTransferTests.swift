#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import XCTest

    @testable import whitenoise_ios

    private struct NativeSourceTransferFixture: Decodable {
        let version: Int
        let root: String
        let account: String
        let group: String
        let recipientCount: Int
        let expectedRecipient: String
        enum CodingKeys: String, CodingKey {
            case version, root, account, group
            case recipientCount = "recipient_count"
            case expectedRecipient = "expected_recipient"
        }
        static func read(_ path: String) throws -> Self {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            guard bytes.count <= 32768,
                try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber == 0o600
            else { throw CocoaError(.fileReadCorruptFile) }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            let root = URL(fileURLWithPath: value.root, isDirectory: true).resolvingSymlinksInPath()
            guard value.version == 2, value.recipientCount == 2, value.account.count == 64,
                value.expectedRecipient.count == 64,
                value.expectedRecipient.allSatisfy({ "0123456789abcdef".contains($0) }),
                !value.group.isEmpty, value.group.utf8.count <= 512,
                root.path.hasPrefix("/Users/pj/project/build/native-"),
                try Data(contentsOf: root.appendingPathComponent(".native-acceptance"))
                    == Data("native-sdk83-test-only-v1\n".utf8)
            else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
    }

    @MainActor final class GenuineHistorySourceTransferTests: XCTestCase {
        func testCompleteFreshSourceOriginalThroughAppStateAndNativeRecipient() async throws {
            guard let path = ProcessInfo.processInfo.environment["WN_IOS_SOURCE_TRANSFER_BRIDGE"] else {
                throw XCTSkip("Requires a live native recipient and positively closed simulator source handoff")
            }
            let bridge = URL(fileURLWithPath: path, isDirectory: true)
            let descriptor = bridge.appendingPathComponent("fixture.json")
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            while !FileManager.default.fileExists(atPath: descriptor.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(atPath: bridge.path)[.posixPermissions] as? NSNumber,
                NSNumber(value: 0o700))
            let fixture = try NativeSourceTransferFixture.read(descriptor.path)
            let root = URL(fileURLWithPath: fixture.root, isDirectory: true)
            let client = try MarmotClient(
                rootPath: root.appendingPathComponent("runtime", isDirectory: true).path,
                relayUrls: ["ws://127.0.0.1:18181"], cursorPersistence: .advance,
                telemetryConfig: .current(), secretStore: try ImportedHistoryReadOnlyStore(root: root),
                relayPolicy: .allowLoopback)
            let defaultsName = "GenuineHistorySourceTransfer-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let app = AppState.test(client: client, accountDefaults: defaults)
            do {
                app.setAppSceneActive(true)
                await app.bootstrap()
                XCTAssertTrue(app.activeAccountRef == fixture.account)
                let model = try await app.makeHistorySourcePickerModel(groupIdHex: fixture.group)
                try await model.loadRecipients()
                XCTAssertEqual(model.recipients.count, fixture.recipientCount)
                XCTAssertNil(model.selectedDevice)
                XCTAssertFalse(model.hasOriginal)
                try write(["ready": true], name: "ready.json", bridge: bridge)
                let chosen = try XCTUnwrap(
                    model.recipients.first { Self.hex($0.device) == fixture.expectedRecipient })
                // Explicit model actions use the actual observed choice and fresh original SDK factory.
                try model.select(device: chosen.device)
                try await model.begin()
                let displayed = try XCTUnwrap(model.review)
                XCTAssertTrue(model.hasOriginal)
                XCTAssertTrue(displayed.groupIdHex == fixture.group && displayed.recipientDevice == chosen.device)
                XCTAssertGreaterThan(displayed.recordCount, 0)
                XCTAssertFalse(displayed.complete)
                try write(
                    [
                        "group": displayed.groupIdHex, "source": Self.hex(displayed.sourceDevice),
                        "recipient": Self.hex(displayed.recipientDevice), "records": displayed.recordCount,
                        "encoded_bytes": displayed.encodedBytes, "fragments": displayed.fragmentCount,
                        "ceiling": displayed.snapshotTimestampCeiling, "revision": displayed.revision,
                        "complete": displayed.complete, "explicit_action": true,
                    ], name: "requested.json", bridge: bridge)
                let approvedFile = bridge.appendingPathComponent("recipient-approved.json")
                let approvalDeadline = ContinuousClock.now.advanced(by: .seconds(30))
                while !FileManager.default.fileExists(atPath: approvedFile.path), ContinuousClock.now < approvalDeadline
                {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let approved = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: approvedFile))
                XCTAssertEqual(approved, ["approved": true])
                let held = try await app.makeHistorySourcePickerModel(groupIdHex: fixture.group)
                XCTAssertTrue(held === model)
                try await held.refresh()
                let currentDisplayed = try XCTUnwrap(held.review)
                XCTAssertTrue(currentDisplayed.groupIdHex == displayed.groupIdHex)
                XCTAssertTrue(currentDisplayed.sourceDevice == displayed.sourceDevice)
                XCTAssertTrue(currentDisplayed.recipientDevice == displayed.recipientDevice)
                XCTAssertEqual(currentDisplayed.recordCount, displayed.recordCount)
                XCTAssertEqual(currentDisplayed.encodedBytes, displayed.encodedBytes)
                XCTAssertEqual(currentDisplayed.fragmentCount, displayed.fragmentCount)
                XCTAssertEqual(currentDisplayed.snapshotTimestampCeiling, displayed.snapshotTimestampCeiling)
                try await held.continueTransfer(displayedRevision: currentDisplayed.revision)
                let completeDeadline = ContinuousClock.now.advanced(by: .seconds(30))
                while held.review?.complete != true, ContinuousClock.now < completeDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                    try await held.refresh()
                }
                let completed = try XCTUnwrap(held.review)
                XCTAssertTrue(completed.complete)
                XCTAssertTrue(held.hasOriginal)
                app.releaseHistorySourcePickerModel(held)
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                XCTAssertFalse(held.isActive)
                XCTAssertFalse(held.hasOriginal)
                XCTAssertNil(app.client)
                let storageClosed = client.marmot.storageIsClosed()
                XCTAssertTrue(storageClosed)
                try write(
                    [
                        "source_complete": completed.complete, "original_retired": !held.hasOriginal && !held.isActive,
                        "runtime_closed": storageClosed && app.client == nil,
                    ],
                    name: "completed.json", bridge: bridge)
            } catch {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                XCTAssertNil(app.client)
                let storageClosed = client.marmot.storageIsClosed()
                XCTAssertTrue(storageClosed)
                try write(["failed": true], name: "failed.json", bridge: bridge)
                throw error
            }
        }

        private static func hex(_ bytes: Data) -> String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        private func write(_ value: [String: Any], name: String, bridge: URL) throws {
            let target = bridge.appendingPathComponent(name)
            let pending = bridge.appendingPathComponent(name + ".pending")
            try JSONSerialization.data(withJSONObject: value).write(to: pending, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
            try FileManager.default.linkItem(at: pending, to: target)
            try FileManager.default.removeItem(at: pending)
        }
    }
#endif
