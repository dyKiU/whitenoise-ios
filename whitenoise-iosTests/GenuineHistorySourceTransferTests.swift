#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import SwiftUI
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
                try HostedNativeFixtureRoot.accepts(root, prefix: "native-"),
                try Data(contentsOf: root.appendingPathComponent(".native-acceptance"))
                    == Data("native-sdk83-test-only-v1\n".utf8)
            else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
    }

    private enum PublicSourceTransferError: Error { case deadline }
    @MainActor private final class PublicSourceTransferGraph {}
    private struct PublicSourceTransferRoot: View {
        let model: HistorySourcePickerModel
        let graph: PublicSourceTransferGraph
        var body: some View { HistorySourcePickerView(model: model).id(ObjectIdentifier(graph)) }
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

        func testHostedFreshSourceTransferThroughPublicButtons() async throws {
            guard let path = ProcessInfo.processInfo.environment["WN_IOS_SOURCE_TRANSFER_PUBLIC_BRIDGE"] else {
                throw XCTSkip("Requires a live native recipient and external public UI driver")
            }
            let bridge = URL(fileURLWithPath: path, isDirectory: true)
            let descriptor = bridge.appendingPathComponent("fixture.json")
            try await wait { FileManager.default.fileExists(atPath: descriptor.path) }
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
            let defaultsName = "GenuinePublicSourceTransfer-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let app = AppState.test(client: client, accountDefaults: defaults)
            do {
                app.setAppSceneActive(true)
                await app.bootstrap()
                XCTAssertTrue(app.activeAccountRef == fixture.account)
                let model = try await app.makeHistorySourcePickerModel(groupIdHex: fixture.group)
                try await observePublicTransfer(model, fixture: fixture, bridge: bridge)
                let complete = model.review?.complete == true
                XCTAssertTrue(complete)
                app.releaseHistorySourcePickerModel(model)
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                let closed = client.marmot.storageIsClosed() && app.client == nil
                XCTAssertTrue(closed)
                try write(
                    [
                        "source_complete": complete, "original_retired": !model.hasOriginal && !model.isActive,
                        "runtime_closed": closed,
                    ], name: "completed.json", bridge: bridge)
            } catch {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                XCTAssertTrue(client.marmot.storageIsClosed() && app.client == nil)
                try write(["failed": true], name: "failed.json", bridge: bridge)
                throw error
            }
        }

        private func observePublicTransfer(
            _ model: HistorySourcePickerModel, fixture: NativeSourceTransferFixture, bridge: URL
        ) async throws {
            var graph: PublicSourceTransferGraph? = .init()
            weak let retiredGraph = graph
            var host: UIHostingController<AnyView>? = UIHostingController(
                rootView: AnyView(PublicSourceTransferRoot(model: model, graph: try XCTUnwrap(graph))))
            graph = nil
            weak let retiredHost = host
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.keyWindow
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host
            window.makeKeyAndVisible()
            var failure: Error?
            do {
                // The view loads native choices; only the external UI driver performs actions.
                try await wait(seconds: 30) { !model.recipients.isEmpty && !model.isWorking }
                XCTAssertEqual(model.recipients.count, fixture.recipientCount)
                XCTAssertNil(model.selectedDevice)
                XCTAssertFalse(model.hasOriginal)
                let chosen = try XCTUnwrap(model.recipients.first { Self.hex($0.device) == fixture.expectedRecipient })
                try write(["ready": true], name: "ready.json", bridge: bridge)
                try write(
                    ["choice_identifier": "history-source.choice-\(chosen.leafIndex)"],
                    name: "ui-ready.json", bridge: bridge)
                try await wait(seconds: 30) { model.review != nil && !model.isWorking }
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
                    ],
                    name: "requested.json", bridge: bridge)
                try await wait(seconds: 30) { model.review?.revision != displayed.revision && !model.isWorking }
                let refreshed = try XCTUnwrap(model.review)
                XCTAssertTrue(refreshed.groupIdHex == displayed.groupIdHex)
                XCTAssertTrue(refreshed.sourceDevice == displayed.sourceDevice)
                XCTAssertTrue(refreshed.recipientDevice == displayed.recipientDevice)
                XCTAssertEqual(refreshed.recordCount, displayed.recordCount)
                XCTAssertEqual(refreshed.encodedBytes, displayed.encodedBytes)
                XCTAssertEqual(refreshed.fragmentCount, displayed.fragmentCount)
                XCTAssertEqual(refreshed.snapshotTimestampCeiling, displayed.snapshotTimestampCeiling)
                XCTAssertTrue(model.hasOriginal)
                try write(["refreshed": true], name: "refreshed.json", bridge: bridge)
                try await wait(seconds: 30) { model.review?.complete == true && !model.isWorking }
                XCTAssertTrue(model.hasOriginal)
                try write(["public_actions_complete": true], name: "ui-completed.json", bridge: bridge)
            } catch { failure = error }
            host?.rootView = AnyView(EmptyView())
            window.isHidden = true
            window.rootViewController = nil
            host = nil
            previous?.makeKey()
            let retirement = ContinuousClock.now.advanced(by: .seconds(10))
            while retiredHost != nil || retiredGraph != nil, ContinuousClock.now < retirement {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(retiredHost)
            XCTAssertNil(retiredGraph)
            withExtendedLifetime(model) {}
            if let failure { throw failure }
        }

        private func wait(seconds: Int = 120, until predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            while !predicate() {
                guard ContinuousClock.now < deadline else { throw PublicSourceTransferError.deadline }
                try await Task.sleep(for: .milliseconds(20))
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
