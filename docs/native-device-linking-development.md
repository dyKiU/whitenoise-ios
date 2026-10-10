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

### Original-session verification actions — 2026-10-10

The account scope now forwards comparison confirmation with the exact displayed
revision and reads opaque outgoing SDK packets. Both operations check cancellation
and the original scope before and after awaiting the SDK. An account replacement
therefore discards a late packet result; SDK stale-revision errors remain errors.
No enrollment, continuation or finalization action is enabled.

Generated-protocol controls first demonstrate the missing host API: one passes
and three fail. The unchanged four tests then pass, followed by all 37 affected
action, account-lifetime, native-runtime and sign-out tests. Root independently
checks all 782 frozen inputs and complete logs for each run; only the scope
implementation changes between semantic RED and GREEN. The original RED is
retained in a named Git stash. See
`native-device-linking-owned-actions-verification.json` for hashes and scope.

These are host-boundary tests, including actual AccountStore replacement, rather
than fresh SDK pairing or message-delivery acceptance. The newer action slice
still needs full PR qualification before integration. Hosted tests have now
rebuilt the experimental Staging test host; the previous published-host statement
above records the earlier full-suite stage. Physical installation remains deferred.

The signed action slice `c5afa4f83803827a690ef71788c1ed4a396cd826`
subsequently passes both full Staging cohorts: experimental 2,726 and published
0.12 baseline 2,702, zero failures and two existing skips each. Root independently
checks all 783 inputs and complete logs for each cohort. Three published attempts
are compile-only stale FFI-header failures; only their exact named modules are
retired after the target stops. The four experimental overrides are restored
byte for byte, and all 783 preceding experimental inputs match again. See
`native-device-linking-owned-actions-full-verification.json`. The hosted simulator
product is now the published test host until the next experimental rebuild;
physical installation and fresh pairing/delivery remain unqualified.

### Original-owner opaque transport actions

The native account scope now forwards setup packet reads, setup/ordinary packet
receipt and explicit delivery acknowledgement to its original SDK session.
Retired scopes reject every action before touching that session; async operations
also revalidate after the SDK returns. Exact opaque bytes and acknowledgement IDs
are preserved, and SDK packet errors do not synthesize acknowledgements.
The genuine missing-feature regression passed1/failed2 before implementation,
then focused3/3 and affected40/40 passed on M5. Root independently verified all785
frozen inputs and full logs; only the runtime scope changed from RED to GREEN.
The exact RED source is retained in named Git stash `e08e67e1`.
See `native-device-linking-transport-verification.json` for compact evidence.
These generated-protocol controls do not qualify fresh native pairing or actual
chat delivery; full new-source qualification remains a separate gate.

The signed transport slice `de7b13a6` subsequently passed full experimental
Staging2,729 and published0.12 Staging2,702 tests, zero failures and the same two
existing skips. Root independently verified all786 frozen source inputs and
complete logs for both cohorts. Three published attempts compiled zero tests
because of stale FFI precompiled modules; only the diagnosed owned files were
retired after each target stopped. The preserved e6 overrides were restored and
all786 experimental inputs verified byte for byte before further work.
See `native-device-linking-transport-full-verification.json`. No physical
installation or fresh native pairing/delivery is implied by these full regressions.

## Account-owned verification display

The feature model uses only original scoped verification operations, composed in
Session through the existing AppState factories. Its current-owner check captures
the actual client, runtime generation and existing AccountStore ownership epoch;
A→B→A and runtime suspension cannot adopt or display an old result. That epoch is
observable negative identity, never SDK permission. No new counter, persisted
snapshot, enrollment action or permission constructor was added. Exact retired
cleanup remains in AccountStore; the feature exposes a negative cleanup-error state.

Missing-model RED0/2 was preserved before Green in named compact stash e3f46751.
Initial unchanged Green2/2 and final affected30/30 passed (model5 plus original
account lifetime, transport, owned actions and real factory controls). Three
zero-test named FFI PCM failures are preserved separately. Scoped strictSwiftLint
0.63.2 and Swiftformat6.2.3 pass. See native-device-verification-model-evidence.json.
The tests use generated-protocol controls with isolated actual AccountStore and
RuntimeLifecycle paths; they do not prove genuine SDK pairing or native UI.
Settings UI and final full experimental/published gates are next.

## Verification-only Settings pane

The experimental Settings pane composes its feature model from the original
account/runtime owner and resets local opaque packet display on ownership change.
It supports explicit start/approve, setup and packet transport, delivery ACK,
and comparison of the rendered SAS revision. Enrollment remains unavailable;
no continuation, permission DTO, retained snapshot reconstruction or global state
was added. The persistent input label, cancellation/error state and explicit ACK
remain separate from copying bytes.

Initial and final affected30/30 passed; the final source uses strict scoped
SwiftLint0.63.2 and Swiftformat6.2.3. Apple compiler stringsdata extraction and
XLIFF export/import added18 strings in nine existing target languages while
preserving all1,926 old entries. The first import was an accurately preserved
feature-off/e6 configuration failure; only its own newly-created idle output was
removed. See native-device-verification-settings-evidence.json. Full signed-source
experimental/published qualification follows; genuine fresh native pairing,
accessibility/visual acceptance and enrollment/chat delivery are separate gates.

The signed Settings product `3812b882` subsequently passed both full Staging
cohorts: experimental2,734 passed/zero failed/two existing skips; published0.12
2,702 passed/zero failed/two existing skips. All793 input paths were frozen
before/after each run. Three published attempts compiled zero tests due to stale
FFI modules; each exact compiler-named file was preserved after an idle check,
without broad cache deletion. All four e6 generated overrides were restored
byte for byte after the canonical published run. See
native-device-verification-settings-full-evidence.json. These are full regression
results, not native pairing, visual acceptance, enrollment or chat delivery proof.

## Original-owner enrollment forwards (development only)

The existing account scope now forwards explicit revision-bound `continueLinking`,
`enrollmentPacket`, `receiveEnrollmentPacket` and `finalizeLinking` to its retained
original SDK session. It checks native owner/task liveness before and after each
await; late packets after A→B→A or runtime suspension cannot escape the old scope.
SDK revision errors and exact opaque bytes pass through unchanged.

Default-deny missing-feature RED ran five tests and failed all five. The unchanged
controls passed five after implementation; affected original action, transport,
account lifetime and runtime-factory tests passed30/30. Strict scoped SwiftLint
0.63.2, Swiftformat6.2.3 and diff checks pass. Exact RED source is retained in a
named compact Git stash and verified against the frozen795-input manifest. See
native-device-linking-enrollment-scope-verification.json.

This is a scoped native forwarding/lifetime check, not actual SDK enrollment or
chat acceptance. The verification protocol, pane and advertised capability remain
unchanged. Separate original approval custody and enrollment model/UI are still
required. Xcode's hosted Staging test installation is separate from manual app
adoption; no physical phone or production app action occurred.
