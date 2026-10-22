import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct AccountAttentionCreationTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["WN_RUN_ATTENTION_CREATION_DIAGNOSTIC"] == "1"),
        arguments: [false, true]
    )
    func generatedAccountReadinessWithAndWithoutAttention(useAttention: Bool) async throws {
        // Explicitly enabled only by the owned-relay runner. Never turn this
        // readiness diagnostic into a public-network or unreachable-relay test.
        let relay = try #require(ProcessInfo.processInfo.environment["WN_NATIVE_TEST_RELAY_URL"])
        let components = try #require(URLComponents(string: relay))
        let port = try #require(components.port)
        try #require(components.scheme == "ws" && components.host == "127.0.0.1"
            && (1...65535).contains(port) && components.user == nil && components.password == nil
            && components.query == nil && components.fragment == nil
            && (components.path.isEmpty || components.path == "/"))
        let client = try MarmotClient.testClient(relayUrls: [relay], relayPolicy: .allowLoopback)
        let appState = AppState.test(client: client)
        appState.accountAttentionEnabledForTesting = useAttention
        recordStage("bootstrap_begin", useAttention: useAttention)
        await appState.bootstrap()
        recordStage("bootstrap_end", useAttention: useAttention)
        var stage = "first identity"
        var firstNetworkReady = false
        var secondDistinct = false
        var bodyCompleted = false
        do {
            recordStage("first_identity_begin", useAttention: useAttention)
            let first = try await appState.createIdentity()
            recordStage("first_identity_end", useAttention: useAttention)
            stage = "readiness after first identity"
            var ready = false
            recordStage("readiness_begin", useAttention: useAttention)
            for _ in 0..<300 {
                if try client.marmot.accountSetupReadiness(accountRef: first.label) == .networkReady {
                    ready = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            recordStage("readiness_end", useAttention: useAttention)
            firstNetworkReady = ready
            try #require(ready, "The first identity must reach relay readiness before testing second-account creation")
            stage = "second identity"
            recordStage("second_identity_begin", useAttention: useAttention)
            let second = try await appState.createIdentity()
            recordStage("second_identity_end", useAttention: useAttention)
            secondDistinct = second.accountIdHex != first.accountIdHex
            #expect(second.accountIdHex != first.accountIdHex)
            bodyCompleted = true
        } catch {
            Issue.record("Attention enabled: \(useAttention); stage: \(stage); error: \(error)")
        }
        recordStage("suspension_begin", useAttention: useAttention)
        await appState.startRuntimeSuspension().value
        recordStage("suspension_end", useAttention: useAttention)
        // Closed per-argument observations after the ORIGINAL suspension await.
        // This records await completion, not SDK socket/storage closure.
        // swiftlint:disable:next no_direct_standard_out_logs
        print(
            "attention-creation-result use_attention=\(useAttention)"
                + " first_network_ready=\(firstNetworkReady) second_distinct=\(secondDistinct)"
                + " body_completed=\(bodyCompleted) suspension_await_completed=true"
        )
    }

    private func recordStage(_ stage: String, useAttention: Bool) {
        let line = "attention-creation-stage use_attention=\(useAttention) stage=\(stage)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
