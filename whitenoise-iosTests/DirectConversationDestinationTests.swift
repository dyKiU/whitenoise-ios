import MarmotKit
import Testing

@testable import whitenoise_ios

@Suite struct DirectConversationDestinationTests {
    @Test(arguments: [false, true]) func localLookupPreservesNativeReuseAndArchivePolicy(reusable: Bool) {
        let original = ExistingDirectConversationFfi(
            groupIdHex: "local-group", reusable: reusable, lifecycleState: .stable,
            selfMembership: .member, pendingConfirmation: !reusable, leaveRequestPending: false,
            disbanding: false, archived: true, activitySortAt: 1)
        let destination = DirectConversationDestination.localMls(original)
        #expect(destination.groupIdHex == original.groupIdHex)
        #expect(destination.reusable == original.reusable)
        #expect(destination.archived)
        #expect(!destination.isPaired)
    }

    #if WN_EXPERIMENTAL_DEVICE_SYNC
        @Test func pairedLookupRetainsSourceWithoutClaimingAnMlsMembership() {
            let original = PairedChatSummaryFfi(
                groupIdHex: "paired-group", name: "", description: "",
                source: .init(
                    deviceHex: String(repeating: "b", count: 64), policyDigestHex: String(repeating: "c", count: 64),
                    protectedGeneration: 2, sourceEpoch: 3, sourceSequence: 4,
                    sourceDigestHex: String(repeating: "d", count: 64)))
            let destination = DirectConversationDestination.pairedSource(original)
            #expect(destination.groupIdHex == original.groupIdHex)
            #expect(destination.reusable)
            #expect(destination.isPaired)
            #expect(!destination.archived)
            guard case .pairedSource(let observation) = destination else {
                Issue.record("Paired observation was converted into MLS authority")
                return
            }
            #expect(observation == original)
        }
    #endif
}
