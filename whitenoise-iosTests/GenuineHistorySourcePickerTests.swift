import Foundation
import MarmotKit
import XCTest

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    private enum SourcePickerFixtureError: Error { case invalidFixture }
    private struct SourcePickerFixture: Decodable {
        let version: Int
        let root: String
        let account: String
        let group: String
        let recipientCount: Int
        enum CodingKeys: String, CodingKey {
            case version, root, account, group
            case recipientCount = "recipient_count"
        }
        static func read(_ path: String) throws -> Self {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            guard bytes.count <= 4096,
                try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber == 0o600
            else { throw SourcePickerFixtureError.invalidFixture }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            let root = URL(fileURLWithPath: value.root, isDirectory: true).resolvingSymlinksInPath()
            guard value.version == 1, root.path.hasPrefix("/Users/pj/project/build/native-"),
                try Data(contentsOf: root.appendingPathComponent(".native-acceptance"))
                    == Data("native-sdk83-test-only-v1\n".utf8),
                value.recipientCount == 2, value.account.utf8.count == 64,
                !value.group.isEmpty, value.group.utf8.count <= 512
            else { throw SourcePickerFixtureError.invalidFixture }
            return value
        }
    }

    /// Reopens a positively closed task-only peer; the descriptor carries observations, never an action.
    @MainActor final class GenuineHistorySourcePickerTests: XCTestCase {
        func testActualNativeChoicesCreateRefreshAndCancelOriginalThroughAccountOwner() async throws {
            guard let path = ProcessInfo.processInfo.environment["WN_HISTORY_SOURCE_PICKER_FIXTURE"] else {
                throw XCTSkip("Requires a fresh positively closed native source fixture")
            }
            let fixture = try SourcePickerFixture.read(path)
            let root = URL(fileURLWithPath: fixture.root, isDirectory: true)
            let callback = try ImportedHistoryReadOnlyStore(root: root)
            let client = try MarmotClient(
                rootPath: root.appendingPathComponent("runtime", isDirectory: true).path,
                relayUrls: ["ws://127.0.0.1:18181"], cursorPersistence: .advance,
                telemetryConfig: .current(), secretStore: callback, relayPolicy: .allowLoopback)
            let defaultsName = "GenuineHistorySource-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let app = AppState.test(client: client, accountDefaults: defaults)
            do {
                let accounts = try await client.listAccounts()
                XCTAssertEqual(accounts.count, 1)
                XCTAssertTrue(accounts.first?.accountIdHex == fixture.account)
                app.setAppSceneActive(true)
                await app.bootstrap()
                XCTAssertTrue(app.activeAccountRef == fixture.account)
                let model = try await app.makeHistorySourcePickerModel(groupIdHex: fixture.group)
                XCTAssertTrue(model.isActive)
                XCTAssertFalse(model.hasOriginal)
                try await model.loadRecipients()
                XCTAssertEqual(model.recipients.count, fixture.recipientCount)
                XCTAssertNil(model.selectedDevice)
                XCTAssertNil(model.review)
                let selected = try XCTUnwrap(model.recipients.first).device
                try model.select(device: selected)
                try await model.begin()
                let first = try XCTUnwrap(model.review)
                XCTAssertTrue(model.hasOriginal)
                XCTAssertTrue(first.groupIdHex == fixture.group && first.recipientDevice == selected)
                XCTAssertEqual(first.sourceDevice.count, 32)
                XCTAssertTrue(first.sourceDevice != first.recipientDevice)
                XCTAssertGreaterThan(first.recordCount, 0)
                XCTAssertGreaterThan(first.encodedBytes, 0)
                XCTAssertFalse(first.complete)
                let held = try await app.makeHistorySourcePickerModel(groupIdHex: fixture.group)
                XCTAssertTrue(held === model)
                try await held.refresh()
                let refreshed = try XCTUnwrap(held.review)
                XCTAssertTrue(
                    refreshed.groupIdHex == first.groupIdHex && refreshed.sourceDevice == first.sourceDevice
                        && refreshed.recipientDevice == first.recipientDevice
                        && refreshed.snapshotTimestampCeiling == first.snapshotTimestampCeiling
                        && refreshed.recordCount == first.recordCount && refreshed.encodedBytes == first.encodedBytes
                        && refreshed.fragmentCount == first.fragmentCount)
                held.cancel()
                XCTAssertFalse(model.isActive)
                XCTAssertFalse(model.hasOriginal)
                XCTAssertNil(model.review)
                app.releaseHistorySourcePickerModel(model)
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                XCTAssertNil(app.client)
            } catch {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                throw error
            }
        }
    }
#endif
