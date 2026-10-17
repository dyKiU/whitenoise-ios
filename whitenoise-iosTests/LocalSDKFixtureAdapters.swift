import MarmotKit

#if WN_EXPERIMENTAL_DEVICE_SYNC
    extension AttachmentEntryFfi {
        /// Existing media fixtures describe shared attachments rather than inline emoji.
        init(
            messageIdHex: String, sourceMessageIdHex: String, sender: String,
            timelineAt: UInt64, receivedAt: UInt64, sourceEpoch: UInt64?,
            category: AttachmentCategoryFfi, attachment: MediaAttachmentOutcomeFfi
        ) {
            self.init(
                messageIdHex: messageIdHex, sourceMessageIdHex: sourceMessageIdHex, sender: sender,
                timelineAt: timelineAt, receivedAt: receivedAt, sourceEpoch: sourceEpoch,
                category: category, role: .shared, attachment: attachment)
        }
    }

    extension PresentedChatRowFfi {
        /// Existing chat fixtures do not model the newer core's draft lease.
        init(
            preview: SelectedChatPreviewFfi,
            actions: ChatListRowActionsFfi,
            row: ChatListRowFfi,
            presentation: ConversationPresentationFfi,
            avatarAsset: AvatarAssetFfi?
        ) {
            self.init(
                draftVersion: nil, preview: preview, actions: actions, row: row,
                presentation: presentation, avatarAsset: avatarAsset)
        }
    }
#endif
