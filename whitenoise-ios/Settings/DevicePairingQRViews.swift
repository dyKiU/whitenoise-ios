#if WN_EXPERIMENTAL_DEVICE_SYNC
    import SwiftUI
    import UIKit

    struct DevicePairingQRCard: View {
        @Environment(\.scenePhase) private var scenePhase
        let packet: String
        @State private var image: UIImage?
        @State private var unavailable = false

        var body: some View {
            Group {
                if scenePhase == .active {
                    if unavailable {
                        Text("This packet is too large for a QR code. Use Copy instead.")
                    } else {
                        WNQRCodeCard(image: image, accessibilityLabel: "Device pairing QR code")
                            .privacySensitive()
                    }
                }
            }
            .task(id: scenePhase == .active ? packet : nil) {
                image = nil
                unavailable = false
                guard scenePhase == .active else { return }
                if let payload = try? DevicePairingQRCode.payload(packet: packet),
                    let rendered = QRCode.image(from: payload)
                {
                    image = rendered
                } else {
                    unavailable = true
                }
            }
        }
    }

    struct DevicePairingScannerSheet: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(\.scenePhase) private var scenePhase
        @State private var failure: QRScannerFailure?
        @State private var invalid = false
        @State private var attempt = 0
        @State private var cameraSession = UUID()
        let onScan: (String) -> Void

        var body: some View {
            NavigationStack {
                Group {
                    if let failure {
                        QRScannerUnavailableView(failure: failure) {
                            self.failure = nil
                            cameraSession = UUID()
                        }
                    } else if scenePhase == .active {
                        QRScannerView(
                            onScan: { payload in
                                guard scenePhase == .active,
                                    let packet = try? DevicePairingQRCode.packet(from: payload)
                                else { return }
                                onScan(packet)
                                dismiss()
                            }, onError: { failure = $0 },
                            validate: { (try? DevicePairingQRCode.packet(from: $0)) != nil },
                            onInvalidPayload: { invalid = true }, scanAttempt: attempt
                        )
                        .id(cameraSession)
                        .ignoresSafeArea()
                    } else {
                        ProgressView("Preparing Camera")
                    }
                }
                .navigationTitle("Scan pairing QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .alert("Can’t Use This QR Code", isPresented: $invalid) {
                    Button("Try Again") { attempt += 1 }
                } message: {
                    Text("Scan a device pairing QR from White Noise. Private keys and profile codes are not accepted.")
                }
            }
        }
    }
#endif
