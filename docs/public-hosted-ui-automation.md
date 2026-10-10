# Public hosted UI automation

`Whitenoise (Hosted Automation)` is an opt-in test scheme containing the existing
unit-test host and a separate public XCTest UI runner. Existing Staging and
Production PR schemes do not acquire the UI target. The runner attaches with
`XCUIApplication(bundleIdentifier:)`; it never calls `launch()` or reconstructs
an account/model. It intentionally fails unless the Personal Team Staging test
host is already foreground.

The qualified control uses the dedicated M5 simulator and existing iOS
DerivedData. Build the scheme for testing with both
`ExternalHostedUIControlTests` and `HostedHistoryApprovalUITests` selected.
Split its generated xctestrun into one unit-test dictionary and one UI-test
dictionary, preserving the metadata and environment. Set
`WN_EXTERNAL_UI_CONTROL=1` on the unit test, and select only
`testExternalDriverAttachesWithoutReplacingHostedApp` and
`testExternalHostedControlTap` respectively. Install the generated UI runner
before starting the host. Start the unit `test-without-building`, wait for its
actual test-start log, then run the UI `test-without-building` on the same
simulator with parallel testing disabled. Require both real nonempty results.
The public UI test taps the stable control identifier and observes the changed
label; the unit keeps its existing host alive and finishes normally.

Xcode's documented `UseDestinationArtifacts` is not supported for simulators;
the failed attempt and initial scheduling error are retained separately. Normal
simulator driver testing was subsequently qualified on a clean nonoverlapping
control. Never start a replacement host while another host's terminal collection
is active. This checkpoint establishes attachment and tap feasibility, not
history approval or imported-history UI acceptance. Full PR qualification is
required before merging.
