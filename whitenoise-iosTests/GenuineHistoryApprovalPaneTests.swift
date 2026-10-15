import CryptoKit
import Foundation
import MarmotKit
import SwiftUI
import XCTest

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    private enum GenuineApprovalError: Error { case invalidFixture, deadline }
    private struct GenuineApprovalFixture: Decodable {
        let version: Int
        let root: String
        let account: String
        let group: String
        let liveMessage: String
        let oldMessage: String
        let oldContent: String
        let oldTags: [[String]]
        let author: String
        enum CodingKeys: String, CodingKey {
            case version, root, account, group, author
            case liveMessage = "live_message"
            case oldMessage = "old_message"
            case oldContent = "old_content"
            case oldTags = "old_tags"
        }
    }
    @MainActor private final class GenuineApprovalGraph {}
    private struct GenuineApprovalRoot: View {
        let model: HistoryConsentReviewModel
        let graph: GenuineApprovalGraph
        var body: some View { HistoryConsentReviewView(model: model).id(ObjectIdentifier(graph)) }
    }

    @MainActor final class GenuineHistoryApprovalPaneTests: XCTestCase {
        func testHostedExplicitOriginalApprovalCommitsRealRelayImport() async throws {
            guard let path = ProcessInfo.processInfo.environment["WN_HISTORY_APPROVAL_BRIDGE"] else {
                throw XCTSkip("Requires a fresh live original recipient approval bridge")
            }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let fixture = try await readFixture(directory)
            let root = URL(fileURLWithPath: fixture.root, isDirectory: true).resolvingSymlinksInPath()
            guard try HostedNativeFixtureRoot.accepts(root, prefix: "native-"),
                try Data(contentsOf: root.appendingPathComponent(".native-acceptance"))
                    == Data("native-sdk83-test-only-v1\n".utf8), fixture.version == 2,
                fixture.oldContent.utf8.count == 8192
            else { throw GenuineApprovalError.invalidFixture }
            let callback = try ImportedHistoryReadOnlyStore(root: root)
            let client = try MarmotClient(
                rootPath: root.appendingPathComponent("runtime").path,
                relayUrls: ["ws://127.0.0.1:18181"], cursorPersistence: .advance,
                telemetryConfig: .current(), secretStore: callback, relayPolicy: .allowLoopback)
            let defaultsName = "GenuineHistoryApproval-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let app = AppState.test(client: client, accountDefaults: defaults)
            do {
                app.setAppSceneActive(true)
                await app.bootstrap()
                XCTAssertTrue(app.activeAccountRef == fixture.account)
                let reader = try app.makeSynchronizedHistoryModel(groupIdHex: fixture.group)
                await reader.loadNextPage()
                XCTAssertFalse(reader.readFailed)
                XCTAssertTrue(reader.records.isEmpty)
                let review = try app.makeHistoryConsentReviewModel()
                try writeObservation(["ready": true], named: "ready.json", directory: directory)
                try await exerciseHostedApproval(review, directory: directory)
                let selected = try XCTUnwrap(review.selected)
                let deadline = ContinuousClock.now.advanced(by: .seconds(40))
                while try await selected.refresh().complete == false {
                    guard ContinuousClock.now < deadline else { throw GenuineApprovalError.deadline }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertEqual(selected.review?.importedRecords, 1)
                await reader.reload()
                try checkImported(reader, fixture: fixture, selected: selected)
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                XCTAssertFalse(review.isActive)
                XCTAssertFalse(selected.isActive)
                XCTAssertFalse(reader.isCurrentOwner)
                XCTAssertTrue(reader.records.isEmpty)
                try writeObservation(
                    ["consent_complete": true, "imported_records": 1, "reader_verified": true, "owner_retired": true],
                    named: "completed.json", directory: directory)
            } catch {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("failed.json").path) {
                    try writeObservation(
                        ["failed": true, "stage": "app-owner"], named: "failed.json", directory: directory)
                }
                throw error
            }
        }

        private func readFixture(_ directory: URL) async throws -> GenuineApprovalFixture {
            let path = directory.appendingPathComponent("fixture.json")
            let deadline = ContinuousClock.now.advanced(by: .seconds(180))
            while !FileManager.default.fileExists(atPath: path.path) {
                guard ContinuousClock.now < deadline else { throw GenuineApprovalError.deadline }
                try await Task.sleep(for: .milliseconds(100))
            }
            let data = try Data(contentsOf: path)
            guard data.count <= 32768,
                try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber == 0o600
            else { throw GenuineApprovalError.invalidFixture }
            return try JSONDecoder().decode(GenuineApprovalFixture.self, from: data)
        }

        private func exerciseHostedApproval(_ model: HistoryConsentReviewModel, directory: URL) async throws {
            var graph: GenuineApprovalGraph? = .init()
            weak var retiredGraph = graph
            var host: UIHostingController<AnyView>? = UIHostingController(
                rootView: AnyView(GenuineApprovalRoot(model: model, graph: try XCTUnwrap(graph))))
            graph = nil
            weak var retiredHost = host
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.keyWindow
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                host?.rootView = AnyView(EmptyView())
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            var actionFailure: Error?
            var stage = "waiting-original"
            do {
                await Task.yield()
                let deadline = ContinuousClock.now.advanced(by: .seconds(40))
                while model.scopes.isEmpty {
                    if !model.isWorking { try await model.loadPending() }
                    guard ContinuousClock.now < deadline else { throw GenuineApprovalError.deadline }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertEqual(model.scopes.count, 1)
                let scope = try XCTUnwrap(model.scopes.first)
                try await model.select(id: scope.id)
                let displayed = try XCTUnwrap(model.review)
                XCTAssertFalse(displayed.complete)
                XCTAssertEqual(displayed.importedRecords, 0)
                await Task.yield()
                host?.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                stage = "hosted-activation"
                let view = try XCTUnwrap(host?.view)
                scrollToBottom(view)
                await Task.yield()
                view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "genuine-original-history-review-before-explicit-approval"
                attachment.lifetime = .keepAlways
                add(attachment)
                try writeObservation(["ready": true], named: "ui-ready.json", directory: directory)
                stage = "awaiting-approval-action"
                while model.isWorking || model.review?.revision == displayed.revision {
                    guard ContinuousClock.now < deadline else { throw GenuineApprovalError.deadline }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertFalse(model.failed)
                XCTAssertTrue(model.selected === scope)
                XCTAssertNotNil(model.review)
                try writeObservation(
                    [
                        "group": displayed.groupIdHex, "source": hex(displayed.sourceDevice),
                        "recipient": hex(displayed.recipientDevice), "records": displayed.recordCount,
                        "encoded_bytes": displayed.encodedBytes, "fragments": displayed.fragmentCount,
                        "ceiling": displayed.snapshotTimestampCeiling, "explicit_action": true, "archive_before": 0,
                    ],
                    named: "approved.json", directory: directory)
            } catch {
                actionFailure = error
            }
            host?.rootView = AnyView(EmptyView())
            window.isHidden = true
            window.rootViewController = nil
            host = nil
            previous?.makeKey()
            let retirementDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while retiredHost != nil || retiredGraph != nil, ContinuousClock.now < retirementDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(retiredHost)
            XCTAssertNil(retiredGraph)
            withExtendedLifetime(model) {}
            if let actionFailure {
                try writeObservation(["failed": true, "stage": stage], named: "failed.json", directory: directory)
                throw actionFailure
            }
        }

        private func scrollToBottom(_ view: UIView) {
            view.layoutIfNeeded()
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
                let bottom = max(
                    -scroll.adjustedContentInset.top,
                    scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: bottom), animated: false)
                scroll.layoutIfNeeded()
            }
            for child in view.subviews { scrollToBottom(child) }
        }

        private func checkImported(
            _ reader: SynchronizedHistoryViewModel, fixture: GenuineApprovalFixture, selected: NativeHistoryConsentScope
        ) throws {
            XCTAssertFalse(reader.readFailed)
            XCTAssertEqual(reader.records.count, 1)
            let row = try XCTUnwrap(reader.records.first)
            XCTAssertTrue(row.id == fixture.oldMessage && row.authorPubkey == fixture.author)
            XCTAssertEqual(SHA256.hash(data: Data(row.content.utf8)), SHA256.hash(data: Data(fixture.oldContent.utf8)))
            XCTAssertTrue(row.tags.map(\.values) == fixture.oldTags)
            XCTAssertTrue(row.sourceDevice == selected.review?.sourceDevice)
            XCTAssertEqual(row.transferId.count, 32)
            XCTAssertEqual(row.manifestDigest.count, 32)
        }
        private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        private func writeObservation(_ value: [String: Any], named: String, directory: URL) throws {
            let path = directory.appendingPathComponent(named)
            guard !FileManager.default.fileExists(atPath: path.path) else { throw GenuineApprovalError.invalidFixture }
            let temporary = directory.appendingPathComponent(".observation-\(UUID())")
            try JSONSerialization.data(withJSONObject: value).write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try FileManager.default.moveItem(at: temporary, to: path)
        }
    }
#endif
