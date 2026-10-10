#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    @MainActor @Observable
    final class DeviceVerificationViewModel {
        @ObservationIgnored private let beginOriginal: @MainActor () async throws -> any DeviceVerificationSession
        @ObservationIgnored private let approveOriginal:
            @MainActor (Data, Data?) async throws -> any DeviceVerificationSession
        @ObservationIgnored private let readTargets: @MainActor () async throws -> [DeviceLinkingTargetFfi]
        let verificationSupported: Bool
        let enrollmentSupported: Bool
        @ObservationIgnored private let enrollmentOriginal: @MainActor () throws -> DeviceEnrollmentViewModel
        private var successfulTargetRead = false
        // Cancellation alone cannot distinguish overlapping finite read completions.
        @ObservationIgnored private var targetReadID: UUID?
        var isReadingTargets: Bool { targetReadID != nil }
        var hasLoadedTargets: Bool { isActive && successfulTargetRead && !isReadingTargets }
        private var cachedTargets: [DeviceLinkingTargetFfi] = []
        var targets: [DeviceLinkingTargetFfi] { isActive ? cachedTargets : [] }
        @ObservationIgnored private let cancelOriginal: @MainActor () async throws -> Void
        private(set) var owner: (any DeviceVerificationSession)?
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        @ObservationIgnored private let readCleanupFailure: @MainActor () -> Bool
        private var retired = false
        var isActive: Bool { !retired && isCurrent() }
        var cleanupRequired: Bool { readCleanupFailure() }
        private(set) var isStarting = false
        @ObservationIgnored private var pending: Task<any DeviceVerificationSession, Error>?
        var snapshot: DeviceLinkingSnapshotFfi? { isActive ? owner?.latestSnapshot : nil }

        init(
            owner: (any DeviceVerificationSession)? = nil,
            isCurrent: @escaping @MainActor () -> Bool = { true },
            begin: @escaping @MainActor () async throws -> any DeviceVerificationSession = {
                throw CancellationError()
            },
            cancel: @escaping @MainActor () async throws -> Void = {},
            cleanupFailure: @escaping @MainActor () -> Bool = { false },
            approve: @escaping @MainActor (Data, Data?) async throws -> any DeviceVerificationSession = { _, _ in
                throw CancellationError()
            },
            targets: @escaping @MainActor () async throws -> [DeviceLinkingTargetFfi] = { [] },
            verificationSupported: Bool = false, enrollmentSupported: Bool = false,
            enrollment: @escaping @MainActor () throws -> DeviceEnrollmentViewModel = {
                throw MarmotKitError.DeviceLinkingNotReady
            }
        ) {
            self.owner = owner
            self.isCurrent = isCurrent
            readCleanupFailure = cleanupFailure
            beginOriginal = begin
            cancelOriginal = cancel
            approveOriginal = approve
            readTargets = targets
            self.verificationSupported = verificationSupported
            self.enrollmentSupported = enrollmentSupported
            enrollmentOriginal = enrollment
        }

        func enrollmentTransport() throws -> DeviceEnrollmentViewModel {
            guard isActive, enrollmentSupported, owner != nil,
                snapshot?.phase == .verificationCompleteEnrollmentPending
            else { throw MarmotKitError.DeviceLinkingNotReady }
            let model = try enrollmentOriginal()
            guard isActive, model.isActive, model.enrollmentSupported else { throw MarmotKitError.DeviceLinkingClosed }
            return model
        }

        func begin() async throws { try await start(beginOriginal) }

        private func start(_ factory: @escaping @MainActor () async throws -> any DeviceVerificationSession)
            async throws
        {
            guard isActive, owner == nil, !isStarting else { throw CancellationError() }
            isStarting = true
            let task = Task { try await factory() }
            pending = task
            defer {
                isStarting = false
                pending = nil
            }
            // Session retains exact account/runtime ownership and cleans late SDK results.
            let original = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard isActive, !Task.isCancelled, !task.isCancelled else { throw CancellationError() }
            owner = original
        }

        func loadTargets() async throws {
            guard isActive else { throw CancellationError() }
            successfulTargetRead = false
            cachedTargets = []
            let id = UUID()
            targetReadID = id
            defer { if targetReadID == id { targetReadID = nil } }
            let values = try await readTargets()
            guard isActive, !Task.isCancelled, targetReadID == id else { throw CancellationError() }
            cachedTargets = values
            successfulTargetRead = true
        }

        // Presentation of an explicit attempt, never a bootstrap permission.
        var offersFirstDeviceSetupAttempt: Bool {
            verificationSupported && hasLoadedTargets && targets.isEmpty && owner == nil && !isStarting
        }
        func approveFirstDeviceSetup(request: Data) async throws {
            guard offersFirstDeviceSetupAttempt else { throw CancellationError() }
            let approveOriginal = self.approveOriginal
            try await start { try await approveOriginal(request, nil) }
        }

        func approve(request: Data, target: Data) async throws {
            guard hasLoadedTargets, targets.contains(where: { $0.selector == target }) else {
                throw CancellationError()
            }
            let approveOriginal = self.approveOriginal
            try await start { try await approveOriginal(request, target) }
        }

        private func originalOwner() throws -> any DeviceVerificationSession {
            guard isActive, let owner else { throw CancellationError() }
            return owner
        }

        private func checkOriginal(_ original: any DeviceVerificationSession) throws {
            guard isActive, !Task.isCancelled, owner === original else { throw CancellationError() }
        }

        func setupPacket() throws -> Data { try originalOwner().setupPacket() }

        func outgoingPackets() async throws -> [DeviceLinkingOutgoingPacketFfi] {
            let original = try originalOwner()
            let packets = try await original.outgoingPackets()
            try checkOriginal(original)
            return packets
        }

        func receiveSetupPacket(_ packet: Data) async throws {
            let original = try originalOwner()
            try await original.receiveSetupPacket(packet)
            try checkOriginal(original)
        }

        func receivePacket(_ packet: Data) async throws {
            let original = try originalOwner()
            try await original.receivePacket(packet)
            try checkOriginal(original)
        }

        func acknowledgePacket(_ id: String) async throws {
            let original = try originalOwner()
            try await original.acknowledgePacket(id)
            try checkOriginal(original)
        }

        func confirm(displayedRevision: UInt64) async throws {
            guard isActive, let original = owner else { throw CancellationError() }
            try await original.confirmComparison(displayedRevision: displayedRevision)
            guard isActive, !Task.isCancelled, owner === original else { throw CancellationError() }
        }
        func cancel() async throws {
            guard isActive else { throw CancellationError() }
            pending?.cancel()
            owner = nil
            try await cancelOriginal()
        }

        func invalidate() {
            retired = true
            successfulTargetRead = false
            targetReadID = nil
            cachedTargets = []
            pending?.cancel()
            owner = nil
        }
    }
    nonisolated enum DeviceVerificationPacketInput {
        enum Error: Swift.Error { case invalidPacket }
        static func decode(_ input: String) throws -> Data {
            let encoded = input.trimmingCharacters(in: .whitespacesAndNewlines)
            // Native resource bound only; the original SDK authenticates bytes and protocol.
            guard !encoded.isEmpty, encoded.utf8.count <= 65_536,
                let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded
            else { throw Error.invalidPacket }
            return bytes
        }
    }
#endif
