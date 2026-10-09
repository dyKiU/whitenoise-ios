# Personal Team development baseline

Use `Whitenoise (Staging)` / `Debug-Staging` on M1 for the separate
`WN Personal Dev` installation. It uses the `.staging.personal` bundle,
extension, App Group, Keychain and URL identities alongside TestFlight.
Configure the Personal Team locally in Xcode or pass `DEVELOPMENT_TEAM`;
do not commit a team identifier or signing credentials.

This branch uses published MarmotKit 0.12.0, without experimental device sync.
Personal Team unsupported remote push, communication notifications and Apple
Pay are disabled for this development profile. Local notification authorization
still works. Remote registration actions are unavailable when native push is
unconfigured. `PersonalTeam.entitlements` retains App Group and Keychain sharing;
the original production entitlement file remains unchanged.

Validation on 2026-10-09:

- Genuine physical-device RED: two PersonalTeamNotificationTests failed.
- Physical-device GREEN: 21 tests passed, zero failed/skipped, across
  PersonalTeamNotificationTests, AppNotificationsRefreshTests,
  NativePushServerConfigValidationTests and DonationBuildConfigTests.
- The actual xcresult counts were independently rechecked before this commit.
- Production and Staging effective Xcode build settings were queried after
  separating entitlements: production retains all three capabilities; Staging
  selects the Personal Team file, retaining App Group/Keychain.
- Modified Swift ranges were formatted with the workspace four-space style.
  This checkout has no `.swift-format`; default strict lint reports existing
  style differences, so no whole-file lint pass is claimed.
- `git diff --check` passes. No full PR pass or post-isolation signed rebuild
  is claimed; the already installed phone baseline remains unchanged.

The original runs and compact verification records live in the parent workspace
`build/results/ios-personal-*`. Preserve the distinct development storage identity
when replacing the app. Full experimental sync integration is a separate gate.
