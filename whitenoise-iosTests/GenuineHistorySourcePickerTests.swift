import Foundation
import MarmotKit
import SwiftUI
import XCTest

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    private enum SourcePickerFixtureError: Error { case invalidFixture, deadline }
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
            guard value.version == 1, try HostedNativeFixtureRoot.accepts(root, prefix: "native-"),
                try Data(contentsOf: root.appendingPathComponent(".native-acceptance"))
                    == Data("native-sdk83-test-only-v1\n".utf8),
                value.recipientCount == 2, value.account.utf8.count == 64,
                !value.group.isEmpty, value.group.utf8.count <= 512
            else { throw SourcePickerFixtureError.invalidFixture }
            return value
        }
    }

    @MainActor private final class GenuineSourcePickerGraph {}
    private struct GenuineSourcePickerRoot: View {
        let model: HistorySourcePickerModel
        let graph: GenuineSourcePickerGraph
        var body: some View { HistorySourcePickerView(model: model).id(ObjectIdentifier(graph)) }
    }

    /// Reopens a positively closed task-only peer; the descriptor carries observations, never an action.
    @MainActor final class GenuineHistorySourcePickerTests: XCTestCase {
        func testHostedNativeChoiceRequestAndCancelThroughPublicDriver() async throws {
            guard let path = ProcessInfo.processInfo.environment["WN_HISTORY_SOURCE_PICKER_FIXTURE"],
                let bridgePath = ProcessInfo.processInfo.environment["WN_HISTORY_SOURCE_UI_BRIDGE"]
            else { throw XCTSkip("Requires a fresh closed native source and external public UI driver") }
            let fixture = try SourcePickerFixture.read(path)
            let bridge = URL(fileURLWithPath: bridgePath, isDirectory: true)
            let root = URL(fileURLWithPath: fixture.root, isDirectory: true)
            let callback = try ImportedHistoryReadOnlyStore(root: root)
            let client = try MarmotClient(
                rootPath: root.appendingPathComponent("runtime", isDirectory: true).path,
                relayUrls: ["ws://127.0.0.1:18181"], cursorPersistence: .advance,
                telemetryConfig: .current(), secretStore: callback, relayPolicy: .allowLoopback)
            let defaultsName = "GenuineHistorySourceUI-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let app = AppState.test(client: client, accountDefaults: defaults)
            do {
                app.setAppSceneActive(true)
                await app.bootstrap()
                XCTAssertTrue(app.activeAccountRef == fixture.account)
                let model = try await app.makeHistorySourcePickerModel(groupIdHex: fixture.group)
                try await exercisePublicActions(model, fixture: fixture, bridge: bridge)
                XCTAssertFalse(model.isActive)
                XCTAssertFalse(model.hasOriginal)
                XCTAssertNil(model.review)
                app.releaseHistorySourcePickerModel(model)
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                XCTAssertNil(app.client)
                try observe(
                    ["public_actions": true, "original_cancelled": true, "runtime_closed": true],
                    named: "completed.json", bridge: bridge)
            } catch {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                try observe(["failed": true], named: "failed.json", bridge: bridge)
                throw error
            }
        }

        private func exercisePublicActions(
            _ model: HistorySourcePickerModel, fixture: SourcePickerFixture, bridge: URL
        ) async throws {
            var graph: GenuineSourcePickerGraph? = .init()
            weak let retiredGraph = graph
            var host: UIHostingController<AnyView>? = UIHostingController(
                rootView: AnyView(GenuineSourcePickerRoot(model: model, graph: try XCTUnwrap(graph))))
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
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                while model.recipients.isEmpty || model.isWorking {
                    guard ContinuousClock.now < deadline else { throw SourcePickerFixtureError.deadline }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertEqual(model.recipients.count, fixture.recipientCount)
                XCTAssertNil(model.selectedDevice)
                XCTAssertFalse(model.hasOriginal)
                host?.view.layoutIfNeeded()
                try observe(["native_choices_ready": true], named: "ui-ready.json", bridge: bridge)
                while model.review == nil || model.isWorking {
                    guard ContinuousClock.now < deadline else { throw SourcePickerFixtureError.deadline }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let review = try XCTUnwrap(model.review)
                XCTAssertTrue(model.hasOriginal)
                XCTAssertTrue(review.groupIdHex == fixture.group && review.recipientDevice == model.selectedDevice)
                XCTAssertTrue(model.recipients.contains { $0.device == review.recipientDevice })
                XCTAssertEqual(review.sourceDevice.count, 32)
                XCTAssertGreaterThan(review.recordCount, 0)
                XCTAssertFalse(review.complete)
                host?.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "genuine-source-review-after-public-request"
                attachment.lifetime = .keepAlways
                add(attachment)
                try observe(["native_original_reviewed": true], named: "reviewed.json", bridge: bridge)
                while model.isActive {
                    guard ContinuousClock.now < deadline else { throw SourcePickerFixtureError.deadline }
                    try await Task.sleep(for: .milliseconds(20))
                }
            } catch { failure = error }
            model.cancel()
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
        private func observe(_ value: [String: Bool], named: String, bridge: URL) throws {
            let target = bridge.appendingPathComponent(named)
            let temporary = bridge.appendingPathComponent(".observation-\(UUID())")
            try JSONSerialization.data(withJSONObject: value).write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try FileManager.default.moveItem(at: temporary, to: target)
        }

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
