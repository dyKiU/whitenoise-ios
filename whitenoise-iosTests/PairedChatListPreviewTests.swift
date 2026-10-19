import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    @MainActor @Suite struct PairedChatListPreviewTests {
        private func message() -> PairedChatMessageFfi {
            .init(
                kind: 9, canonicalChat: true, messageIdHex: String(repeating: "a", count: 64),
                authorHex: String(repeating: "b", count: 64), createdAt: 123, expiresAt: nil,
                deleted: false, content: "Synthetic text",
                contentTokens: .init(blocks: [], truncated: false, blankLinesBefore: Data()),
                tags: [], mediaAttachments: [],
                source: .init(
                    deviceHex: String(repeating: "c", count: 64),
                    policyDigestHex: String(repeating: "d", count: 64),
                    protectedGeneration: 1, sourceEpoch: 1, sourceSequence: 1,
                    sourceDigestHex: String(repeating: "e", count: 64)))
        }

        private func row(_ value: PairedChatMessageFfi) -> PairedChatSummaryFfi {
            .init(
                groupIdHex: "synthetic", name: "Friends", description: "", source: value.source,
                latestMessage: value)
        }

        private func photo(_ index: UInt32) -> MediaAttachmentOutcomeFfi {
            .accepted(
                attachmentIndex: index,
                reference: .init(
                    locators: [], ciphertextSha256: String(repeating: "a", count: 64),
                    plaintextSha256: String(repeating: "b", count: 64), nonceHex: String(repeating: "c", count: 24),
                    fileName: "synthetic.jpg", mediaType: "image/jpeg", version: .v1,
                    sourceEpoch: 1, dim: nil, thumbhash: nil))
        }

        @Test func localAndSharedTextUseTheSameBodyAndAttribution() {
            let value = message()
            let local = ChatListMessagePreviewFfi(
                messageIdHex: value.messageIdHex, sender: value.authorHex, senderDisplayName: nil,
                plaintext: value.content, kind: 9, timelineAt: value.createdAt, deleted: false)
            for account in [nil, value.authorHex] {
                let expected = ChatRowPreviewPresentation.message(
                    body: MessagePreview.body(local), systemImageName: nil,
                    sender: value.authorHex, senderDisplayName: nil, isDirectMessage: false,
                    activeAccountIdHex: account, senderName: { _ in "Alice" })
                let actual = AutomaticChatListPresentation.preview(
                    row(value), activeAccountIdHex: account, senderName: { _ in "Alice" })
                #expect(actual == expected)
            }
        }

        @Test func directPeerPreviewDoesNotAddAGroupAuthorPrefix() {
            let value = message()
            var direct = row(value)
            direct.directPeerAccountIdHex = value.authorHex
            let actual = AutomaticChatListPresentation.preview(
                direct, activeAccountIdHex: nil, senderName: { _ in "Alice" })
            #expect(actual.prefix == nil)
            #expect(actual.body == value.content)
        }

        @Test func captionUsesTheNativeMediaGlyph() {
            var value = message()
            value.mediaAttachments = [photo(0)]
            let actual = AutomaticChatListPresentation.preview(
                row(value), activeAccountIdHex: nil, senderName: { _ in "Alice" })
            #expect(actual.prefix == "Alice")
            #expect(actual.body == value.content)
            #expect(actual.systemImageName == "photo")
        }

        @Test func photoOnlyPreviewUsesTheNativePluralAndOwnSenderPrefix() {
            var value = message()
            value.content = ""
            value.mediaAttachments = [photo(0), photo(1)]
            let actual = AutomaticChatListPresentation.preview(
                row(value), activeAccountIdHex: value.authorHex, senderName: { _ in "Alice" })
            #expect(actual.prefix == L10n.string("You"))
            #expect(actual.body == L10n.plural("%lld images", Int64(2)))
            #expect(actual.systemImageName == "photo.on.rectangle")
        }

        @Test func unsupportedKindsNeverInterpretContentOrAuthor() {
            var value = message()
            value.canonicalChat = false
            value.kind = 1068
            let actual = AutomaticChatListPresentation.preview(
                row(value), activeAccountIdHex: value.authorHex, senderName: { _ in "Alice" })
            #expect(actual == .init(prefix: nil, body: L10n.string("Unsupported message")))
        }

        @Test func deletionMasksTextAndAttachments() {
            var value = message()
            value.deleted = true
            value.mediaAttachments = [photo(0)]
            let actual = AutomaticChatListPresentation.preview(
                row(value), activeAccountIdHex: nil, senderName: { _ in "Alice" })
            #expect(actual.body == MessageDeletionPresentation.text(source: .unknown))
            #expect(actual.systemImageName == nil)
        }

        @Test func blockedAuthorsCannotLeakTextOrAttribution() {
            let value = message()
            let actual = AutomaticChatListPresentation.preview(
                row(value), activeAccountIdHex: nil, blockedAuthors: [value.authorHex],
                senderName: { _ in "Alice" })
            #expect(actual == .init(prefix: nil, body: L10n.string("New message")))
            var direct = row(value)
            direct.directPeerAccountIdHex = value.authorHex
            #expect(
                AutomaticChatListPresentation.preview(
                    direct, activeAccountIdHex: nil, blockedAuthors: [value.authorHex], senderName: { _ in "Alice" }
                ) == .init(prefix: nil, body: L10n.string("You blocked this user")))
        }

        @Test func exactExpiryHidesTheMessageAndItsTimestamp() {
            var value = message()
            value.expiresAt = 200
            let chat = row(value)
            let now = Date(timeIntervalSince1970: 200)
            #expect(AutomaticChatListPresentation.latestMessage(chat, now: now) == nil)
            #expect(
                AutomaticChatListPresentation.preview(
                    chat, activeAccountIdHex: nil, senderName: { _ in "Alice" }, now: now
                ) == .init(prefix: nil, body: L10n.string("No messages yet")))
        }

        @Test func canonicalMentionsUseTheNativeDisplayNameResolver() throws {
            let npub = try #require(NostrProfileReference.npub(fromAccountIdHex: String(repeating: "11", count: 32)))
            var value = message()
            value.content = "Hello @\(npub)"
            let actual = AutomaticChatListPresentation.preview(
                row(value), activeAccountIdHex: nil, senderName: { _ in "Alice" },
                mentionDisplayName: { $0.bech32 == npub ? "Alex" : nil })
            #expect(actual.body == "Hello @Alex")
        }
    }
#endif
