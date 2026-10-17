# Owned loopback relay for native tests

The native secret-store tests create an actual SDK identity, publish its setup
records, reopen its runtime and verify the supplied secret-store callback. They
need a running Nostr relay; a socket placeholder does not exercise that path.

This pinned `nostr-relay-builder` fixture binds only IPv4 loopback and keeps its
synthetic events in memory. It prints only its URL and aggregate admission count.
The dependencies and lockfile match the workspace's existing sync test relay.

Build and run from the repository root:

```sh
cargo build --locked --manifest-path scripts/test-relay/Cargo.toml --target-dir build/TestRelay
scripts/test-with-relay.sh -only-testing:whitenoise-iosTests/NativeSecretStoreBoundaryTests
```

The wrapper refuses an occupied port, owns its child process, checks a real
WebSocket/Nostr query before dispatch and cleans up after the test command.
`WN_TEST_RELAY_PORT` selects another port; `WN_TEST_RELAY_BINARY` selects the built
fixture. Xcode forwards its URL through `TEST_RUNNER_WN_NATIVE_TEST_RELAY_URL`.
The existing `scripts/test.sh` still works when the caller already manages a relay.

GitHub builds the fixture and runs the published-SDK app tests through this
wrapper. Experimental SDK packaging, original pairing, multi-device convergence,
physical UI recovery and TestFlight interoperability remain separate checks.
