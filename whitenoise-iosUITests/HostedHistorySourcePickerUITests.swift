import XCTest

@MainActor final class HostedHistorySourcePickerUITests: XCTestCase {
    func testExternalNativeChoiceRequestAndCancel() throws {
        guard ProcessInfo.processInfo.environment["WN_HISTORY_SOURCE_UI_DRIVER"] == "1" else {
            throw XCTSkip("Requires an actual native source picker hosted by the app")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.ipf.whitenoise.ios.staging.personal")
        // Attach only; launch would replace the account-owned original runtime.
        XCTAssertEqual(app.state, .runningForeground)
        let choice = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@", "history-source.choice-")
        ).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 15))
        XCTAssertTrue(choice.isEnabled && choice.isHittable)
        choice.tap()
        let request = app.buttons["history-source.request"]
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        XCTAssertTrue(request.isEnabled && request.isHittable)
        request.tap()
        // The native snapshot must reach the view; this test never invokes Continue.
        XCTAssertTrue(app.buttons["history-source.continue"].waitForExistence(timeout: 15))
        let bridge = try XCTUnwrap(ProcessInfo.processInfo.environment["WN_HISTORY_SOURCE_UI_BRIDGE"])
        let reviewed = URL(fileURLWithPath: bridge).appendingPathComponent("reviewed.json")
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: reviewed.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: reviewed.path))
        let cancel = app.buttons["history-source.cancel"]
        for _ in 0..<3 where !cancel.exists || !cancel.isHittable { app.swipeUp() }
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.isEnabled && cancel.isHittable)
        cancel.tap()
    }
}
