import XCTest

@MainActor final class HostedHistoryApprovalUITests: XCTestCase {
    func testExternalRunnerStartsWithoutLaunchingAbsentHost() {
        // Provision the public UI runner before any hosted original exists.
        let app = XCUIApplication(bundleIdentifier: "dev.ipf.whitenoise.ios.staging.personal")
        XCTAssertEqual(app.state, .notRunning)
    }

    func testExternalHostedControlTap() throws {
        try tapExistingHostedButton(identifier: "native-hosted-control", result: "native-hosted-control-tapped")
    }

    func testExternalOriginalHistoryApprovalTap() throws {
        guard ProcessInfo.processInfo.environment["WN_HISTORY_APPROVAL_UI_DRIVER"] == "1" else {
            throw XCTSkip("Requires an actual original history approval hosted by the app")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.ipf.whitenoise.ios.staging.personal")
        XCTAssertEqual(app.state, .runningForeground)
        let button = app.buttons["history-original-approve"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.isHittable)
        button.tap()
    }

    private func tapExistingHostedButton(identifier: String, result: String) throws {
        let app = XCUIApplication(bundleIdentifier: "dev.ipf.whitenoise.ios.staging.personal")
        // Attach only: relaunching would destroy the hosted original owner.
        XCTAssertEqual(app.state, .runningForeground)
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        XCTAssertTrue(button.isHittable)
        button.tap()
        XCTAssertTrue(app.staticTexts[result].waitForExistence(timeout: 5))
    }
}
