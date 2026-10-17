import Foundation

nonisolated enum PairedChatDisplayTitle {
    static func resolve(name: String?, directPeerAccountIdHex: String?, peerDisplayName: String?) -> String {
        guard let peer = directPeerAccountIdHex?.trimmingCharacters(in: .whitespacesAndNewlines), !peer.isEmpty else {
            return ContentSanitizer.groupName(name) ?? L10n.string("Unnamed group")
        }
        return IdentityPresentation.text(
            accountIdHex: peer,
            knownName: ContentSanitizer.displayName(peerDisplayName) ?? ContentSanitizer.groupName(name))
    }
}
