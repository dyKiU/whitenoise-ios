# Private native device-linking development

Install matching local bindings with `EXPERIMENTAL_DEVICE_SYNC=1` using the
existing local installer, then run `WN_EXPERIMENTAL_DEVICE_SYNC=1 scripts/test.sh`.
The app flag defaults off. Its preflight requires matching full source/builder
commits, both exporters plus experimental device sync, and unchanged generated
Swift and iOS device/simulator archives. `WN_TEST_JOBS` optionally bounds Xcode
workers; trailing test-selection arguments apply to test-without-building.

Matched clean MDK `e6b0e9c1` builds and validates Mac, iOS device and arm64
simulator artifacts. The M5 Staging simulator focused run passes 57 tests,
including five real isolated native runtime tests. Its full suite passes 2,709
tests, zero failures and two existing skips. See the adjacent verification JSON
for complete log hashes and independently checked 773-input freezes. Earlier
diagnostics, timestamp, fixture and opaque-row-equality compile failures are
recorded as compiler failures, not behavioral regressions.

The compatibility paths preserve canonical timestamp literal content and compare
actual chat-row presentation values, excluding opaque SDK draft lease handles.
They do not supply live localized timestamp rendering. The published-SDK baseline also passes 2,702 tests with zero failures and the
same two skips. The initial reused-cache FFI header/module mismatch was resolved
by retiring only three named FFI precompiled modules after Xcode stopped. Fresh application pairing, selected-chat consent,
ordinary membership/message delivery and history remain separate acceptance
gates. M1 has rebuilt and strictly verified the Personal Team app and notification
extension with the matched experimental SDK. Signing, App Group identity and
disabled unsupported capability checks pass; the provisioning profiles expire
on 2026-10-16. The prior signed published-SDK build is retained as a rollback
copy. Physical iPhone installation remains deferred.

The matched native Staging app is installed and running in the dedicated M5
simulator. Its installed executable and linked debug library hashes match the
qualified build. The previous app and closed app/App Group storage are preserved
as one rollback copy. The first launch wrapper misclassified an already stopped
app (POSIX3); recovery reused the successful build after verifying no old app or
extension process. This launch does not qualify fresh pairing or delivery.

## iOS app wrapper boundary

The feature-gated `MarmotClient` now forwards capabilities, targets, pending
approvals, new-device sessions and approver sessions. The existing five isolated
native runtime tests call these app wrappers, retaining the original opaque SDK
objects and typed missing-account failures. On M5 the focused Staging simulator
run passed all five tests with no failures or skips in102.71 seconds, using the
existing matched `e6b0e9c1` archive and Xcode cache. See
`native-device-linking-wrapper-verification.json` for exact input/log hashes.
Generated local binding overrides remain uncommitted and unchanged. This is
capability and missing-account qualification; fresh pairing, account-owned UI,
selected-chat admission, delivery and history are still separate gates.

## Account-owned original session lifetime

The experimental AccountStore now holds one original opaque DeviceLinkingSession
and its subscription in a Session scope. Account replacement immediately removes
the old owner, closes its subscription and cancels that exact object. Late
snapshots cannot populate the replacement account. Cleanup failure remains on
the retired owner for explicit retry; a new owner cannot bypass it. No snapshot
is persisted or used to reconstruct SDK permission.

Runtime suspension waits for original cancellation before closing Core. Sign-out
and wipe use the same boundary, acquire the existing exit guard before any new
await, and refuse account mutation on cancellation failure. Terminal runtime
shutdown still releases SQLite after recording a failed exact cleanup.

M5 focused checks passed eight lifecycle tests, five existing factory smoke tests
and fifteen existing sign-out/wipe tests, with no failures or skips. Observable
regressions first failed replacement/suspension (0/2) and concurrent exit (0/1).
Tests use generated opaque-object doubles for delayed subscription and cancellation
controls, plus actual isolated native runtime/storage routes; this is lifetime
qualification, not fresh SDK pairing, selected-chat approval or delivery. See
`native-device-linking-lifetime-verification.json` for hashes, original RED source
preservation, compiler failures and the secondary RED diagnostics tooling failure.
The four local generated e6 SDK overrides remain unchanged and uncommitted.

## Factory-to-owner adoption

Experimental AppState entrypoints now call the real MarmotClient begin/approve
factories and retain the original returned session through AccountStore. One
pending factory is bound to a private owner epoch plus exact runtime identity
and generation. Replacement (including A→B→A), suspension and teardown invalidate
the reservation synchronously. Core close does not wait for a cancellation-ignoring
factory. Its exact late returned session is never adopted; its subscription closes
and failed cancellation remains retained for explicit retry. These epochs are
negative native lifetime fences, not SDK permission or persisted approval.

The real stale-result regression failed first (one parameterized test, both
replacement and suspension cases). Final M5 checks passed thirteen lifecycle tests
and twenty existing factory/sign-out/wipe tests with no failures or skips. Controls
include same-account actual runtime restart, bounded competing factories, exact
late cleanup failure/retry, current original-object adoption and typed real SDK
missing-account errors through both App entrypoints. Original RED source was
preserved before Green in a named Git stash and matched the recorded manifest.

Hosted Xcode tests implicitly install and launch their Staging test host in the
dedicated simulator. Read-only post-test inspection confirms its executable and
linked debug library match the tested product; the older installed executable
provenance is not asserted unchanged. No account data was inspected or modified
manually. See `native-device-linking-factory-verification.json` for current hashes,
compiler/runner failures, exact counts and scope. Fresh pairing, native UI, selected
chat admission, delivery and history remain separate gates.

### Full lifecycle qualification — 2026-10-10

Signed product source `3402bb997829c866238055be1db302889a40b53d` passes the
full Staging suite with the matched experimental e6 SDK:2,722 passed, zero
failures, two existing skips. Published0.12 default passes2,702 with zero
failures and the same two skips. Root independently verifies all780 frozen
inputs and complete terminal logs for both gates. Three compile-only published
attempts diagnose separate stale FFI precompiled modules; only the exact named
modules are retired after the target is idle. All share the final published
input manifest; none ran tests. The four experimental overrides are retained
in a named Git stash and restored byte for byte; all780 previous experimental
inputs match again. See `native-device-linking-full-verification.json`.

This qualifies application regressions for session ownership and delayed-factory
fencing. Fresh pairing, ordinary recipient admission/delivery and history remain
open. Hosted tests installed the published test host last; do not claim its binary
is experimental until a new experimental rebuild. Physical installation stays
deferred; the existing signed M1 ready build is preserved.
