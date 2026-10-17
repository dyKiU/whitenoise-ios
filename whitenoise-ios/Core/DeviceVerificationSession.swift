#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit

    /// Verification-only operations on the original native owner; no enrollment authority.
    @MainActor
    protocol DeviceVerificationSession: AnyObject {
        var latestSnapshot: DeviceLinkingSnapshotFfi? { get }
        func setupPacket() throws -> Data
        func outgoingPackets() async throws -> [DeviceLinkingOutgoingPacketFfi]
        func receiveSetupPacket(_ packet: Data) async throws
        func receivePacket(_ packet: Data) async throws
        func acknowledgePacket(_ id: String) async throws
        func confirmComparison(displayedRevision: UInt64) async throws
    }
#endif
