#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    nonisolated enum SelectedChatPacketInput {
        static func check(_ packet: Data) throws {
            guard !packet.isEmpty, packet.count <= 16_384 else { throw MarmotKitError.SelectedChatCopyInvalidPacket }
        }
        static func decode(_ input: String) throws -> Data {
            let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 21_848, let packet = Data(base64Encoded: value),
                packet.base64EncodedString() == value
            else { throw MarmotKitError.SelectedChatCopyInvalidPacket }
            try check(packet)
            return packet
        }
    }

    /// Actions use one already-owned original. Display records never recreate a request.
    @MainActor @Observable final class SelectedChatCopyViewModel {
        @ObservationIgnored private let original: SelectedChatCopyScope
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        private var retired = false
        private var currentSnapshot: SelectedChatCopySnapshotFfi?
        private var outgoingValue: String?
        private var lastActionError: Error?
        private(set) var isWorking = false
        var isActive: Bool { !retired && original.isActive && isCurrent() }
        var snapshot: SelectedChatCopySnapshotFfi? { isActive ? currentSnapshot : nil }
        var outgoingPacket: String? { isActive ? outgoingValue : nil }
        var actionError: Error? { isActive ? lastActionError : nil }
        var cleanupError: Error? { original.cleanupError }
        enum Action { case request, consent, offer, continueCopy }

        init(original: SelectedChatCopyScope, isCurrent: @escaping @MainActor () -> Bool) {
            self.original = original
            self.isCurrent = isCurrent
        }
        private func checkActive() throws {
            guard isActive, !Task.isCancelled else { throw MarmotKitError.SelectedChatCopyClosed }
        }
        func refresh() async throws {
            try checkActive()
            let value: SelectedChatCopySnapshotFfi
            do { value = try await original.snapshot() } catch {
                currentSnapshot = nil
                outgoingValue = nil
                throw error
            }
            try checkActive()
            guard value.siblingCount <= 128, value.consentingSiblingCount <= value.siblingCount,
                value.offeredSiblingCount <= value.siblingCount
            else {
                currentSnapshot = nil
                outgoingValue = nil
                throw MarmotKitError.SelectedChatCopyNotReady
            }
            if currentSnapshot?.revision != value.revision || value.phase != .awaitingSiblingConsent {
                outgoingValue = nil
            }
            currentSnapshot = value
        }
        private func checkRevision(_ revision: UInt64) throws {
            try checkActive()
            guard snapshot?.phase == .awaitingSiblingConsent, snapshot?.revision == revision else {
                throw MarmotKitError.SelectedChatCopyStaleRevision
            }
        }
        func exportRequest(displayedRevision: UInt64) async throws {
            try await perform(.request, displayedRevision: displayedRevision)
        }
        func perform(_ action: Action, displayedRevision: UInt64, input: String = "") async throws {
            try checkRevision(displayedRevision)
            guard !isWorking else { throw MarmotKitError.SelectedChatCopyBusy }
            isWorking = true
            outgoingValue = nil
            lastActionError = nil
            defer { isWorking = false }
            do {
                switch action {
                case .request:
                    let packet = try await original.requestPacket(displayedRevision: displayedRevision)
                    try checkRevision(displayedRevision)
                    try SelectedChatPacketInput.check(packet)
                    outgoingValue = packet.base64EncodedString()
                case .consent:
                    try await original.receiveConsentPacket(
                        displayedRevision: displayedRevision, packet: SelectedChatPacketInput.decode(input))
                    try await refresh()
                case .offer:
                    try await original.receiveOfferPacket(
                        displayedRevision: displayedRevision, packet: SelectedChatPacketInput.decode(input))
                    try await refresh()
                case .continueCopy:
                    try await original.continueCopy(displayedRevision: displayedRevision)
                    try await refresh()
                }
                try checkActive()
            } catch {
                lastActionError = error
                throw error
            }
        }
        func invalidate() {
            retired = true
            currentSnapshot = nil
            outgoingValue = nil
            lastActionError = nil
        }
        func cancel() async throws {
            invalidate()
            try await original.cancel()
        }
    }

    /// Ordinary-chat consent is independent of protected-device enrollment approval.
    @MainActor @Observable final class SelectedChatConsentViewModel {
        @ObservationIgnored private let original: SelectedChatConsentScope
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        private var retired = false
        private var currentSnapshot: SelectedChatConsentSnapshotFfi?
        private var reviewedRevision: UInt64?
        private var outgoingValue: String?
        private var lastActionError: Error?
        private(set) var isWorking = false
        var isActive: Bool { !retired && original.isActive && isCurrent() }
        var snapshot: SelectedChatConsentSnapshotFfi? { isActive ? currentSnapshot : nil }
        var outgoingPacket: String? { isActive ? outgoingValue : nil }
        var actionError: Error? { isActive ? lastActionError : nil }
        var cleanupError: Error? { original.cleanupError }
        enum Action { case approve, response, offer }

        init(original: SelectedChatConsentScope, isCurrent: @escaping @MainActor () -> Bool) {
            self.original = original
            self.isCurrent = isCurrent
        }
        private func checkActive() throws {
            guard isActive, !Task.isCancelled else { throw MarmotKitError.SelectedChatCopyClosed }
        }
        func refresh() async throws {
            try checkActive()
            let value: SelectedChatConsentSnapshotFfi
            do { value = try await original.snapshot() } catch {
                currentSnapshot = nil
                reviewedRevision = nil
                outgoingValue = nil
                throw error
            }
            try checkActive()
            guard !value.chatSelector.isEmpty, value.chatSelector.count <= 256 else {
                reviewedRevision = nil
                currentSnapshot = nil
                outgoingValue = nil
                throw MarmotKitError.SelectedChatCopyNotReady
            }
            if currentSnapshot?.revision != value.revision || value.phase != .approved { outgoingValue = nil }
            currentSnapshot = value
            reviewedRevision = value.phase == .awaitingApproval ? value.revision : nil
        }
        private func checkRevision(_ revision: UInt64, phase: SelectedChatConsentPhaseFfi) throws {
            try checkActive()
            guard snapshot?.phase == phase, snapshot?.revision == revision else {
                throw MarmotKitError.SelectedChatCopyStaleRevision
            }
        }
        func approveReviewed(displayedRevision: UInt64) async throws {
            try await perform(.approve, displayedRevision: displayedRevision)
        }
        func perform(_ action: Action, displayedRevision: UInt64) async throws {
            try checkActive()
            guard !isWorking else { throw MarmotKitError.SelectedChatCopyBusy }
            isWorking = true
            outgoingValue = nil
            lastActionError = nil
            defer { isWorking = false }
            do {
                switch action {
                case .approve:
                    try checkRevision(displayedRevision, phase: .awaitingApproval)
                    guard reviewedRevision == displayedRevision else {
                        throw MarmotKitError.SelectedChatCopyStaleRevision
                    }
                    reviewedRevision = nil
                    try await original.approve(displayedRevision: displayedRevision)
                    try await refresh()
                case .response, .offer:
                    try checkRevision(displayedRevision, phase: .approved)
                    let packet: Data
                    if action == .response {
                        packet = try await original.responsePacket(displayedRevision: displayedRevision)
                    } else {
                        packet = try await original.offerPacket(displayedRevision: displayedRevision)
                    }
                    try checkRevision(displayedRevision, phase: .approved)
                    try SelectedChatPacketInput.check(packet)
                    outgoingValue = packet.base64EncodedString()
                }
                try checkActive()
            } catch {
                lastActionError = error
                throw error
            }
        }
        func invalidate() {
            retired = true
            currentSnapshot = nil
            reviewedRevision = nil
            outgoingValue = nil
            lastActionError = nil
        }
        func cancel() async throws {
            invalidate()
            try await original.cancel()
        }
    }
#endif
