import Foundation
import MarmotKit
import Observation

#if WN_EXPERIMENTAL_DEVICE_SYNC
    struct PairedPendingText: Identifiable {
        let id: String
        let createdAt = Date()
        let text: String
        let replyToMessageIdHex: String?
        var acceptedMessageIdHex: String?
        var status: LocalSendStatusFfi?
    }

    /// Logical observations never replace the ordinary conversation's authenticated proofs.
    @MainActor
    @Observable
    final class AccountConversationViewModel {
        let accountRef: String
        let groupIdHex: String
        private(set) var snapshot: AccountConversationWindowSnapshotFfi?
        private(set) var pendingTexts: [String: PairedPendingText] = [:]
        private(set) var markdownByMessageId: [String: [MarkdownDisplayBlock]] = [:]
        private(set) var isLoading = false
        private(set) var error: AutomaticChatPresentationError?
        @ObservationIgnored private let observations: any AccountChatObserving
        @ObservationIgnored private let runtime: any PairedConversationSending
        @ObservationIgnored private var task: Task<Void, Never>?
        @ObservationIgnored private var owner: (any AccountConversationObserving)?
        @ObservationIgnored private var retired = false
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        var isCurrentOwner: Bool { !retired && isCurrent() }

        init(
            accountRef: String, groupIdHex: String, runtime: any PairedConversationSending,
            observations: any AccountChatObserving,
            isCurrent: @escaping @MainActor () -> Bool = { true }
        ) {
            self.isCurrent = isCurrent
            self.accountRef = accountRef
            self.groupIdHex = groupIdHex
            self.runtime = runtime
            self.observations = observations
        }

        var pairedHeader: PairedChatSummaryFfi? {
            guard isCurrentOwner, let snapshot, case .pairedSource(let header) = snapshot.header else { return nil }
            return header
        }

        var pairedMessages: [PairedChatMessageFfi] {
            guard isCurrentOwner else { return [] }
            return snapshot?.rows.compactMap { row in
                if case .pairedSource(let value) = row { return value }
                return nil
            } ?? []
        }

        func start() {
            guard isCurrentOwner, task == nil else { return }
            isLoading = true
            task = Task { [weak self] in await self?.observe() }
        }

        func invalidate() {
            retired = true
            task?.cancel()
            task = nil
            owner?.cancel()
            owner = nil
            snapshot = nil
            markdownByMessageId = [:]
            pendingTexts = [:]
            isLoading = false
            error = nil
        }

        func loadOlder() async {
            guard isCurrentOwner, let original = owner, let current = snapshot, let cursor = current.nextBefore else {
                return
            }
            do {
                let replacement = try await original.olderPage(sequence: current.sequence, before: cursor)
                guard isCurrentOwner, !Task.isCancelled, owner === original else { return }
                try install(replacement)
            } catch {
                guard isCurrentOwner, owner === original else { return }
                refuse(original)
            }
        }

        /// The normal client-token admission route performs Core authorization. No direct SDK send.
        @discardableResult
        func sendText(_ text: String, replyingTo messageIdHex: String? = nil) async throws -> LocalSendAcceptanceFfi {
            guard isCurrentOwner, !Task.isCancelled, pairedHeader != nil, let original = owner,
                pendingTexts.count < 128
            else { throw AutomaticChatPresentationError.retired }
            let token = UUID().uuidString.lowercased()
            pendingTexts[token] = PairedPendingText(id: token, text: text, replyToMessageIdHex: messageIdHex)
            do {
                let accepted: LocalSendAcceptanceFfi
                if let messageIdHex {
                    accepted = try await runtime.replyWithClientToken(
                        accountRef: accountRef, groupIdHex: groupIdHex, targetMessageId: messageIdHex,
                        text: text, clientToken: token)
                } else {
                    accepted = try await runtime.sendTextWithClientToken(
                        accountRef: accountRef, groupIdHex: groupIdHex, text: text, clientToken: token)
                }
                guard isCurrentOwner, !Task.isCancelled, owner === original else {
                    throw AutomaticChatPresentationError.retired
                }
                guard accepted.clientToken == token else { throw AutomaticChatPresentationError.invalidSnapshot }
                // Native admission returns the canonical ID; the client token is never an event ID.
                pendingTexts[token]?.acceptedMessageIdHex = accepted.messageIdHex.isEmpty ? nil : accepted.messageIdHex
                reconcileObservedPendingTexts()
                return accepted
            } catch {
                pendingTexts[token] = nil
                throw error
            }
        }

        func refreshPendingStatus() async {
            guard isCurrentOwner, let original = owner else { return }
            let account = accountRef
            let group = groupIdHex
            let client = runtime
            for token in Array(pendingTexts.keys) {
                do {
                    let status = try await client.localSendStatus(
                        accountRef: account, groupIdHex: group, clientToken: token)
                    guard isCurrentOwner, !Task.isCancelled, owner === original else { return }
                    pendingTexts[token]?.status = status
                } catch {
                    guard isCurrentOwner, owner === original else { return }
                    self.error = .unavailable
                }
            }
        }

        private func observe() async {
            while isCurrentOwner, !Task.isCancelled {
                await observeOnce()
                guard isCurrentOwner, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }

        private func observeOnce() async {
            do {
                let original = try await observations.openAccountConversation(
                    accountRef: accountRef, groupIdHex: groupIdHex, initialRows: 128)
                guard isCurrentOwner, !Task.isCancelled else {
                    original.cancel()
                    return
                }
                owner = original
                guard let initial = original.snapshot() else { throw AutomaticChatPresentationError.invalidSnapshot }
                try install(initial)
                await refreshPendingStatus()
                while let replacement = try await original.next() {
                    guard isCurrentOwner, !Task.isCancelled, owner === original else {
                        original.cancel()
                        return
                    }
                    try install(replacement)
                    await refreshPendingStatus()
                }
                guard isCurrentOwner, owner === original else { return }
                refuse(original)
            } catch {
                guard isCurrentOwner, !Task.isCancelled else { return }
                if let original = owner {
                    refuse(original)
                } else {
                    snapshot = nil
                    self.error = .unavailable
                    isLoading = false
                }
            }
        }

        private func install(_ replacement: AccountConversationWindowSnapshotFfi) throws {
            guard !replacement.generation.isEmpty, replacement.rows.count <= 128 else {
                throw AutomaticChatPresentationError.invalidSnapshot
            }
            if let current = snapshot {
                guard replacement.generation == current.generation, replacement.sequence >= current.sequence else {
                    throw AutomaticChatPresentationError.invalidSnapshot
                }
                if replacement.sequence == current.sequence { return }
            }
            if case .pairedSource(let header) = replacement.header, header.groupIdHex != groupIdHex {
                throw AutomaticChatPresentationError.invalidSnapshot
            }
            var markdown: [String: [MarkdownDisplayBlock]] = [:]
            for row in replacement.rows {
                if case .pairedSource(let message) = row,
                    message.canonicalChat, !message.deleted, !message.contentTokens.blocks.isEmpty
                {
                    markdown[message.messageIdHex] = MarkdownMessageBuilder.displayBlocks(for: message.contentTokens)
                }
            }
            markdownByMessageId = markdown
            snapshot = replacement
            reconcileObservedPendingTexts()
            isLoading = false
            error = nil
        }

        private func reconcileObservedPendingTexts() {
            let observedIds = Set(
                (snapshot?.rows ?? []).compactMap { row -> String? in
                    if case .pairedSource(let message) = row { return message.messageIdHex }
                    return nil
                })
            pendingTexts = pendingTexts.filter { _, pending in
                guard let eventId = pending.acceptedMessageIdHex else { return true }
                return !observedIds.contains(eventId)
            }
        }

        private func refuse(_ original: any AccountConversationObserving) {
            original.cancel()
            owner = nil
            snapshot = nil
            markdownByMessageId = [:]
            pendingTexts = [:]
            isLoading = false
            error = .unavailable
        }
    }
#endif
