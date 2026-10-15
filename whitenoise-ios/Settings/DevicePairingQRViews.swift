#if WN_EXPERIMENTAL_DEVICE_SYNC
    import SwiftUI
    import UIKit

    struct DevicePairingQRCard: View {
        @Environment(\.scenePhase) private var scenePhase
        let packet: String
        @State private var image: UIImage?
        @State private var unavailable = false
        @State private var pages: [String] = []
        @State private var page = 0

        var body: some View {
            VStack {
                if scenePhase == .active {
                    if unavailable {
                        Text("This packet is too large for a QR code. Use Copy instead.")
                    } else {
                        WNQRCodeCard(image: image, accessibilityLabel: "Device pairing QR code")
                            .privacySensitive()
                        if pages.count > 1 {
                            HStack {
                                Button("Back") { page = max(0, page - 1); renderPage() }.disabled(page == 0)
                                Text(L10n.formatted("%@ of %@", String(page + 1), String(pages.count))).monospacedDigit()
                                Button("Next") { page = min(pages.count - 1, page + 1); renderPage() }
                                    .disabled(page == pages.count - 1)
                            }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            .task(id: scenePhase == .active ? packet : nil) {
                image = nil
                pages = []
                page = 0
                unavailable = false
                guard scenePhase == .active else { return }
                if let payloads = try? DevicePairingQRCode.payloads(packet: packet) {
                    pages = payloads
                    renderPage()
                } else {
                    unavailable = true
                }
            }
        }

        private func renderPage() {
            guard pages.indices.contains(page) else { image = nil; return }
            image = QRCode.image(from: pages[page])
            unavailable = image == nil
        }
    }

    /// Retains the same import across camera retries and sheet reopen.
    struct DevicePairingQRImportButton: View {
        @Environment(\.scenePhase) private var scenePhase
        let isCurrent: @MainActor () -> Bool
        let onScan: (String) -> Void
        private let onStart: () -> Void
        @State private var transport: DevicePairingQRImport?
        @State private var scanning = false

        init(isCurrent: @escaping @MainActor () -> Bool,
             onStart: @escaping () -> Void = {}, onScan: @escaping (String) -> Void) {
            self.isCurrent = isCurrent
            self.onStart = onStart
            self.onScan = onScan
        }

        var body: some View {
            VStack {
                WNButton(title: "Scan pairing QR", emphasis: .secondary, size: .standard) {
                    guard scenePhase == .active, isCurrent() else { return }
                    if transport == nil { transport = DevicePairingQRImport(isCurrent: isCurrent) }
                    onStart()
                    scanning = true
                }.disabled(transport?.terminal == true)
                if transport != nil {
                    WNButton(title: "Start over", emphasis: .secondary, size: .standard) {
                        transport?.retire()
                        transport = nil
                    }
                }
            }
            .sheet(isPresented: $scanning) {
                if let transport {
                    DevicePairingScannerSheet(transport: transport) { packet in
                        guard scanning, scenePhase == .active, isCurrent(), self.transport === transport else { return }
                        onScan(packet)
                        scanning = false
                    }
                }
            }
            .task(id: transport?.ticket) {
                guard let captured = transport else { return }
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                if transport === captured { captured.retire(); scanning = false }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { transport?.retire(); scanning = false }
            }
            .onChange(of: isCurrent()) { _, current in
                if !current { transport?.retire(); scanning = false }
            }
            .onDisappear { transport?.retire(); scanning = false }
        }
    }

    struct DevicePairingScannerSheet: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(\.scenePhase) private var scenePhase
        @State private var failure: QRScannerFailure?
        @State private var invalid = false
        @State private var attempt = 0
        @State private var cameraSession = UUID()
        let transport: DevicePairingQRImport
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
                                    !transport.terminal else { return }
                                do {
                                    if let packet = try transport.receive(payload) {
                                        onScan(packet)
                                        dismiss()
                                    } else { attempt += 1 }
                                } catch { invalid = true }
                            }, onError: { failure = $0 },
                            validate: { (try? DevicePairingQRCode.validateFrame($0)) != nil },
                            onInvalidPayload: { invalid = true }, scanAttempt: attempt
                        )
                        .id(cameraSession)
                        .ignoresSafeArea()
                    } else {
                        ProgressView("Preparing Camera")
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if let total = transport.totalFrames {
                        Text(L10n.formatted("%@ of %@", String(transport.receivedFrames), String(total))).monospacedDigit().padding()
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
                    Button("Try Again") { attempt += 1 }.disabled(transport.terminal)
                    Button("Cancel", role: .cancel) { dismiss() }
                } message: {
                    Text("Scan a device pairing QR from White Noise. Private keys and profile codes are not accepted.")
                }
            }
        }
    }
    #Preview { DevicePairingQRCard(packet: Data([1, 2, 3]).base64EncodedString()) }
    #Preview { DevicePairingQRImportButton(isCurrent: { true }, onScan: { _ in }) }
#endif
