import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    @MainActor @Suite struct NativeDeviceLinkingRuntimeTests {
        private func withRuntime(_ body: (MarmotClient) async throws -> Void) async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "white-noise-linking-runtime-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try MarmotClient(
                rootPath: root.path,
                relayUrls: ["wss://relay.example.invalid"]
            )
            do {
                try await body(client)
                #expect(try client.marmot.listAccounts().isEmpty)
                try await client.marmot.shutdownAndClose()
            } catch {
                try? await client.marmot.shutdownAndClose()
                throw error
            }
        }

        @Test func matchedRuntimeReportsQualifiedVerificationAndEnrollment() async throws {
            try await withRuntime { runtime in
                let capabilities = runtime.deviceLinkingCapabilities()
                #expect(capabilities.verificationSupported)
                #expect(capabilities.enrollmentSupported)
            }
        }

        @Test func newDeviceFactoryPreservesMissingAccountErrorAndCreatesNoIdentity() async throws {
            try await withRuntime { runtime in
                await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                    _ = try await runtime.beginDeviceLinkingSession(accountRef: "missing")
                }
            }
        }

        @Test func approverFactoryPreservesMissingAccountErrorAndCreatesNoIdentity() async throws {
            try await withRuntime { runtime in
                await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                    _ = try await runtime.approveDeviceLinkingSession(
                        accountRef: "missing", request: Data(), target: nil)
                }
            }
        }

        @Test func targetReadPreservesMissingAccountErrorAndCreatesNoIdentity() async throws {
            try await withRuntime { runtime in
                await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                    _ = try await runtime.deviceLinkingTargets(accountRef: "missing")
                }
            }
        }

        @Test func approvalReadPreservesMissingAccountErrorAndCreatesNoIdentity() async throws {
            try await withRuntime { runtime in
                await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                    _ = try await runtime.pendingDeviceLinkingApprovals(accountRef: "missing")
                }
            }
        }
    }
#endif
