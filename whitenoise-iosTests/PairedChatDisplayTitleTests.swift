import Foundation
import Testing

@testable import whitenoise_ios

@Suite struct PairedChatDisplayTitleTests {
    private let peer = String(repeating: "a", count: 64)

    @Test func directChatUsesCurrentNameInsteadOfOldSourceTitle() {
        #expect(
            PairedChatDisplayTitle.resolve(name: "Old", directPeerAccountIdHex: peer, peerDisplayName: "Current")
                == "Current")
    }

    @Test func directChatKeepsSourceNameWhileContactIsUnknown() {
        #expect(
            PairedChatDisplayTitle.resolve(name: "Source", directPeerAccountIdHex: peer, peerDisplayName: nil)
                == "Source")
    }

    @Test func unknownDirectPeerDisplaysNpubInsteadOfHexOrGroupPlaceholder() {
        let title = PairedChatDisplayTitle.resolve(name: "", directPeerAccountIdHex: peer, peerDisplayName: nil)
        #expect(title == IdentityPresentation.text(accountIdHex: peer))
        #expect(title.hasPrefix("npub"))
        #expect(!title.contains(peer))
    }

    @Test func legacyGroupDoesNotBorrowAContactName() {
        #expect(
            PairedChatDisplayTitle.resolve(name: "Friends", directPeerAccountIdHex: nil, peerDisplayName: "Contact")
                == "Friends")
    }

    @Test func unnamedLegacyGroupKeepsGroupPlaceholder() {
        #expect(
            PairedChatDisplayTitle.resolve(name: " ", directPeerAccountIdHex: nil, peerDisplayName: nil)
                == L10n.string("Unnamed group"))
    }

    @Test func invalidPeerAndHexNameDoNotLeakRawIdentity() {
        #expect(
            PairedChatDisplayTitle.resolve(name: peer, directPeerAccountIdHex: "invalid", peerDisplayName: nil)
                == L10n.string("Unknown user"))
    }

    @Test func currentNameIsSanitized() {
        #expect(
            PairedChatDisplayTitle.resolve(name: "", directPeerAccountIdHex: peer, peerDisplayName: "Name\u{202e}\n")
                == "Name")
    }
}
