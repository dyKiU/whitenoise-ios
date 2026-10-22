import MarmotKit
import SwiftUI

#if WN_EXPERIMENTAL_DEVICE_SYNC
    struct AutomaticConversationScreen: View {
        let model: AccountConversationViewModel?
        @Environment(AppState.self) private var appState
        @State private var blockedUsers = BlockedUsersModel()

        var body: some View {
            AutomaticConversationContent(
                model: model, blockedAuthors: blockedUsers.blockedAccountIds,
                localAccountIdHex: appState.activeAccount?.accountIdHex,
                blockedPeerNpub: blockedPeerNpub,
                canUnblock: blockedUsers.canMutate, isUnblocking: blockedUsers.isSaving,
                onUnblock: {
                    guard let model, let peer = model.pairedHeader?.directPeerAccountIdHex else { return }
                    Task {
                        guard model.isCurrentOwner, model.accountRef == appState.activeAccountRef else { return }
                        await blockedUsers.setBlocked(false, userId: peer, using: appState)
                    }
                },
                title: model?.pairedHeader.map { row in
                    AutomaticChatListPresentation.title(
                        row,
                        peerDisplayName: row.directPeerAccountIdHex.flatMap {
                            appState.cachedKnownDisplayName(forAccountIdHex: $0)
                        })
                } ?? L10n.string("Unnamed group")
            )
            .id(appState.activeAccountRef)
            .task(id: appState.automaticChatOwner) {
                await blockedUsers.run(using: appState, target: nil)
            }
            .task(
                id: AutomaticChatProfileScope(
                    owner: appState.automaticChatOwner,
                    peerAccountIds: model?.pairedHeader?.directPeerAccountIdHex.map { [$0] } ?? [])
            ) {
                guard !Task.isCancelled, let model, model.isCurrentOwner,
                    model.accountRef == appState.activeAccountRef,
                    let peer = model.pairedHeader?.directPeerAccountIdHex
                else { return }
                _ = appState.knownDisplayName(forAccountIdHex: peer)
            }

        }

        private var blockedPeerNpub: String? {
            guard let peer = model?.pairedHeader?.directPeerAccountIdHex,
                blockedUsers.isConfirmedBlocked(peer, accountRef: appState.activeAccountRef)
            else { return nil }
            return IdentityPresentation.canonicalNpub(accountIdHex: peer)
        }
    }

    private struct AutomaticConversationContent: View {
        let model: AccountConversationViewModel?
        let blockedAuthors: Set<String>
        var localAccountIdHex: String? = nil
        var blockedPeerNpub: String? = nil
        var canUnblock = false
        var isUnblocking = false
        var onUnblock: () -> Void = {}
        let title: String
        @Environment(\.dismiss) private var dismiss
        private var text: String {
            get { model?.continuity.draft ?? "" }
            nonmutating set { model?.continuity.draft = newValue }
        }
        @State private var sending = false
        @State private var sendFailed = false
        @State private var scrollPosition = ScrollPosition(edge: .bottom)
        @State private var followsNewest = true
        @State private var userScrolling = false

        private func statusLabel(_ status: LocalSendStatusFfi?) -> LocalizedStringKey {
            switch status {
            case .completed: "Sent"
            case .rejected: "Send failed"
            case .engineOwned: "Sending…"
            case .queued, nil: "Pending"
            }
        }

        var body: some View {
            ScrollView {
                LazyVStack(spacing: 6) {
                    if model?.isLoading == true { ProgressView() }
                    if model?.error != nil { Text("Chat unavailable") }
                    if model?.snapshot?.nextBefore != nil {
                        Button("Load older messages") { Task { await model?.loadOlder() } }
                    }
                    ForEach(
                        PairedTimelineEntry.make(messages: model?.pairedMessages ?? [], blockedAuthors: blockedAuthors)
                    ) { entry in
                        if let day = entry.dayStart {
                            TimelineInlineDateHeader(heading: .init(id: entry.id, day: day))
                        }
                        AutomaticPairedMessageRow(
                            message: entry.message,
                            markdownBlocks: model?.markdownByMessageId[entry.id],
                            localAccountIdHex: localAccountIdHex,
                            showsSenderName: model?.pairedHeader?.directPeerAccountIdHex == nil)
                    }
                    ForEach((model.map { Array($0.pendingTexts.values) } ?? []).sorted { $0.createdAt < $1.createdAt })
                    {
                        pending in
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(verbatim: pending.text)
                                .padding(.horizontal, ChatBubbleMetrics.horizontalInset)
                                .padding(.vertical, ChatBubbleMetrics.verticalInset)
                                .foregroundStyle(MessageBubblePalette.foreground(isFromMe: true))
                                .background(MessageBubblePalette.background(isFromMe: true))
                                .clipShape(.rect(cornerRadius: ChatBubbleMetrics.cornerRadius, style: .continuous))
                            Text(statusLabel(pending.status)).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: ChatBubbleMetrics.regularMaximumWidth, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.leading, ChatBubbleMetrics.compactOppositeInset)
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollPosition($scrollPosition)
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 80
            } action: { _, atBottom in
                if userScrolling { followsNewest = atBottom }
            }
            .onChange(of: model?.snapshot?.sequence) { _, _ in
                if followsNewest { scrollPosition.scrollTo(edge: .bottom) }
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConversationHeaderBar(isSelectingMessages: false, onBack: { dismiss() }, onClose: {}) {
                    HStack(spacing: 10) {
                        AvatarBubble(
                            seed: model?.pairedHeader?.directPeerAccountIdHex ?? model?.groupIdHex ?? "",
                            title: title, pictureURL: nil
                        )
                        .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: title).font(.headline).lineLimit(1)
                            Text("Shared from a linked device").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let blockedPeerNpub {
                    BlockedConversationNotice(
                        npub: blockedPeerNpub, canUnblock: canUnblock,
                        isUnblocking: isUnblocking, onUnblock: onUnblock)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if sendFailed { Text("Send failed").foregroundStyle(.red).font(.caption) }
                        ComposerBar(
                            draft: Binding(get: { text }, set: { text = $0 }),
                            isSending: sending, hasAttachments: false, audioDraft: nil,
                            preparedAttachments: [], replyPreview: nil, mediaEnabled: false,
                            disabledMessage: model?.isCurrentOwner == true && model?.pairedHeader != nil
                                ? nil : L10n.string("Chat unavailable"),
                            voiceRecordingActive: false, voiceRecordingLocked: false,
                            voiceRecordingSamples: [], voiceRecordingDurationSeconds: 0,
                            focusRequest: 0, dismissRequest: 0, mentionCandidates: [],
                            voiceMessagesEnabled: false, cameraAvailable: false, gifsAvailable: false,
                            onTakePhoto: {}, onPhotoLibrary: {}, onAttachFile: {}, onShareLocation: {},
                            onShareContact: {}, onSearchGIFs: {}, onPasteImage: { _ in },
                            onRemoveAudioDraft: { _ in }, onRemovePreparedAttachment: { _ in },
                            onPreviewPreparedMedia: { _ in }, onCancelReply: {}, onCancelVoiceRecording: {},
                            onStopVoiceRecording: {}, onVoicePressBegan: {}, onVoiceDragChanged: { _ in },
                            onVoicePressEnded: {}, onMentionSelect: { _ in }, onSend: send
                        )
                    }
                }
            }
        }

        private func send() {
            guard let model, !sending, blockedPeerNpub == nil else { return }
            let captured = text
            sending = true
            sendFailed = false
            Task {
                defer { sending = false }
                do {
                    _ = try await model.sendText(captured)
                    guard model.isCurrentOwner else { return }
                    if text == captured { text = "" }
                    followsNewest = true
                    scrollPosition.scrollTo(edge: .bottom)
                    await model.refreshPendingStatus()
                } catch {
                    guard model.isCurrentOwner else { return }
                    sendFailed = true
                }
            }
        }
    }

    struct AutomaticPairedMessageRow: View {
        let message: PairedChatMessageFfi?
        var markdownBlocks: [MarkdownDisplayBlock]? = nil
        var localAccountIdHex: String? = nil
        var showsSenderName = true
        @Environment(AppState.self) private var appState
        @Environment(\.horizontalSizeClass) private var sizeClass
        @Environment(\.openURL) private var openURL
        @State private var pendingExternalLink: PendingMessageExternalLink?

        var body: some View {
            if let message {
                let presentation = PairedMessagePresentation(
                    message: message, localAccountIdHex: localAccountIdHex)
                TimelineView(.periodic(from: .now, by: 1)) { clock in
                    if presentation.isVisible(at: clock.date) {
                        HStack(alignment: .bottom, spacing: 6) {
                            if presentation.isOutgoing {
                                Spacer(
                                    minLength: sizeClass == .regular
                                        ? ChatBubbleMetrics.regularOppositeInset
                                        : ChatBubbleMetrics.compactOppositeInset)
                            }
                            VStack(alignment: presentation.isOutgoing ? .trailing : .leading, spacing: 2) {
                                if !presentation.isOutgoing, showsSenderName {
                                    Text(appState.displayName(forAccountIdHex: message.authorHex))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(WNIdentityPalette.color(for: message.authorHex))
                                        .padding(.leading, 12)
                                }
                                MessageBubbleChromeLayout(isFromMe: presentation.isOutgoing) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        if presentation.isDeleted {
                                            Text("Message deleted").italic()
                                        } else if message.canonicalChat {
                                            if let markdownBlocks {
                                                MarkdownMessageView(blocks: markdownBlocks)
                                                    .tint(
                                                        MessageBubblePalette.foreground(
                                                            isFromMe: presentation.isOutgoing)
                                                    )
                                                    .environment(\.openURL, OpenURLAction(handler: handleMessageLink))
                                                    .environment(
                                                        \.copyMessageLink,
                                                        MessageLinkCopyAction { [appState] target in
                                                            MessageLinkCopyAction.copy(target, presenting: appState)
                                                        })
                                            } else {
                                                Text(verbatim: ContentSanitizer.textRun(presentation.text))
                                                    .textSelection(.enabled)
                                            }
                                        } else {
                                            Text("Unsupported message")
                                        }
                                        if presentation.showsUnavailableAttachment {
                                            Text("Attachment unavailable").font(.caption)
                                        }
                                    }
                                    .padding(.horizontal, ChatBubbleMetrics.horizontalInset)
                                    .padding(.vertical, ChatBubbleMetrics.verticalInset)
                                    .foregroundStyle(
                                        MessageBubblePalette.foreground(isFromMe: presentation.isOutgoing)
                                    )
                                    .background(MessageBubblePalette.background(isFromMe: presentation.isOutgoing))
                                    .clipShape(
                                        .rect(cornerRadius: ChatBubbleMetrics.cornerRadius, style: .continuous))
                                    HStack {
                                        if presentation.isOutgoing { Spacer(minLength: 8) }
                                        MessageMetadataFooter(
                                            time: MessageBubble.timeLabel(recordedAt: presentation.timestamp),
                                            isEdited: presentation.isEdited, status: .received,
                                            isFromMe: presentation.isOutgoing,
                                            showsDeliveryStatus: false)
                                        if !presentation.isOutgoing { Spacer(minLength: 8) }
                                    }
                                    .padding(.horizontal, ChatBubbleMetrics.horizontalInset)
                                }
                            }
                            .frame(
                                maxWidth: sizeClass == .regular ? ChatBubbleMetrics.regularMaximumWidth : nil,
                                alignment: presentation.isOutgoing ? .trailing : .leading)
                            if !presentation.isOutgoing {
                                Spacer(
                                    minLength: sizeClass == .regular
                                        ? ChatBubbleMetrics.regularOppositeInset
                                        : ChatBubbleMetrics.compactOppositeInset)
                            }
                        }
                        .padding(.horizontal, 12)
                        .sheet(item: $pendingExternalLink) { link in
                            MessageLinkActionSheet(
                                url: link.url,
                                onOpen: {
                                    pendingExternalLink = nil
                                    openURL(link.url)
                                },
                                onCopy: {
                                    pendingExternalLink = nil
                                    if let target = MessageLinkTarget(url: link.url) {
                                        MessageLinkCopyAction.copy(target, presenting: appState)
                                    }
                                },
                                onCancel: { pendingExternalLink = nil }
                            )
                            .appAppearance()
                        }
                    }
                }
            }
        }

        private func handleMessageLink(_ url: URL) -> OpenURLAction.Result {
            switch MessageLinkPolicy.action(for: url) {
            case .openProfile(let npub):
                appState.presentProfile(npub: npub)
                return .handled
            case .openChat(let groupIdHex):
                appState.presentChat(groupIdHex: groupIdHex)
                return .handled
            case .confirmExternal(let external):
                pendingExternalLink = PendingMessageExternalLink(url: external)
                return .handled
            case .blocked:
                return .discarded
            }
        }
    }

    #Preview("Shared conversation") {
        NavigationStack {
            AutomaticConversationContent(
                model: nil, blockedAuthors: [], title: L10n.string("Unnamed group"))
        }
    }

    #Preview("Shared message") { AutomaticPairedMessageRow(message: nil) }
    #Preview("Shared conversation screen") {
        AutomaticConversationScreen(model: nil).environment(AppState())
    }
#endif
