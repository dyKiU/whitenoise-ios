#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Synchronization
    import XCTest
    @testable import whitenoise_ios

    private enum AcceptanceFailure: Error {
        case invalidArguments, secretMissing, unexpectedAccount, comparisonMismatch, enrollmentTimeout, onboardingBlocked
    }
    nonisolated private final class IsolatedQRSecretStore: SecretStore, Sendable {
        private struct State { var values: [String: String] = [:]; var labels: Set<String> = [] }
        private let state = Mutex(State())
        func hasSecretForLabel(label: String) throws -> Bool { state.withLock { $0.labels.contains(label) } }
        func hasSecretForAccountId(accountIdHex: String) throws -> Bool { state.withLock { $0.values[accountIdHex] != nil } }
        func writeSecret(label: String, accountIdHex: String, secretKeyHex: String) throws {
            state.withLock { $0.values[accountIdHex] = secretKeyHex; $0.labels.insert(label) }
        }
        func loadSecret(label: String, accountIdHex: String) throws -> String {
            try state.withLock {
                guard let secret = $0.values[accountIdHex] else { throw AcceptanceFailure.secretMissing }
                return secret
            }
        }
        func removeSecret(label: String, accountIdHex: String) throws {
            state.withLock { $0.values.removeValue(forKey: accountIdHex); $0.labels.remove(label) }
        }
    }

    @MainActor final class NativePairingQRCodeTests: XCTestCase {
        func testActualThreeDevicePacketsPassAppCodecAndOriginalSdkAuthentication() async throws {
            guard ProcessInfo.processInfo.environment["WN_NATIVE_PAIRING_QR_ACCEPTANCE"] == "1" else {
                throw XCTSkip("Requires the isolated development relay.")
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PairingQR-\(UUID())")
            var passed = false
            defer { if passed { try? FileManager.default.removeItem(at: root) } }
            var stage = "start"
            do {
                try await NativePairingQRControls.run(root: root, stage: &stage)
                passed = true
            } catch {
                // SDK errors can contain private packet metadata; report only the static stage.
                XCTFail("Native QR gate failed at \(stage)")
            }
        }
    }
  /// Real originals and the unchanged app codec; only lengths and pass flags leave this gate.
  @MainActor enum NativePairingQRControls {
    static func roundTrip(_ bytes: Data, role: String) throws -> Data {
      do {
        let pages = try DevicePairingQRCode.payloads(packet: bytes.base64EncodedString())
        var accumulator = DevicePairingQRCode.FragmentAccumulator()
        var decoded: String?
        for page in pages.reversed() {
          if let complete = try accumulator.ingest(page) { decoded = complete }
          if pages.count > 1 {
            guard try accumulator.ingest(page) == nil else {
              throw AcceptanceFailure.unexpectedAccount
            }
          }
        }
        guard let decoded, pages.allSatisfy({ $0.utf8.count <= 2200 }),
          try DeviceVerificationPacketInput.decode(decoded) == bytes
        else {
          throw AcceptanceFailure.unexpectedAccount
        }
        let maximumText = pages.map { $0.utf8.count }.max() ?? 0












      // Test-only non-sensitive native transport/cleanup counts.
      // swiftlint:disable:next no_direct_standard_out_logs
      print(
          "{\"packet_role\":\"\(role)\",\"packet_bytes\":\(bytes.count),\"text_bytes\":\(maximumText),\"frames\":\(pages.count),\"within_2200\":true,\"round_trip\":true}"
        )
        return try DeviceVerificationPacketInput.decode(decoded)
      } catch {












      // Test-only non-sensitive native transport/cleanup counts.
      // swiftlint:disable:next no_direct_standard_out_logs
      print("{\"packet_role\":\"\(role)\",\"packet_bytes\":\(bytes.count),\"round_trip\":false}")
        throw error
      }
    }

    static func exchange(_ a: DeviceLinkingSession, _ b: DeviceLinkingSession, label: String)
      async throws
    {
      for _ in 0..<8 {
        for (source, destination) in [(a, b), (b, a)] {
          for packet in try await source.outgoingPackets() {
            let decoded = try roundTrip(packet.bytes, role: label)
            try await destination.receivePacket(packet: decoded)
            try await source.acknowledgePacket(acknowledgementId: packet.acknowledgementId)
          }
        }
      }
    }
    static func confirmAndContinue(
      _ a: DeviceLinkingSession, _ b: DeviceLinkingSession, label: String
    ) async throws {
      let av = try await a.snapshot()
      let bv = try await b.snapshot()
      guard av.phase == .comparisonAvailable, bv.phase == .comparisonAvailable,
        let ac = av.decimals, let bc = bv.decimals,
        ac.first == bc.first, ac.second == bc.second, ac.third == bc.third
      else { throw AcceptanceFailure.comparisonMismatch }
      try await a.confirmComparison(displayedRevision: av.revision)
      try await b.confirmComparison(displayedRevision: bv.revision)
      try await exchange(a, b, label: label)
      try await b.continueLinkingAndShareChats(displayedRevision: b.snapshot().revision)
      try await a.continueLinkingAndShareChats(displayedRevision: a.snapshot().revision)
    }
    static func waitFor(_ ready: () async throws -> Bool) async throws {
      for _ in 0..<600 {
        if try await ready() { return }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      throw AcceptanceFailure.enrollmentTimeout
    }

    static func run(root: URL, stage: inout String) async throws {
      guard !FileManager.default.fileExists(atPath: root.path) else {
        throw AcceptanceFailure.invalidArguments
      }
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let relay = "ws://127.0.0.1:18181"
      let stores = [IsolatedQRSecretStore(), IsolatedQRSecretStore(), IsolatedQRSecretStore()]
      var runtimes: [Marmot] = []
      var originals: [DeviceLinkingSession] = []
      var approvals: [DeviceLinkingApproval] = []
      var originalFailure: Error?
      do {
        for (index, store) in stores.enumerated() {
          #if WN_CURRENT_SDK_API
              var runtimeOptions = MarmotOptions(deployment: marmotDeploymentWhiteNoise())
          #else
              var runtimeOptions = MarmotOptions()
          #endif
          runtimeOptions.relayPolicy = .allowLoopback
          runtimeOptions.clientName = "native-real-packet-qr"
          runtimeOptions.secretStore = store
          let runtime = try Marmot.newWithConfiguration(
            rootPath: root.appendingPathComponent(["a", "b", "c"][index]).path, relayUrls: [relay],
            options: runtimeOptions)
          runtimes.append(runtime)
          try await runtime.start()
        }
        let a = runtimes[0]
        let b = runtimes[1]
        stage = "qr-create-synthetic-identity"
        let account = try await a.createIdentity(
          defaultRelays: [relay], bootstrapRelays: [relay], inboxRelays: [relay])
        let secret = try stores[0].loadSecret(
          label: account.label, accountIdHex: account.accountIdHex)
        guard
          try await onboard(runtime: b, secret: secret, stage: &stage)
            == account.accountIdHex
        else {
          throw AcceptanceFailure.unexpectedAccount
        }
        stage = "qr-real-request"
        let recipient = try await b.beginDeviceLinkingSession(accountRef: account.accountIdHex)
        originals.append(recipient)
        let request = try roundTrip(recipient.setupPacket(), role: "request")
        stage = "qr-authenticate-request"
        let approver = try await a.approveDeviceLinkingSession(
          accountRef: account.accountIdHex, request: request, target: nil)
        originals.append(approver)
        stage = "qr-real-challenge"
        let challenge = try roundTrip(approver.setupPacket(), role: "challenge")
        stage = "qr-authenticate-challenge"
        try await recipient.receiveSetupPacket(packet: challenge)
        try await exchange(approver, recipient, label: "ab-proof")
        try await confirmAndContinue(approver, recipient, label: "ab-confirmation")
        stage = "qr-real-ab-enrollment"
        try await waitFor {
          let av = try await approver.snapshot()
          let bv = try await recipient.snapshot()
          return av.phase == .enrollmentComplete && bv.phase == .enrollmentComplete
        }
        try await approver.cancel()
        try await recipient.cancel()
        originals.removeAll()
        let c = runtimes[2]
        guard
          try await onboard(runtime: c, secret: secret, stage: &stage)
            == account.accountIdHex
        else {
          throw AcceptanceFailure.unexpectedAccount
        }
        let targets = try await a.deviceLinkingTargets(accountRef: account.accountIdHex)
        guard targets.count == 1, targets[0].deviceCount == 2 else {
          throw AcceptanceFailure.unexpectedAccount
        }
        stage = "qr-real-c-request"
        let joining = try await c.beginDeviceLinkingSession(accountRef: account.accountIdHex)
        originals.append(joining)
        let cRequest = try roundTrip(joining.setupPacket(), role: "c-request")
        stage = "qr-authenticate-c-request"
        let coordinator = try await a.approveDeviceLinkingSession(
          accountRef: account.accountIdHex, request: cRequest, target: targets[0].selector)
        originals.append(coordinator)
        let cChallenge = try roundTrip(coordinator.setupPacket(), role: "c-challenge")
        try await joining.receiveSetupPacket(packet: cChallenge)
        try await exchange(coordinator, joining, label: "c-proof")
        try await confirmAndContinue(coordinator, joining, label: "c-confirmation")
        stage = "qr-original-sibling-review"
        try await waitFor {
          if approvals.isEmpty {
            approvals = try await b.pendingDeviceLinkingApprovals(accountRef: account.accountIdHex)
          }
          return approvals.count == 1
        }
        let sibling = approvals[0]
        let observed = try await sibling.snapshot()
        let reviewed = try await sibling.reviewMetadata(displayedRevision: observed.revision)
        guard reviewed.existingDeviceCount == 2 else { throw AcceptanceFailure.unexpectedAccount }
        try await sibling.approveAndShareChats(displayedRevision: observed.revision)
        stage = "qr-original-enrollment-export"
        var enrollment: Data?
        try await waitFor {
          do {
            enrollment = try await coordinator.enrollmentPacket(
              displayedRevision: coordinator.snapshot().revision)
            return true
          } catch MarmotKitError.DeviceLinkingNotReady { return false }
        }
        guard let actualEnrollment = enrollment else { throw AcceptanceFailure.unexpectedAccount }
        let decodedEnrollment = try roundTrip(actualEnrollment, role: "enrollment-capacity")
        // Both enrollment panes stage this same canonical packet before explicit receive.












      // Test-only non-sensitive native transport/cleanup counts.
      // swiftlint:disable:next no_direct_standard_out_logs
      print(
          "{\"packet_role\":\"enrollment-copy-transport\",\"packet_bytes\":\(decodedEnrollment.count),\"qr_exposed\":true}"
        )
        stage = "qr-original-enrollment-receive"
        try await joining.receiveEnrollmentPacket(
          displayedRevision: joining.snapshot().revision, packet: decodedEnrollment)
        try await sibling.receiveEnrollmentPacket(
          displayedRevision: sibling.snapshot().revision, packet: decodedEnrollment)
        try await coordinator.finalizeLinking(displayedRevision: coordinator.snapshot().revision)
        stage = "qr-real-three-device-settlement"
        try await waitFor {
          let av = try await coordinator.snapshot()
          let cv = try await joining.snapshot()
          let bv = try await sibling.snapshot()
          return av.phase == .enrollmentComplete && cv.phase == .enrollmentComplete
            && bv.phase == .settled
        }
        for runtime in runtimes {
          let settled = try await runtime.deviceLinkingTargets(accountRef: account.accountIdHex)
          guard settled.count == 1, settled[0].deviceCount == 3 else {
            throw AcceptanceFailure.unexpectedAccount
          }
        }
      } catch { originalFailure = error }
      var cleanupFailure: Error?
      for original in originals {
        do { try await original.cancel() } catch { cleanupFailure = cleanupFailure ?? error }
      }
      for original in approvals {
        do { try await original.cancel() } catch { cleanupFailure = cleanupFailure ?? error }
      }
      var closed = 0
      for runtime in runtimes {
        do {
          try await runtime.shutdownAndClose()
          guard runtime.storageIsClosed() else { throw AcceptanceFailure.unexpectedAccount }
          closed += 1
        } catch { cleanupFailure = cleanupFailure ?? error }
      }






      // Test-only non-sensitive native transport/cleanup counts.
      // swiftlint:disable:next no_direct_standard_out_logs
      print("{\"positive_closes\":\(closed),\"cleanup_passed\":\(cleanupFailure == nil)}")
      if let originalFailure { throw originalFailure }
      if let cleanupFailure { throw cleanupFailure }
      guard closed == 3 else { throw AcceptanceFailure.unexpectedAccount }






      // Test-only non-sensitive native transport/cleanup counts.
      // swiftlint:disable:next no_direct_standard_out_logs
      print(
        "{\"gate\":\"native-real-packet-qr\",\"passed\":1,\"failed\":0,\"request_authenticated\":true,\"challenge_authenticated\":true,\"third_device_settled\":true,\"enrollment_authenticated\":true}"
      )
    }
    static func onboard(runtime: Marmot, secret: String, stage: inout String) async throws -> String {
        let relay = "ws://127.0.0.1:18181"
        var onboard = try await runtime.beginOnboarding(
            nsec: secret,
            options: OnboardingOptionsFfi(defaultRelays: [relay], discoveryRelays: [relay], inboxRelays: [relay]))
        for _ in 0..<32 {
            if onboard.ready { break }
            onboard = try await runtime.runOnboarding(accountRef: onboard.accountIdHex)
            if onboard.ready { break }
            guard
                let blocked = onboard.steps.first(where: {
                    $0.status == .needsInput || $0.status == .retryableFailure
                })
            else {
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            stage =
                "second-onboarding-" + String(describing: blocked.step) + "-" + String(describing: blocked.status)
            if blocked.actions.contains(.continueWithout) {
                onboard = try await runtime.continueOnboardingWithout(
                    accountRef: onboard.accountIdHex, step: blocked.step)
            } else if blocked.step == .singleDevice && blocked.actions.contains(.continueAnyway) {
                onboard = try await runtime.acknowledgeOnboardingSingleDevice(
                    accountRef: onboard.accountIdHex, revision: onboard.revision)
            } else if blocked.step == .relays || blocked.step == .inboxRelays {
                let proposal = try await runtime.proposeOnboardingRelays(
                    accountRef: onboard.accountIdHex,
                    step: blocked.step, readRelays: [relay], writeRelays: [relay])
                onboard = try await runtime.approveOnboardingRepair(
                    accountRef: onboard.accountIdHex, revision: proposal.revision)
            } else {
                throw AcceptanceFailure.onboardingBlocked
            }
        }
        guard onboard.ready else { throw AcceptanceFailure.onboardingBlocked }
        return onboard.accountIdHex
    }

  }
#endif
