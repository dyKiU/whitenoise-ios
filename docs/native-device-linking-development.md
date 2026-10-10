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
