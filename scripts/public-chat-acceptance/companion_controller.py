#!/usr/bin/env python3
"""Supported companion sign-in and ordinary interop using separately linked native workers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import select
import subprocess
import time

import controller as harness


class NativePeer(harness.Peer):
    def __init__(self, binary, device, state, relay, log):
        if device != 'native-mac':
            super().__init__(binary, device, state, relay, log)
            return
        self.log = log.open('xb')
        os.chmod(log, 0o600)
        self.process = subprocess.Popen([binary, str(state), relay], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.log)


def complete_companion(primary, companion):
    secret = primary.ask('secret')['secret']
    begun = companion.ask('onboarding-begin', secret=secret)
    del secret
    harness.require(not begun['ready'], 'companion-begin-is-gated')
    state = companion.ask('onboarding-run')
    notice = state.get('notice')
    harness.require(notice and notice['other_package_count'] > 0, 'real-other-installation-notice')
    denied = companion.ask('onboarding-ack', allow_error='refused', revision=state['revision'] + 1)
    harness.require(denied.get('error_category') == 'refused', 'stale-displayed-revision-refused')
    harness.require(companion.ask('onboarding-status') == state, 'stale-ack-has-no-effects')
    for _ in range(32):
        if state['ready']:
            return state
        step = next((s for s in state['steps'] if s['status'] in ('needsInput', 'retryableFailure')), None)
        if step and step['step'] == 'singleDevice' and 'continueAnyway' in step['actions']:
            state = companion.ask('onboarding-ack', revision=state['revision'])
        elif step and 'continueWithout' in step['actions']:
            state = companion.ask('onboarding-continue-without', revision=state['revision'], step=step['step'])
        else:
            state = companion.ask('onboarding-run')
    raise harness.Failure('companion-never-ready')


def direction(versions, sponsor, root, endpoint, peers, published_control):
    def open_peer(index, install, suffix):
        binary, device, _ = versions[index]
        peer = NativePeer(binary, device, root / install, endpoint, root / (install + suffix + '.stderr'))
        peers.append(peer)
        return peer
    def close(peer):
        peer.close()
        peers.remove(peer)
    a = open_peer(0, 'published-primary', '-initial')
    b = open_peer(1, 'candidate-primary', '-initial')
    ids = [a.ask('create')['account'], b.ask('create')['account']]
    harness.require(ids[0] != ids[1], 'independent-ordinary-identities')
    before = b.ask('package-observation')
    harness.require(before['count'] > 0, 'candidate-original-public-slot')
    companion = open_peer(1, 'candidate-companion', '-initial')
    snapshot = complete_companion(b, companion)
    harness.require(snapshot['account'] == ids[1], 'same-identity-independent-companion')
    after = b.ask('package-observation')
    unchanged = before['slot_set_digest'] == after['slot_set_digest']
    if not published_control:
        harness.require(unchanged, 'experimental-companion-preserves-receiver-slotset')
    close(companion)
    companion = open_peer(1, 'candidate-companion', '-reopened')
    harness.require(companion.ask('reopen')['account'] == ids[1], 'same-companion-encrypted-reopen')
    harness.require(companion.ask('onboarding-status') == snapshot, 'durable-companion-original-snapshot')
    reopened = b.ask('package-observation')
    if not published_control:
        harness.require(reopened['slot_set_digest'] == before['slot_set_digest'],
                        'experimental-reopen-preserves-receiver-slotset')
    else:
        # Published0.12 has no companion hold. This declared control-only
        # fresh publication restores the primary as a valid public recipient;
        # experimental qualification never uses this repair.
        time.sleep(2)
        b.ask('publish')
    primary = [a, b]
    source, recipient = primary[sponsor], primary[1-sponsor]
    group = source.ask('create-chat', member=ids[1-sponsor])['group']
    harness.wait_for(lambda: recipient.ask('invitation-observation', group=group)['requested_group_pending'],
                     'actual-primary-invitation')
    if not published_control and sponsor == 0:
        harness.require(not companion.ask('invitation-observation', group=group)['requested_group_present'],
                        'held-companion-is-not-an-ordinary-member')
    recipient.ask('accept', group=group)
    for peer in primary:
        state = peer.ask('state', group=group)
        harness.require(state['current'] and state['members'] == 2, 'actual-two-member-current-group')
    for index in (sponsor, 1-sponsor):
        text = 'isolated-supported-signin-direction-' + str(index)
        sent = primary[index].ask('send', group=group, text=text)
        harness.check_message(primary[1-index], group, sent, text, ids[index], 'exact-bidirectional-delivery')
    for offline_index in (0, 1):
        online_index = 1 - offline_index
        install = 'published-primary' if offline_index == 0 else 'candidate-primary'
        source = primary[online_index]
        close(primary[offline_index])
        text = 'isolated-primary-offline-record-' + str(offline_index)
        sent = source.ask('send', group=group, text=text)
        recipient = open_peer(offline_index, install, '-message-reopened')
        harness.require(recipient.ask('reopen')['account'] == ids[offline_index], 'primary-original-reopen')
        harness.check_message(recipient, group, sent, text, ids[online_index], 'exact-offline-primary-message-replay')
        close(recipient)
        offline_group = source.ask('create-chat', member=ids[offline_index])['group']
        harness.require(offline_group != group, 'distinct-offline-invitation')
        recipient = open_peer(offline_index, install, '-invite-reopened')
        harness.require(recipient.ask('reopen')['account'] == ids[offline_index], 'primary-second-original-reopen')
        harness.wait_for(lambda: recipient.ask('invitation-observation', group=offline_group)['requested_group_pending'],
                         'offline-primary-invitation-replay')
        recipient.ask('accept', group=offline_group)
        text = 'isolated-replayed-invitation-record-' + str(offline_index)
        harness.check_message(recipient, offline_group, source.ask('send', group=offline_group, text=text),
                              text, ids[online_index], 'exact-message-after-offline-invitation-acceptance')
        primary[offline_index] = recipient
    for peer in (primary[1], companion, primary[0]):
        close(peer)
    return {'creator': versions[sponsor][2], 'explicit_companion_revision_controls': True,
            'companion_encrypted_reopen': True, 'slot_set_unchanged_after_approval': unchanged,
            'experimental_slot_hold_qualified': not published_control,
            'published_control_primary_republication': published_control,
            'ordinary_explicit_accept': True, 'exact_bidirectional_delivery': True,
            'both_primaries_offline_message_replay': True, 'both_primaries_offline_invitation_accept_replay': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--published', required=True)
    parser.add_argument('--experimental', required=True)
    parser.add_argument('--published-device', default='native-mac')
    parser.add_argument('--experimental-device', default='native-mac')
    parser.add_argument('--published-sdk-source', required=True)
    parser.add_argument('--experimental-sdk-source', required=True)
    parser.add_argument('--published-control', action='store_true')
    parser.add_argument('--relay-binary', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--port', type=int, default=18250)
    args = parser.parse_args()
    for source in (args.published_sdk_source, args.experimental_sdk_source):
        harness.require(re.fullmatch('[0-9a-f]{40}', source), 'full-sdk-source-pins-required')
    hashes = [hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in (args.published, args.experimental)]
    if not args.published_control:
        harness.require(hashes[0] != hashes[1] and args.published_sdk_source != args.experimental_sdk_source,
                        'separately-linked-cross-version-workers-required')
    os.umask(0o077)
    harness.require(not args.output.exists(), 'fresh-private-output-required')
    args.output.mkdir(parents=True, mode=0o700)
    relay_log = (args.output / 'relay.stderr').open('xb')
    relay = subprocess.Popen([args.relay_binary, '--port', str(args.port)], stdout=subprocess.PIPE,stderr=relay_log)
    peers, checks, failure = [], [], None
    try:
        harness.require(select.select([relay.stdout], [], [], 15)[0], 'relay-start-timeout')
        endpoint = relay.stdout.readline().decode().strip()
        harness.require(endpoint == 'ws://127.0.0.1:' + str(args.port), 'isolated-loopback-relay')
        versions = [(args.published,args.published_device,'published'),
                    (args.experimental,args.experimental_device,'candidate')]
        for sponsor in (0,1):
            root = args.output / ('creator-' + str(sponsor)); root.mkdir(mode=0o700)
            checks.append(direction(versions,sponsor,root,endpoint,peers,args.published_control))
    except (harness.Failure,OSError,ValueError,subprocess.SubprocessError) as error:
        failure = str(error) if isinstance(error,harness.Failure) else 'controller-refused'
    finally:
        for peer in peers:
            try: peer.close()
            except Exception: failure = failure or 'cleanup-failed'
        if relay.poll() is None:
            relay.terminate()
            try: relay.wait(timeout=10)
            except subprocess.TimeoutExpired: relay.kill();relay.wait()
        relay.stdout.close();relay_log.close()
    result={'passed':len(checks),'failed':int(failure is not None),'failure':failure,'checks':checks,
            'published_control':args.published_control,'published_sha256':hashes[0],'experimental_sha256':hashes[1],
            'published_sdk_source':args.published_sdk_source,'experimental_sdk_source':args.experimental_sdk_source,
            'controller_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'scope':'Real native separate stores and local relay; no installed app/TestFlight/APNS claim'}
    (args.output/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
    return int(failure is not None)
if __name__=='__main__':raise SystemExit(main())
