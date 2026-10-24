import XCTest

@MainActor final class HostedHistorySourceTransferUITests: XCTestCase {
    func testExternalNativeChoiceRequestRefreshAndContinue() throws {
        guard let path = ProcessInfo.processInfo.environment["WN_IOS_SOURCE_TRANSFER_PUBLIC_BRIDGE"] else {
            throw XCTSkip("Requires an actual hosted native source transfer and recipient")
        }
        let bridge = URL(fileURLWithPath: path, isDirectory: true)
        try waitForFile("ui-ready.json", bridge: bridge, timeout: 120)
        let bytes = try Data(contentsOf: bridge.appendingPathComponent("ui-ready.json"))
        let observation = try JSONDecoder().decode([String: String].self, from: bytes)
        let identifier = try XCTUnwrap(observation["choice_identifier"])
        XCTAssertTrue(identifier.hasPrefix("history-source.choice-"))
        let app = XCUIApplication(bundleIdentifier: "dev.ipf.whitenoise.ios.staging.personal")
        // Attach only: launching would replace the original account-owned runtime.
        XCTAssertEqual(app.state, .runningForeground)
        try tap(app.buttons[identifier], in: app)
        try tap(app.buttons["history-source.request"], in: app)
        try waitForFile("requested.json", bridge: bridge, timeout: 15)
        try waitForFile("recipient-approved.json", bridge: bridge, timeout: 30)
        try tap(app.buttons["history-source.refresh"], in: app)
        try waitForFile("refreshed.json", bridge: bridge, timeout: 15)
        try tap(app.buttons["history-source.continue"], in: app)
        try waitForFile("ui-completed.json", bridge: bridge, timeout: 30)
    }

    private func tap(_ button: XCUIElement, in app: XCUIApplication) throws {
        for _ in 0..<3 where !button.exists || !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isEnabled && button.isHittable)
        button.tap()
    }

    private func waitForFile(_ name: String, bridge: URL, timeout: TimeInterval) throws {
        let file = bridge.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
