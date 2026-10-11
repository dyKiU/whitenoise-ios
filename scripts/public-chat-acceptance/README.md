# Native iOS ordinary-chat acceptance

This runner exercises the real published and experimental MarmotKit iOS archives
inside separate iOS simulators against a fresh, loopback-only Nostr relay. It is
an SDK transport test, not an installed-app navigation or APNS test. The actual
TestFlight build remains a separate physical-device acceptance gate.

Each direction creates fresh independent identities and private state directories,
publishes ordinary KeyPackages, creates an ordinary current-profile chat, receives
and explicitly accepts the invitation, and verifies authenticated exact message
IDs, senders and synthetic content in both directions. It then reopens the
receiver's original state to check offline message and invitation replay. It never
copies a database or uses private pairing packages.

Build each worker against its own matching generated Swift source and native
simulator archive (reuse the appropriate module cache):

```sh
scripts/public-chat-acceptance/build.sh \
  /absolute/MarmotKit.swift /absolute/ios-arm64-simulator \
  /absolute/worker /absolute/module-cache
```

Run on the simulator host, using two dedicated booted simulator IDs and the
workspace `tools/sync-test-relay` executable:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 scripts/public-chat-acceptance/controller.py \
  --published /absolute/published-worker \
  --experimental /absolute/experimental-worker \
  --published-device PUBLISHED_SIMULATOR_ID \
  --experimental-device EXPERIMENTAL_SIMULATOR_ID \
  --relay-binary /absolute/white-noise-sync-test-relay \
  --port 18182 --output /absolute/fresh-output-directory
```

The runner owns only its new relay and workers. Output directories must be fresh;
reopened worker roots must contain the harness marker. SDK logs and state stay in
private task directories. Worker IPC can contain synthetic identities/secrets;
never echo, upload or commit it. Only aggregate `result.json` may be retained as
public qualification evidence. The test callback stores synthetic secrets in an
AES-GCM file with a separate key under that private directory; it is not a
production credential-store design. Normal output contains counts, booleans,
stage names and worker artifact hashes only.

`qualification.json` records the first passing matrix: two sponsor directions,
no failures or skips. It does not establish sender publication-failure recovery,
same-account unpaired-installation behavior, private sync, or TestFlight UI parity.
