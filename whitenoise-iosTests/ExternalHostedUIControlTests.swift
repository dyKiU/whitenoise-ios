import SwiftUI
import XCTest

@testable import whitenoise_ios

private struct ExternalHostedControl: View {
    @State private var tapped = false
    var body: some View {
        if tapped {
            Text("Tapped").accessibilityIdentifier("native-hosted-control-tapped")
        } else {
            Button("Tap control") { tapped = true }
                .accessibilityIdentifier("native-hosted-control")
        }
    }
}

@MainActor final class ExternalHostedUIControlTests: XCTestCase {
    func testExternalDriverAttachesWithoutReplacingHostedApp() async throws {
        guard ProcessInfo.processInfo.environment["WN_EXTERNAL_UI_CONTROL"] == "1" else {
            throw XCTSkip("Requires the separate public XCTest UI driver")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ExternalHostedControl())
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        // Keep the actual host alive while the independently provisioned driver taps it.
        try await Task.sleep(for: .seconds(40))
        XCTAssertTrue(window.isKeyWindow)
    }
}
