import CryptoKit
import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

/// Binding fixture for sending MDK 0.12.0 custom emoji: a peer's emoji puts
/// `:party:` in the chat's catalog, then a tagged kind-9 goes through the
/// real `sendTaggedMedia` of a live test runtime and is read back through the
/// conversation window and the rendering resolver. The peer row is synthetic, so its retained bytes and
/// the Blossom upload are simulated (the runtime is offline); the uploaded
/// reference is shaped like a real one for the group's epoch.
@MainActor
@Suite(.serialized)
struct CustomEmojiSendingFixtureTests {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func taggedMessageRoundTripsThroughTheRuntime() async throws {
        let client = try MarmotClient.testClient()
        try await client.startRuntime()
        let watchdog = MarmotFixtureWatchdog.start("Custom emoji send fixture exceeded its deadline", breaking: client)
        defer { watchdog.cancel() }
        // CUSTOM_EMOJI_DIAGNOSTIC_BEGIN
        enum DiagnosticStage: String {
            case setup, readinessSend = "readiness-send", readinessWait = "readiness-wait"
            case readinessComplete = "readiness-complete", upload
            case firstTagged = "first-tagged", firstSDKSend = "first-sdk-send"
            case firstReadback = "first-readback", secondTagged = "second-tagged"
            case secondSDKSend = "second-sdk-send", secondReadback = "second-readback", closed
        }
        var diagnosticStage = DiagnosticStage.setup
        var diagnosticSends = 0
        func observe(_ stage: DiagnosticStage) {
            diagnosticStage = stage
            print("custom-emoji-diagnostic stage=\(stage.rawValue)")
        }
        observe(.setup)
        // CUSTOM_EMOJI_DIAGNOSTIC_END
        do {
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            ).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Emoji send", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0))
            func readSnapshot() async throws -> ConversationWindowSnapshotFfi {
                let window = try await client.openConversationWindow(accountRef: account.label, groupIdHex: group.groupIdHex)
                let snapshot = try #require(window.snapshot())
                await window.cancel()
                return snapshot
            }
            // The fixture's cold worker must process a genuine ordinary send before
            // the epoch-pinned legacy media operation; admission alone is not readiness.
            // CUSTOM_EMOJI_DIAGNOSTIC_BEGIN
            observe(.readinessSend)
            // CUSTOM_EMOJI_DIAGNOSTIC_END
            let readiness = try await client.sendTextWithClientToken(accountRef: account.label,
                groupIdHex: group.groupIdHex, text: "Emoji fixture readiness", clientToken: UUID().uuidString)
            // CUSTOM_EMOJI_DIAGNOSTIC_BEGIN
            observe(.readinessWait)
            // CUSTOM_EMOJI_DIAGNOSTIC_END
            try await MarmotLocalSendFixtureReadiness.waitForCompletion(client: client,
                accountRef: account.label, groupIdHex: group.groupIdHex, token: readiness.clientToken)
            // CUSTOM_EMOJI_DIAGNOSTIC_BEGIN
            observe(.readinessComplete)
            // CUSTOM_EMOJI_DIAGNOSTIC_END
            var snapshot = try await readSnapshot()
            let epoch = try await client.marmot.groupMlsState(accountRef: account.label, groupIdHex: group.groupIdHex).epoch
            let groupSubscription = try await client.subscribeGroupState(accountRef: account.label, groupIdHex: group.groupIdHex)
            let groupRecord = try #require(await client.groupStateSubscriptionSnapshot(groupSubscription))
            let state = AppState.test(client: client, accountDefaults: IsolatedAccountDefaults.make())
            state.activeAccountRef = account.label
            let model = ConversationViewModel(appState: state, group: groupRecord)

            // A peer's kind-9 with :party: gives this chat one sendable emoji.
            let payload = Data("party-emoji-png".utf8)
            let peerURL = "https://peer.example.com/party"
            var received = CustomEmojiFixtures.reference(url: peerURL, sha: Self.hex(payload))
            received.sourceEpoch = epoch
            let peer = String(repeating: "5e", count: 32)
            let peerMessageID = String(repeating: "9a", count: 32)
            var peerRow = TimelineMessageRecordFfi(messageIdHex: peerMessageID, sourceMessageIdHex: nil, direction: "received",
                groupIdHex: group.groupIdHex, sender: peer, plaintext: "look :party: :celebrate: :party-time:",
                contentTokens: .emptyDocument, kind: MessageSemantics.kindChat,
                tags: [MessageTagFfi(values: ["emoji", "party", peerURL]),
                       MessageTagFfi(values: ["emoji", "celebrate", peerURL]),
                       MessageTagFfi(values: ["emoji", "party-time", peerURL])],
                timelineAt: 1, receivedAt: 1, replyToMessageIdHex: nil, replyPreview: nil, mediaJson: nil,
                media: [], agentTextStreamJson: nil, groupSystem: nil,
                reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []), edit: nil, deleted: false,
                deletedByMessageIdHex: nil, invalidationStatus: nil)
            peerRow.media = [.accepted(attachmentIndex: 0, reference: received)]
            let peerMessage = ConversationMessageFfi(timeline: peerRow, references: ConversationMessageReferencesFfi(
                messageIdHex: peerMessageID, sender: peer, replyAuthor: nil, mentions: [], mentionsTruncated: false,
                replyMentions: [], replyMentionsTruncated: false, system: nil,
                reactions: ConversationReactionsFfi(totalCount: 0, totalKinds: 0, items: [], omittedKinds: 0)))
            snapshot.revision.sequence += 1
            snapshot.messages = [peerMessage] + snapshot.messages
            model.installConversationWindow(snapshot)

            let party = try #require(CustomEmojiShortcode("party"))
            let celebrate = try #require(CustomEmojiShortcode("celebrate"))
            // :celebrate: is an alias of the same image. The hyphenated
            // shortcode renders but is not NIP-30, so it is never offered.
            #expect(Set(model.customEmojiSendables.map(\.shortcode)) == [party, celebrate])
            let emoji = model.customEmojiUsed(in: "yay :party: :celebrate: :party-time:")
            #expect(emoji.map(\.shortcode) == [party, celebrate])

            var uploadCount = 0
            var uploadedURL = ""
            let version = groupRecord.encryptedMedia.version ?? .v2
            let sender = ConversationCustomEmojiSender(
                scopeProvider: { model.customEmojiSendScope },
                currentEpoch: { epoch },
                loadBytes: { item in
                    #expect(item.reference == received)
                    #expect(item.demand == .automatic)
                    return payload
                },
                upload: { _, request in
                    // CUSTOM_EMOJI_DIAGNOSTIC_BEGIN
                    observe(.upload)
                    // CUSTOM_EMOJI_DIAGNOSTIC_END
                    uploadCount += 1
                    let ciphertext = Self.hex(Data("cipher".utf8) + request.plaintext)
                    uploadedURL = "https://blossom.example.com/\(ciphertext)"
                    return MediaAttachmentReferenceFfi(
                        locators: [MediaLocatorFfi(kind: "blossom-v1", value: uploadedURL)],
                        ciphertextSha256: ciphertext, plaintextSha256: Self.hex(request.plaintext),
                        nonceHex: String(repeating: "3", count: 24), fileName: request.fileName,
                        mediaType: request.mediaType, version: version, sourceEpoch: epoch,
                        dim: request.dim, thumbhash: request.thumbhash)
                },
                sendMessage: { scope, caption, attachments, tags in
                    // CUSTOM_EMOJI_DIAGNOSTIC_BEGIN
                    diagnosticSends += 1
                    observe(diagnosticSends == 1 ? .firstSDKSend : .secondSDKSend)
                    // CUSTOM_EMOJI_DIAGNOSTIC_END
                    _ = try await client.sendTaggedMedia(accountRef: scope.accountRef, groupIdHex: scope.groupIdHex,
                                                         attachments: attachments, caption: caption, tags: tags)
                }
            )

            // CUSTOM_EMOJI_DIAGNOSTIC_BEGIN
            observe(.firstTagged)
            // CUSTOM_EMOJI_DIAGNOSTIC_END
            try await sender.sendMessage(text: "yay :party: :celebrate: :party-time:", replyTargetId: nil, emoji: emoji)
            #expect(uploadCount == 1)

            // MDK stored a kind-9 carrying the caption, the emoji tag naming our
            // upload, and that upload as an attachment; the resolver draws it
            // inline and leaves nothing for the media grid.
            // CUSTOM_EMOJI_DIAGNOSTIC_BEGIN
            observe(.firstReadback)
            // CUSTOM_EMOJI_DIAGNOSTIC_END
            var readBack = try await readSnapshot()
            let sent = try #require(readBack.messages.first {
                $0.timeline.direction == "sent" && $0.timeline.kind == MessageSemantics.kindChat
                    && $0.timeline.plaintext == "yay :party: :celebrate: :party-time:"
                    && $0.timeline.tags.contains(MessageTagFfi(values: ["emoji", "party", uploadedURL]))
            }).timeline
            #expect(sent.plaintext == "yay :party: :celebrate: :party-time:")
            #expect(sent.tags.contains(MessageTagFfi(values: ["emoji", "party", uploadedURL])))
            #expect(sent.tags.contains(MessageTagFfi(values: ["emoji", "celebrate", uploadedURL])))
            // One image, one attachment slot, even with two shortcodes.
            #expect(sent.media.count == 1)
            #expect(!sent.tags.contains { $0.values.first == "emoji" && $0.values.dropFirst().first == "party-time" })
            let attachments = MessageMediaAttachment.displayItems(fromOutcomes: sent.media, ownerId: "msg:\(sent.messageIdHex)",
                messageId: sent.messageIdHex, sourceMessageId: sent.sourceMessageIdHex)
            let resolution = CustomEmojiResolver.resolve(text: sent.plaintext, tags: sent.tags, attachments: attachments)
            #expect(resolution.shortcodes == [party, celebrate])
            #expect(resolution.inline[party]?.reference?.locators.first?.value == uploadedURL)
            #expect(resolution.gridItems.isEmpty)

            // A second message reuses the uploaded reference: no second upload.
            // CUSTOM_EMOJI_DIAGNOSTIC_BEGIN
            observe(.secondTagged)
            // CUSTOM_EMOJI_DIAGNOSTIC_END
            try await sender.sendMessage(text: "again :party:", replyTargetId: nil, emoji: [emoji[0]])
            #expect(uploadCount == 1)
            // CUSTOM_EMOJI_DIAGNOSTIC_BEGIN
            observe(.secondReadback)
            // CUSTOM_EMOJI_DIAGNOSTIC_END
            readBack = try await readSnapshot()
            #expect(readBack.messages.filter {
                $0.timeline.tags.contains(MessageTagFfi(values: ["emoji", "party", uploadedURL]))
            }.count == 2)

            // The view model renders it through the #1136 path.
            readBack.revision.sequence = snapshot.revision.sequence + 1
            readBack.messages = [peerMessage] + readBack.messages
            model.installConversationWindow(readBack)
            let item = try #require(model.timeline.first { item in
                if case .message(let record, _) = item.kind { return record.messageIdHex == sent.messageIdHex }
                return false
            })
            #expect(model.customEmoji(for: item).shortcodes == [party, celebrate])
            #expect(model.mediaItems(for: item).isEmpty)
            try await client.marmot.shutdownAndClose()
            // CUSTOM_EMOJI_DIAGNOSTIC_BEGIN
            observe(.closed)
            // CUSTOM_EMOJI_DIAGNOSTIC_END
        } catch {
            // CUSTOM_EMOJI_DIAGNOSTIC_BEGIN
            let category: String
            switch error {
            case MarmotLocalSendFixtureReadiness.Failure.rejected: category = "readiness-rejected"
            case MarmotLocalSendFixtureReadiness.Failure.missingSubmission: category = "readiness-missing"
            case MarmotLocalSendFixtureReadiness.Failure.timedOut: category = "readiness-timeout"
            case is CancellationError: category = "cancelled"
            case is MarmotKitError: category = "sdk-error"
            default: category = "other"
            }
            print("custom-emoji-diagnostic failure-stage=\(diagnosticStage.rawValue) category=\(category)")
            // CUSTOM_EMOJI_DIAGNOSTIC_END
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }
}
