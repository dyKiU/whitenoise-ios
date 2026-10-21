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
        var needsAdmissionReconciliation = false
    }

    /// Logical observations never replace the ordinary conversation's authenticated proofs.
    @MainActor
    @Observable
    final class AccountConversationViewModel {
        let accountRef: String
        let groupIdHex: String
        let continuity: PairedConversationContinuity
        private(set) var snapshot: AccountConversationWindowSnapshotFfi? {
            get { continuity.snapshot }
            set { continuity.snapshot = newValue }
        }
        private(set) var pendingTexts: [String: PairedPendingText] {
            get { continuity.pendingTexts }
            set { continuity.pendingTexts = newValue }
        }
        private(set) var markdownByMessageId: [String: [MarkdownDisplayBlock]] {
            get { continuity.markdownByMessageId }
            set { continuity.markdownByMessageId = newValue }
        }
        private(set) var isLoading = false
        private(set) var error: AutomaticChatPresentationError?
        @ObservationIgnored private let observations: any AccountChatObserving
        @ObservationIgnored private let runtime: any PairedConversationSending
        @ObservationIgnored private var task: Task<Void, Never>?
        @ObservationIgnored private var pendingStatusTask: Task<Void, Never>?
        @ObservationIgnored private var owner: (any AccountConversationObserving)?
        @ObservationIgnored private var activeSnapshot: AccountConversationWindowSnapshotFfi?
        @ObservationIgnored private(set) var retired = false
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        @ObservationIgnored private let isPresentationCurrent: @MainActor () -> Bool
        var isCurrentOwner: Bool { !retired && !continuity.retired && isCurrent() }

        init(
            accountRef: String, groupIdHex: String, runtime: any PairedConversationSending,
            observations: any AccountChatObserving,
            continuity: PairedConversationContinuity? = nil,
            isPresentationCurrent: (@MainActor () -> Bool)? = nil,
            isCurrent: @escaping @MainActor () -> Bool = { true }
        ) {
            self.isCurrent = isCurrent
            self.isPresentationCurrent = isPresentationCurrent ?? isCurrent
            self.accountRef = accountRef
            self.groupIdHex = groupIdHex
            self.runtime = runtime
            self.observations = observations
            self.continuity = continuity ?? PairedConversationContinuity(accountRef: accountRef, groupIdHex: groupIdHex)
            precondition(self.continuity.accountRef == accountRef && self.continuity.groupIdHex == groupIdHex)
        }

        var pairedHeader: PairedChatSummaryFfi? {
            guard !continuity.retired, isPresentationCurrent(),
                let snapshot, case .pairedSource(let header) = snapshot.header else { return nil }
            return header
        }

        var pairedMessages: [PairedChatMessageFfi] {
            guard !continuity.retired, isPresentationCurrent() else { return [] }
            return snapshot?.rows.compactMap { row in
                if case .pairedSource(let value) = row { return value }
                return nil
            } ?? []
        }

        func start() {
            guard isCurrentOwner, task == nil else { return }
            isLoading = snapshot == nil
            task = Task { [weak self] in await self?.observe() }
        }

        func invalidate() {
            suspend()
            continuity.invalidate()
        }

        func suspend() {
            retired = true
            task?.cancel()
            task = nil
            pendingStatusTask?.cancel()
            pendingStatusTask = nil
            owner?.cancel()
            owner = nil
            activeSnapshot = nil
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
                let accepted = try await submit(try pendingText(token))
                // A late admission may already be durable. Keep its correlation across a runtime handoff.
                guard !continuity.retired, isPresentationCurrent() else {
                    throw AutomaticChatPresentationError.retired
                }
                guard accepted.clientToken == token else { throw AutomaticChatPresentationError.invalidSnapshot }
                // Native admission returns the canonical ID; the client token is never an event ID.
                pendingTexts[token]?.acceptedMessageIdHex = accepted.messageIdHex.isEmpty ? nil : accepted.messageIdHex
                if continuity.draft == text { continuity.draft = "" }
                reconcileObservedPendingTexts()
                startPendingStatusObservation()
                return accepted
            } catch {
                if isCurrentOwner, owner === original {
                    pendingTexts[token] = nil
                } else if !continuity.retired {
                    pendingTexts[token]?.needsAdmissionReconciliation = true
                }
                throw error
            }
        }

        private func pendingText(_ token: String) throws -> PairedPendingText {
            guard let pending = pendingTexts[token] else { throw AutomaticChatPresentationError.retired }
            return pending
        }

        private func submit(_ pending: PairedPendingText) async throws -> LocalSendAcceptanceFfi {
            if let target = pending.replyToMessageIdHex {
                return try await runtime.replyWithClientToken(
                    accountRef: accountRef, groupIdHex: groupIdHex, targetMessageId: target,
                    text: pending.text, clientToken: pending.id)
            }
            return try await runtime.sendTextWithClientToken(
                accountRef: accountRef, groupIdHex: groupIdHex, text: pending.text, clientToken: pending.id)
        }

        private func startPendingStatusObservation() {
            guard isCurrentOwner, pendingStatusTask == nil, !pendingTexts.isEmpty else { return }
            pendingStatusTask = Task { [weak self] in
                guard let self else { return }
                defer { pendingStatusTask = nil }
                while isCurrentOwner, !Task.isCancelled, !pendingTexts.isEmpty {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    await refreshPendingStatus()
                }
            }
        }

        func refreshPendingStatus() async {
            guard isCurrentOwner, let original = owner else { return }
            let account = accountRef
            let group = groupIdHex
            let client = runtime
            for token in Array(pendingTexts.keys) {
                var reconcilingAdmission = false
                do {
                    let status = try await client.localSendStatus(
                        accountRef: account, groupIdHex: group, clientToken: token)
                    guard isCurrentOwner, !Task.isCancelled, owner === original else { return }
                    pendingTexts[token]?.status = status
                    if case .completed(let summary)? = status, summary.messageIds.count == 1 {
                        pendingTexts[token]?.acceptedMessageIdHex = summary.messageIds[0]
                    }
                    if status == nil, pendingTexts[token]?.acceptedMessageIdHex == nil,
                        pendingTexts[token]?.needsAdmissionReconciliation == true
                    {
                        let pending = try pendingText(token)
                        pendingTexts[token]?.needsAdmissionReconciliation = false
                        reconcilingAdmission = true
                        // Retry only an interrupted admission, with its original idempotency token.
                        let accepted = try await submit(pending)
                        guard !continuity.retired, isPresentationCurrent(), accepted.clientToken == token else { return }
                        pendingTexts[token]?.acceptedMessageIdHex = accepted.messageIdHex.isEmpty ? nil : accepted.messageIdHex
                        if continuity.draft == pending.text { continuity.draft = "" }
                    }
                } catch {
                    guard isCurrentOwner, owner === original else {
                        if !continuity.retired { pendingTexts[token]?.needsAdmissionReconciliation = true }
                        return
                    }
                    if reconcilingAdmission {
                        if error is CancellationError
                            || (error as? MarmotKitError)?.isTransientStartupReadinessFailure == true
                        {
                            pendingTexts[token]?.needsAdmissionReconciliation = true
                        } else {
                            pendingTexts[token]?.status = .rejected
                        }
                    }
                    self.error = .unavailable
                }
            }
            reconcileObservedPendingTexts()
        }

        private func observe() async {
            defer {
                task = nil
                pendingStatusTask?.cancel()
                pendingStatusTask = nil
                owner?.cancel()
                owner = nil
                activeSnapshot = nil
                isLoading = false
                // A finished foreground owner must not be reused after an inactive/active transition.
                retired = true
            }
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
                startPendingStatusObservation()
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
                    self.error = .unavailable
                    isLoading = false
                }
            }
        }

        private func install(_ replacement: AccountConversationWindowSnapshotFfi) throws {
            guard !replacement.generation.isEmpty, replacement.rows.count <= 128 else {
                throw AutomaticChatPresentationError.invalidSnapshot
            }
            if let current = activeSnapshot {
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
            activeSnapshot = replacement
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
            activeSnapshot = nil
            isLoading = false
            error = .unavailable
        }
    }
#endif
