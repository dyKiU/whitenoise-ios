import CryptoKit
import Foundation
import MarmotKit
import SwiftUI
import XCTest

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    private enum ImportedHistoryFixtureError: Error { case invalidFixture, credentialMutationRefused }

    private struct ImportedHistoryFixture: Decodable {
        let version: Int
        let root: String
        let account: String
        let group: String
        let liveMessage: String
        let record: Record
        enum CodingKeys: String, CodingKey {
            case version, root, account, group, record
            case liveMessage = "live_message"
        }
        struct Record: Decodable {
            let message: String
            let author: String
            let content: String
            let tags: [[String]]
            let createdAt: UInt64
            let expiresAt: UInt64?
            let deleted: Bool
            let mediaCount: Int
            let source: String
            let transfer: String
            let manifest: String
            enum CodingKeys: String, CodingKey {
                case message, author, content, tags, deleted, source, transfer, manifest
                case createdAt = "created_at"
                case expiresAt = "expires_at"
                case mediaCount = "media_count"
            }
        }
        static func read(_ path: String) throws -> Self {
            let url = URL(fileURLWithPath: path)
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 32768,
                try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber == 0o600
            else { throw ImportedHistoryFixtureError.invalidFixture }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            let root = URL(fileURLWithPath: value.root, isDirectory: true).resolvingSymlinksInPath()
            guard value.version == 1, root.path.hasPrefix("/Users/pj/project/build/native-"),
                try Data(contentsOf: root.appendingPathComponent(".native-acceptance"))
                    == Data("native-sdk83-test-only-v1\n".utf8),
                value.record.content.utf8.count == 8192, value.record.mediaCount == 0,
                !value.record.deleted, value.record.expiresAt == nil
            else { throw ImportedHistoryFixtureError.invalidFixture }
            return value
        }
    }

    /// Read the original task callback's authenticated envelope; no Keychain or credential copy.
    nonisolated private final class ImportedHistoryReadOnlyStore: SecretStore {
        private let values: [String: String]
        init(root: URL) throws {
            let directory = root.appendingPathComponent("credentials", isDirectory: true)
            let keyFile = directory.appendingPathComponent("credentials.key")
            let sealedFile = directory.appendingPathComponent("signing-credentials.sealed")
            for (url, permissions) in [(root, 0o700), (directory, 0o700), (keyFile, 0o600), (sealedFile, 0o600)] {
                guard
                    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
                        == NSNumber(value: permissions)
                else { throw ImportedHistoryFixtureError.invalidFixture }
            }
            let key = try Data(contentsOf: keyFile)
            let sealed = try Data(contentsOf: sealedFile)
            guard key.count == 32, sealed.count <= 65536 else { throw ImportedHistoryFixtureError.invalidFixture }
            let box = try AES.GCM.SealedBox(combined: sealed)
            values = try JSONDecoder().decode(
                [String: String].self, from: AES.GCM.open(box, using: SymmetricKey(data: key)))
        }
        func hasSecretForLabel(label: String) throws -> Bool { values[label] != nil }
        func hasSecretForAccountId(accountIdHex: String) throws -> Bool { values[accountIdHex] != nil }
        func loadSecret(label: String, accountIdHex: String) throws -> String {
            guard let secret = values[accountIdHex], secret.utf8.count == 64 else {
                throw ImportedHistoryFixtureError.invalidFixture
            }
            return secret
        }
        func writeSecret(label: String, accountIdHex: String, secretKeyHex: String) throws {
            throw ImportedHistoryFixtureError.credentialMutationRefused
        }
        func removeSecret(label: String, accountIdHex: String) throws {
            throw ImportedHistoryFixtureError.credentialMutationRefused
        }
    }

    @MainActor private final class ImportedHistoryGraphLifetime {}
    private struct ImportedHistoryHostedRoot: View {
        let model: SynchronizedHistoryViewModel
        let lifetime: ImportedHistoryGraphLifetime
        var body: some View {
            SynchronizedHistoryView(model: model).id(ObjectIdentifier(lifetime))
        }
    }

    /// Opt-in real SDK fixture, not a synthetic row or approval-handle test double.
    @MainActor final class GenuineImportedHistoryPaneTests: XCTestCase {
        func testRealCommittedImportThroughAccountOwnedReaderAndHostedPane() async throws {
            guard let path = ProcessInfo.processInfo.environment["WN_IMPORTED_HISTORY_FIXTURE"] else {
                throw XCTSkip("Requires a freshly committed standalone simulator recipient fixture")
            }
            let fixture = try ImportedHistoryFixture.read(path)
            let root = URL(fileURLWithPath: fixture.root, isDirectory: true)
            let callback = try ImportedHistoryReadOnlyStore(root: root)
            let client = try MarmotClient(
                rootPath: root.appendingPathComponent("runtime", isDirectory: true).path,
                relayUrls: ["ws://127.0.0.1:18181"], cursorPersistence: .advance,
                telemetryConfig: .current(), secretStore: callback, relayPolicy: .allowLoopback)
            let defaultsName = "GenuineHistoryPane-\(UUID())"
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
                let model = try app.makeSynchronizedHistoryModel(groupIdHex: fixture.group)
                await model.loadNextPage()
                try checkImported(model: model, fixture: fixture, client: client)
                try await render(model: model, fixture: fixture)
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                XCTAssertFalse(model.isCurrentOwner)
                XCTAssertTrue(model.records.isEmpty)
            } catch {
                app.setAppSceneActive(false)
                await app.startRuntimeSuspension().value
                throw error
            }
        }
        private func checkImported(
            model: SynchronizedHistoryViewModel, fixture: ImportedHistoryFixture, client: MarmotClient
        ) throws {
            XCTAssertTrue(model.isCurrentOwner)
            XCTAssertFalse(model.readFailed)
            XCTAssertEqual(model.records.count, 1)
            let actual = try XCTUnwrap(model.records.first)
            XCTAssertTrue(actual.id == fixture.record.message && actual.authorPubkey == fixture.record.author)
            XCTAssertEqual(
                SHA256.hash(data: Data(actual.content.utf8)), SHA256.hash(data: Data(fixture.record.content.utf8)))
            XCTAssertTrue(actual.tags.map(\.values) == fixture.record.tags)
            XCTAssertEqual(actual.createdAt, fixture.record.createdAt)
            XCTAssertEqual(actual.expiresAt, fixture.record.expiresAt)
            XCTAssertEqual(actual.deleted, fixture.record.deleted)
            XCTAssertEqual(actual.mediaAttachments.count, 0)
            for (bytes, expected) in [
                (actual.sourceDevice, fixture.record.source), (actual.transferId, fixture.record.transfer),
                (actual.manifestDigest, fixture.record.manifest),
            ] {
                XCTAssertEqual(bytes.count, 32)
                XCTAssertTrue(bytes.map { String(format: "%02x", $0) }.joined() == expected)
            }
            XCTAssertEqual(SynchronizedHistoryPresentation.contentState(actual, referenceDate: .now), .visible)
            let live = try client.marmot.messages(
                accountRef: fixture.account, groupIdHex: fixture.group, limit: 128, kinds: nil)
            XCTAssertTrue(live.contains { $0.messageIdHex == fixture.liveMessage })
            XCTAssertFalse(live.contains { $0.messageIdHex == fixture.record.message })
        }
        private func render(model: SynchronizedHistoryViewModel, fixture: ImportedHistoryFixture) async throws {
            var lifetime: ImportedHistoryGraphLifetime? = .init()
            weak var retiredGraph = lifetime
            var host: UIHostingController<AnyView>? = UIHostingController(
                rootView: AnyView(ImportedHistoryHostedRoot(model: model, lifetime: try XCTUnwrap(lifetime))))
            lifetime = nil
            weak var retiredHost = host
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.keyWindow
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host?.view.layoutIfNeeded()
            defer {
                host?.rootView = AnyView(EmptyView())
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            await Task.yield()
            for _ in 0..<100 {
                if !model.isLoading, model.records.count == 1 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(model.records.count, 1)
            XCTAssertTrue(model.records.first?.id == fixture.record.message)
            XCTAssertFalse(model.readFailed)
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "genuine-source-attested-imported-history-pane"
            attachment.lifetime = .keepAlways
            add(attachment)
            host?.rootView = AnyView(EmptyView())
            window.isHidden = true
            window.rootViewController = nil
            host = nil
            previous?.makeKey()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while retiredHost != nil || retiredGraph != nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(retiredHost)
            XCTAssertNil(retiredGraph)
            withExtendedLifetime(model) {}
        }
    }
#endif
