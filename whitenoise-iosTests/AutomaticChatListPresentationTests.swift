import MarmotKit
import Testing

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    @MainActor @Suite struct AutomaticChatListPresentationTests {
        private func row(_ id: String, name: String) -> PairedChatSummaryFfi {
            .init(
                groupIdHex: id, name: name, description: "",
                source: .init(
                    deviceHex: String(repeating: "a", count: 64), policyDigestHex: String(repeating: "c", count: 64),
                    protectedGeneration: 1, sourceEpoch: 1, sourceSequence: 1,
                    sourceDigestHex: String(repeating: "d", count: 64)))
        }

        @Test func existingOrdinaryChatWinsWithoutInventingLocalRows() {
            let remote = [row("local", name: "First"), row("missing", name: "Second")]
            let visible = AutomaticChatListPresentation.rows(remote, excluding: ["local"], query: "")
            #expect(visible == [remote[1]])
        }

        @Test func newPairedOnlyChatAppearsWithoutLocalMembership() {
            let remote = [row("missing", name: "Friends")]
            #expect(AutomaticChatListPresentation.rows(remote, excluding: [], query: "") == remote)
        }

        @Test func searchMatchesRenderedSanitizedTitle() {
            let remote = [row("first", name: "  Friends  "), row("second", name: "Other")]
            #expect(AutomaticChatListPresentation.rows(remote, excluding: [], query: " friends ") == [remote[0]])
            #expect(AutomaticChatListPresentation.rows(remote, excluding: [], query: "absent").isEmpty)
        }
    }
#endif
