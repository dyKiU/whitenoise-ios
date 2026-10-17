#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import Observation

    /// A finite transport import; it never receives or approves an SDK action.
    @MainActor @Observable
    final class DevicePairingQRImport {
        @ObservationIgnored private var accumulator: DevicePairingQRCode.FragmentAccumulator
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        let ticket = UUID()
        private(set) var terminal = false
        private(set) var receivedFrames = 0
        private(set) var totalFrames: Int?

        init(now: ContinuousClock.Instant = ContinuousClock().now, isCurrent: @escaping @MainActor () -> Bool) {
            accumulator = .init(now: now)
            self.isCurrent = isCurrent
        }

        func receive(_ frame: String, now: ContinuousClock.Instant = ContinuousClock().now) throws -> String? {
            guard !terminal, isCurrent() else {
                retire()
                throw DevicePairingQRCode.MultipartFailure.expired
            }
            do {
                let packet = try accumulator.ingest(frame, now: now)
                guard isCurrent() else {
                    retire()
                    throw DevicePairingQRCode.MultipartFailure.expired
                }
                receivedFrames = accumulator.receivedFrameCount
                totalFrames = accumulator.totalFrameCount
                if packet != nil { terminal = true }
                return packet
            } catch {
                receivedFrames = accumulator.receivedFrameCount
                totalFrames = accumulator.totalFrameCount
                if accumulator.isTerminal { terminal = true }
                throw error
            }
        }

        func retire() {
            accumulator.reset()
            terminal = true
            receivedFrames = 0
            totalFrames = nil
        }
    }
#endif
