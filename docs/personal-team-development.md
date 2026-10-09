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

The initial complete Personal Team M5 simulator run executed 2,704 tests:
2,699 passed, three failed, two skipped. Two fixtures assumed available remote
push; one supplied a flavor URL instead of the canonical generated chat URL.
The fixtures now verify local authorization without remote registration in this
profile, require absent Personal Team push configuration, and exercise rejected
canonical chat destinations through the actual rendering/copy policy. Production
behavior is unchanged. All 99 tests in AppStateBootstrapTests,
AppContainerConfigTests and MessageLinkCopyTests passed after correction. The
actual result count, terminal log hash and two changed test-file hashes were
independently verified. The complete corrected-profile suite from signed `7622a09` then passed on M5:
2,702 passed, zero failed, two skipped (2,704 total), in 204.82 seconds. Root
independently verified the actual xcresult, terminal log hash, source commit and
clean worktree. Compact proof is in the parent workspace
`build/results/ios-personal-profile-full-pr-root-verification.json`.

Local experimental artifact installation now verifies the requested feature list
and exact source/builder commit before replacing the existing artifact. Both the
compiled Swift provenance and `MARMOT_VERSION` record the actual features and
source branch. Four isolated installer regressions failed against the previous
script, then all four passed; one compiles and executes the emitted Swift
provenance. Four existing published-binding coherence tests also pass. These
checks use synthetic build outputs and do not establish a native experimental
build, exported linking API or message synchronization.
