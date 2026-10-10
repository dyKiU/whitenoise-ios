import XCTest

@MainActor final class HostedHistoryApprovalUITests: XCTestCase {
    func testExternalHostedControlTap() throws {
        try tapExistingHostedButton(identifier: "native-hosted-control", result: "native-hosted-control-tapped")
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
