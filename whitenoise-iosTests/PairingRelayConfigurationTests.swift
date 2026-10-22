import MarmotKit
import Testing

@testable import whitenoise_ios

struct PairingRelayConfigurationTests {
    @Test func standardRuntimeUsesSeparatePairingRoutesAndPreservesOtherOptions() {
        #if WN_CURRENT_SDK_API
            var options = MarmotOptions(deployment: marmotDeploymentWhiteNoise())
        #else
            var options = MarmotOptions()
        #endif
        options.cursorPersistence = .frozen
        options.clientName = "whitenoise"
        let configured = MarmotClient.pairingOptions(options, runtimeRelays: MarmotClient.seedRelays)
        #expect(configured.cursorPersistence == .frozen)
        #expect(configured.clientName == "whitenoise")
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            #expect(configured.pairingRelayUrls == ["wss://nos.lol", "wss://relay.primal.net"])
            #expect(configured.pairingRelayUrls != MarmotClient.seedRelays)
        #endif
    }

    @Test func customRuntimeDoesNotAcquirePublicPairingFallbacks() {
        #if WN_CURRENT_SDK_API
            var options = MarmotOptions(deployment: marmotDeploymentWhiteNoise())
        #else
            var options = MarmotOptions()
        #endif
        options.relayPolicy = .allowLoopback
        options.cursorPersistence = .frozen
        let configured = MarmotClient.pairingOptions(options, runtimeRelays: ["ws://127.0.0.1:7000"])
        #expect(configured.relayPolicy == .allowLoopback)
        #expect(configured.cursorPersistence == .frozen)
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            #expect(configured.pairingRelayUrls == nil)
        #endif
    }
}
