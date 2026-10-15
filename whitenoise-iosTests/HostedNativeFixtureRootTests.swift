#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import XCTest

    final class HostedNativeFixtureRootTests: XCTestCase {
        private struct Fixture {
            let base: URL
            let root: URL
            let environment: [String: String]
        }

        private func fixture() throws -> Fixture {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("hosted-root-controls-\(UUID())", isDirectory: true)
                .resolvingSymlinksInPath()
            let root = base.appendingPathComponent("native-control", isDirectory: true)
            let credentials = root.appendingPathComponent("credentials", isDirectory: true)
            for path in [base, root, credentials] {
                try FileManager.default.createDirectory(
                    at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            addTeardownBlock { try FileManager.default.removeItem(at: base) }
            for (path, bytes) in [
                (root.appendingPathComponent(".native-acceptance"), Data("native-sdk83-test-only-v1\n".utf8)),
                (credentials.appendingPathComponent("credentials.key"), Data(repeating: 0, count: 32)),
                (credentials.appendingPathComponent("signing-credentials.sealed"), Data()),
            ] {
                try bytes.write(to: path, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            }
            let environment = [
                "GITHUB_ACTIONS": "true", "WN_NATIVE_ACCEPTANCE_BASE": base.path,
                "WN_NATIVE_ACCEPTANCE_SDK_SOURCE": String(repeating: "a", count: 40),
                "WN_NATIVE_ACCEPTANCE_SDK_RUN_ID": "123",
                "WN_NATIVE_ACCEPTANCE_AGENT_SHA256": String(repeating: "b", count: 64),
            ]
            let value = Fixture(base: base, root: root, environment: environment)
            try writeProvenance(value)
            return value
        }

        private func writeProvenance(_ fixture: Fixture, overrides: [String: Any] = [:]) throws {
            #if os(iOS)
                let platform = "ios-simulator"
            #else
                let platform = "macos"
            #endif
            var value: [String: Any] = [
                "version": 1, "sdk_source": String(repeating: "a", count: 40),
                "sdk_run_id": "123", "agent_sha256": String(repeating: "b", count: 64),
                "platform": platform, "original_worker_closed": true,
            ]
            value.merge(overrides) { _, new in new }
            let path = fixture.root.appendingPathComponent(".hosted-native-fixture.json")
            try JSONSerialization.data(withJSONObject: value).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }

        func testClosedMatchingPrivateRootIsAcceptedOnlyInsideExplicitCIBase() throws {
            let value = try fixture()
            XCTAssertTrue(try HostedNativeFixtureRoot.accepts(value.root, prefix: "native-", environment: value.environment))
            var environment = value.environment
            environment.removeValue(forKey: "GITHUB_ACTIONS")
            XCTAssertFalse(try HostedNativeFixtureRoot.accepts(value.root, prefix: "native-", environment: environment))
            environment = value.environment
            environment["WN_NATIVE_ACCEPTANCE_BASE"] = value.base.deletingLastPathComponent().path
            XCTAssertFalse(try HostedNativeFixtureRoot.accepts(value.root, prefix: "native-", environment: environment))
        }

        func testMismatchedSDKProducerPlatformOrUnclosedWorkerIsRefused() throws {
            let value = try fixture()
            let mismatches: [[String: Any]] = [
                ["sdk_source": String(repeating: "c", count: 40)], ["sdk_run_id": "456"],
                ["agent_sha256": String(repeating: "d", count: 64)],
                ["platform": "unsupported"], ["original_worker_closed": false], ["version": 2],
            ]
            for mismatch in mismatches {
                try writeProvenance(value, overrides: mismatch)
                XCTAssertFalse(try HostedNativeFixtureRoot.accepts(value.root, prefix: "native-", environment: value.environment))
            }
        }

        func testBroadPermissionsOrMissingMarkerAreRefused() throws {
            let value = try fixture()
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: value.root.path)
            XCTAssertFalse(try HostedNativeFixtureRoot.accepts(value.root, prefix: "native-", environment: value.environment))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: value.root.path)
            try FileManager.default.removeItem(at: value.root.appendingPathComponent(".native-acceptance"))
            XCTAssertThrowsError(try HostedNativeFixtureRoot.accepts(value.root, prefix: "native-", environment: value.environment))
        }
    }
#endif
