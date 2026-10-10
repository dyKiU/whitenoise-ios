#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    /// Account-owned presentation of independent ordinary-chat copy requests and consent.
    @MainActor @Observable final class SelectedChatTransferViewModel {
        @ObservationIgnored private let beginOriginal:
            @MainActor (String, Data) async throws -> SelectedChatCopyViewModel
        @ObservationIgnored private let receiveOriginal: @MainActor (Data) async throws -> SelectedChatConsentViewModel
        @ObservationIgnored private let readTargets: @MainActor () async throws -> [DeviceLinkingTargetFfi]
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        private var retired = false
        private var currentCopy: SelectedChatCopyViewModel?
        private var currentGroupIdHex: String?
        private var currentConsent: SelectedChatConsentViewModel?
        private var currentTargets: [DeviceLinkingTargetFfi] = []
        private(set) var isWorking = false
        var isActive: Bool { !retired && isCurrent() }
        var copyGroupIdHex: String? { isActive ? currentGroupIdHex : nil }
        var copy: SelectedChatCopyViewModel? { isActive ? currentCopy : nil }
        var consent: SelectedChatConsentViewModel? { isActive ? currentConsent : nil }
        var targets: [DeviceLinkingTargetFfi] { isActive ? currentTargets : [] }

        init(
            begin: @escaping @MainActor (String, Data) async throws -> SelectedChatCopyViewModel,
            receive: @escaping @MainActor (Data) async throws -> SelectedChatConsentViewModel,
            targets: @escaping @MainActor () async throws -> [DeviceLinkingTargetFfi],
            isCurrent: @escaping @MainActor () -> Bool
        ) {
            beginOriginal = begin
            receiveOriginal = receive
            readTargets = targets
            self.isCurrent = isCurrent
        }

        private func checkActive() throws {
            try Task.checkCancellation()
            guard isActive else { throw MarmotKitError.SelectedChatCopyClosed }
        }
        private func startAction() throws {
            try checkActive()
            guard !isWorking else { throw MarmotKitError.SelectedChatCopyBusy }
            isWorking = true
        }
        func loadTargets() async throws {
            try startAction()
            defer { isWorking = false }
            currentTargets = []
            let values = try await readTargets()
            try checkActive()
            guard values.count <= 128,
                values.allSatisfy({ !$0.selector.isEmpty && $0.selector.count <= 256 })
            else { throw MarmotKitError.SelectedChatCopyNotReady }
            currentTargets = values
        }
        func begin(groupIdHex: String, linkedRosterSelector: Data) async throws {
            try startAction()
            defer { isWorking = false }
            guard currentCopy?.isActive != true else { throw MarmotKitError.SelectedChatCopyBusy }
            guard !groupIdHex.isEmpty, groupIdHex.utf8.count <= 512,
                currentTargets.contains(where: { $0.selector == linkedRosterSelector })
            else { throw MarmotKitError.SelectedChatCopyNotReady }
            let model = try await beginOriginal(groupIdHex, linkedRosterSelector)
            currentCopy = model
            currentGroupIdHex = groupIdHex
            try checkActive()
            try await model.refresh()
            try checkActive()
        }
        func receive(input: String) async throws {
            try startAction()
            defer { isWorking = false }
            guard currentConsent?.isActive != true else { throw MarmotKitError.SelectedChatCopyBusy }
            let model = try await receiveOriginal(SelectedChatPacketInput.decode(input))
            currentConsent = model
            try checkActive()
            try await model.refresh()
            try checkActive()
        }
        func invalidate() {
            retired = true
            currentGroupIdHex = nil
            currentTargets = []
            currentCopy?.invalidate()
            currentConsent?.invalidate()
        }
    }
#endif
