import MarmotKit
import Testing

@testable import whitenoise_ios

struct PairingRelayConfigurationTests {
    @Test func standardRuntimeUsesSeparatePairingRoutesAndPreservesOtherOptions() {
        let options = MarmotOptions(cursorPersistence: .frozen, clientName: "whitenoise")
        let configured = MarmotClient.pairingOptions(options, runtimeRelays: MarmotClient.seedRelays)
        #expect(configured.cursorPersistence == .frozen)
        #expect(configured.clientName == "whitenoise")
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            #expect(configured.pairingRelayUrls == ["wss://nos.lol", "wss://relay.primal.net"])
            #expect(configured.pairingRelayUrls != MarmotClient.seedRelays)
        #endif
    }

    @Test func customRuntimeDoesNotAcquirePublicPairingFallbacks() {
        let options = MarmotOptions(relayPolicy: .allowLoopback, cursorPersistence: .frozen)
        let configured = MarmotClient.pairingOptions(options, runtimeRelays: ["ws://127.0.0.1:7000"])
        #expect(configured.relayPolicy == .allowLoopback)
        #expect(configured.cursorPersistence == .frozen)
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            #expect(configured.pairingRelayUrls == nil)
        #endif
    }
}
