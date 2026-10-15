#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Darwin
    import Foundation

    /// Observation-only test input. Native originals still come from the live SDK factory.
    enum HostedNativeFixtureRoot {
        private struct Provenance: Decodable {
            let version: Int
            let sdkSource: String
            let sdkRunId: String
            let agentSha256: String
            let platform: String
            let originalWorkerClosed: Bool
            enum CodingKeys: String, CodingKey {
                case version, platform
                case sdkSource = "sdk_source"
                case sdkRunId = "sdk_run_id"
                case agentSha256 = "agent_sha256"
                case originalWorkerClosed = "original_worker_closed"
            }
        }

        nonisolated static func accepts(
            _ root: URL, prefix: String,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) throws -> Bool {
            guard prefix == "native-" || prefix == "automatic-host-switch-" else { return false }
            // Preserve the existing dedicated-host allowlist and its caller checks.
            if root.path.hasPrefix("/Users/pj/project/build/" + prefix) { return true }
            guard environment["GITHUB_ACTIONS"] == "true",
                let declaredBase = environment["WN_NATIVE_ACCEPTANCE_BASE"],
                let sdkSource = environment["WN_NATIVE_ACCEPTANCE_SDK_SOURCE"],
                let sdkRunId = environment["WN_NATIVE_ACCEPTANCE_SDK_RUN_ID"],
                let agentSha = environment["WN_NATIVE_ACCEPTANCE_AGENT_SHA256"],
                isHex(sdkSource, count: 40), isHex(agentSha, count: 64),
                !sdkRunId.isEmpty, sdkRunId.allSatisfy({ "0123456789".contains($0) })
            else { return false }
            let base = URL(fileURLWithPath: declaredBase, isDirectory: true).standardizedFileURL
            guard declaredBase.hasPrefix("/"), base.path == base.resolvingSymlinksInPath().path,
                root.path == root.resolvingSymlinksInPath().path,
                root.deletingLastPathComponent().path == base.path,
                root.lastPathComponent.hasPrefix(prefix), root.lastPathComponent.count > prefix.count,
                try owned(base, mode: 0o700, type: .typeDirectory),
                try owned(root, mode: 0o700, type: .typeDirectory)
            else { return false }
            let marker = root.appendingPathComponent(".native-acceptance")
            let provenanceFile = root.appendingPathComponent(".hosted-native-fixture.json")
            let credentials = root.appendingPathComponent("credentials", isDirectory: true)
            guard try owned(marker, mode: 0o600, type: .typeRegular),
                try owned(provenanceFile, mode: 0o600, type: .typeRegular),
                try owned(credentials, mode: 0o700, type: .typeDirectory),
                try owned(credentials.appendingPathComponent("credentials.key"), mode: 0o600, type: .typeRegular),
                try owned(credentials.appendingPathComponent("signing-credentials.sealed"), mode: 0o600, type: .typeRegular),
                try Data(contentsOf: marker) == Data("native-sdk83-test-only-v1\n".utf8)
            else { return false }
            let bytes = try Data(contentsOf: provenanceFile)
            guard bytes.count <= 2048 else { return false }
            let provenance = try JSONDecoder().decode(Provenance.self, from: bytes)
            #if os(iOS)
                let platform = "ios-simulator"
            #else
                let platform = "macos"
            #endif
            return provenance.version == 1 && provenance.originalWorkerClosed
                && provenance.platform == platform && provenance.sdkSource == sdkSource
                && provenance.sdkRunId == sdkRunId && provenance.agentSha256 == agentSha
        }

        nonisolated private static func isHex(_ value: String, count: Int) -> Bool {
            value.utf8.count == count && value.allSatisfy { "0123456789abcdef".contains($0) }
        }

        nonisolated private static func owned(_ url: URL, mode: Int, type: FileAttributeType) throws -> Bool {
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            return values[.type] as? FileAttributeType == type
                && (values[.posixPermissions] as? NSNumber)?.intValue == mode
                && (values[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        }
    }
#endif
