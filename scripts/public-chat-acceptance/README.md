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
no failures or skips. It does not establish private sync or TestFlight UI parity.

Run `--scenario unpaired-installations` with a fresh output directory to reproduce
two independently stored installations of one fresh recipient identity. Both
remain online; the newer installation receives and decrypts the invitation while
the original shows no request during a bounded five-second observation. The same
behavior occurs when the selected newer installation is offline: it receives the
request on reopening, while the original stays online. `unpaired-qualification.json`
records both sponsor directions passing. This proves the ownership hazard in these
cohorts, not the cause of an unobserved TestFlight incident. The synthetic nsec
travels only through private worker pipes; no database is transferred.

Run `--scenario publication-rejection` with a fresh output directory to reject
Welcome and group-message publications temporarily, restore acknowledgements,
and reopen the sender's original state. This checks the same group and exact
retained message; it never masks failed recovery with another create/send call.
Both sponsor directions pass in `publication-qualification.json`.

This scenario requires the pinned small Python dependency in an isolated venv:

```sh
python3 -m venv /absolute/test-venv
/absolute/test-venv/bin/python -m pip install -r scripts/public-chat-acceptance/requirements.txt
# Run controller.py with that interpreter and --scenario publication-rejection.
```

The controller creates a bounded WebSocket proxy on `--port + 1`, using only
loopback sockets. It returns temporary NIP-20 `error:` ACKs for selected outer
event kinds and forwards all other traffic to the same real relay. Neither
proxy nor controller logs frames. Both processes are drained before their
owned relay stops. The custom policy hook in `nostr-relay-builder` always
prefixes rejection with `blocked:`; permanent rejection is deliberately a
different test. The initial permanent-rejection observation and the harness's
wrong summary assumption remain diagnosed in the compact qualification record.

The proxy uses the official [websockets asyncio server/client APIs](https://websockets.readthedocs.io/en/15.0/reference/asyncio/server.html).
No production SDK wire format or published binding pin changes in these tests.

## Explicit companion onboarding

The additive worker commands let controllers exercise supported sign-in without
silently acknowledging a notice in `import`:

- `onboarding-begin` takes the synthetic identity's secret over private IPC.
- `onboarding-run` and `onboarding-status` return the actual native revision,
  offered steps/actions, readiness and aggregate single-device notice.
- `onboarding-ack` forwards the displayed `revision` to the native original.
- `onboarding-continue-without` requires the displayed revision and an offered
  `step`; it calls the public native continuation rather than modifying storage.
- `package-observation` returns counts and a digest of sorted public slot IDs.
- `invitation-observation` returns group/pending counts and booleans for the
  supplied group. Existing `invitations` and `accept` remain unchanged.

Never print worker IPC secrets, account IDs, group IDs or message bodies in
public evidence. Package observations are discovery facts, not device authority.
Published0.12 may publish a new companion slot; preservation of an experimental
receiver must be checked against that separate candidate, not assumed here.

For native Mac worker operation controls, use the workspace
`tools/build-mac-public-chat-worker.sh` with matching published Swift/header/static
archive, then run:

```sh
python3 scripts/public-chat-acceptance/onboarding_controls.py \
  --worker /absolute/published-native-worker \
  --relay-binary /absolute/white-noise-sync-test-relay \
  --port 18249 --output /absolute/fresh-private-output
```

This performs actual notice/revision/readiness/reopen controls with independent
synthetic stores on a real loopback relay. It does not establish cross-version
ordinary delivery or an installed TestFlight journey. Use the existing
`controller.py` invitation/accept/send/offline checks with separately linked
published and final experimental workers for that qualification.

## Supported companion cross-version controller

`companion_controller.py` accepts the same worker protocol with either dedicated
simulators (`--published-device` / `--experimental-device`) or `native-mac`.
It performs explicit companion onboarding against the candidate's real primary,
checks the experimental public slot-set stays unchanged after approval and
companion reopen, then tests both creator directions, explicit invitations,
exact bidirectional messages, and offline message/invitation replay for both
primary stores. Stores and secrets remain isolated and are never copied.

```sh
python3 scripts/public-chat-acceptance/companion_controller.py \
  --published /absolute/published-worker \
  --experimental /absolute/final-experimental-worker \
  --published-sdk-source FULL_PUBLISHED_SOURCE_SHA \
  --experimental-sdk-source FULL_EXPERIMENTAL_SOURCE_SHA \
  --relay-binary /absolute/white-noise-sync-test-relay \
  --port 18250 --output /absolute/fresh-private-output
```

Cross-version mode requires different source pins and executable hashes. Record
matching generated Swift/header/archive provenance for each worker separately;
a source label alone does not authenticate the linked SDK.

`--published-control` permits two retained published executables solely to test
controller operation. Published0.12 creates a companion public slot, so this
mode explicitly republishes the primary's genuine public package before chat
creation. It reports that repair and never qualifies the experimental receiver
hold. Experimental mode performs no such repair. Installed TestFlight/UI/APNS
acceptance remains separate.
