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
        await appState.bootstrap()
        var stage = "first identity"
        var firstNetworkReady = false
        var secondDistinct = false
        var bodyCompleted = false
        do {
            let first = try await appState.createIdentity()
            stage = "readiness after first identity"
            var ready = false
            for _ in 0..<300 {
                if try client.marmot.accountSetupReadiness(accountRef: first.label) == .networkReady {
                    ready = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            firstNetworkReady = ready
            try #require(ready, "The first identity must reach relay readiness before testing second-account creation")
            stage = "second identity"
            let second = try await appState.createIdentity()
            secondDistinct = second.accountIdHex != first.accountIdHex
            #expect(second.accountIdHex != first.accountIdHex)
            bodyCompleted = true
        } catch {
            Issue.record("Attention enabled: \(useAttention); stage: \(stage); error: \(error)")
        }
        await appState.startRuntimeSuspension().value
        // Closed per-argument observations after the ORIGINAL suspension await.
        // This records await completion, not SDK socket/storage closure.
        // swiftlint:disable:next no_direct_standard_out_logs
        print(
            "attention-creation-result use_attention=\(useAttention)"
                + " first_network_ready=\(firstNetworkReady) second_distinct=\(secondDistinct)"
                + " body_completed=\(bodyCompleted) suspension_await_completed=true"
        )
    }
}
