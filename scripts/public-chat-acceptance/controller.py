#!/usr/bin/env python3
"""Isolated iOS native public-chat acceptance; stdout contains aggregate results only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import time


class Failure(Exception):
    pass


def require(condition, stage):
    if not condition:
        raise Failure(stage)


class Peer:
    def __init__(self, binary, device, state, relay, log):
        self.log = log.open('xb')
        os.chmod(log, 0o600)
        self.process = subprocess.Popen(
            ['xcrun', 'simctl', 'spawn', device, binary, str(state), relay],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)

    def ask(self, command, **fields):
        self.process.stdin.write(json.dumps({'command': command, **fields}).encode() + b'\n')
        self.process.stdin.flush()
        deadline = time.monotonic() + 90
        line = bytearray()
        while not line.endswith(b'\n'):
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise Failure('worker-timeout-' + command)
            byte = os.read(self.process.stdout.fileno(), 1)
            if not byte or len(line) > 65536:
                raise Failure('worker-output-refused')
            line.extend(byte)
        result = json.loads(line)
        require(result.get('ok'), 'worker-' + command + '-' + result.get('category', 'invalid'))
        return result['value']

    def close(self):
        try:
            self.ask('close')
            self.process.wait(timeout=10)
            require(self.process.returncode == 0, 'worker-close')
        finally:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
            self.process.stdin.close()
            self.process.stdout.close()
            self.log.close()


def wait_for(predicate, stage):
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise Failure(stage)


def check_message(peer, group, sent, text, sender, stage):
    require(len(sent['messages']) == 1 and sent['published'] > 0, stage + '-publication')
    message = sent['messages'][0]
    wait_for(lambda: peer.ask('has-message', group=group, message=message,
                             text=text, sender=sender)['matches'] == 1, stage)


def unpaired_installations(versions, sponsor, cohort, endpoint, peers):
    def open_peer(index, installation, suffix):
        binary, device, name = versions[index]
        peer = Peer(binary, device, cohort / installation, endpoint,
                    cohort / (installation + suffix + '.stderr'))
        peers.append(peer)
        return peer
    a = open_peer(sponsor, 'sponsor', '-initial')
    b = open_peer(1 - sponsor, 'original-recipient', '-initial')
    a_id = a.ask('create')['account']
    b_id = b.ask('create')['account']
    require(a_id != b_id, 'independent-identities')
    b.ask('publish')
    wait_for(lambda: b.ask('packages')['count'] > 0, 'initial-package-publication')
    # Deliberately import only a fresh synthetic identity, never MLS state.
    # Wait past the original event timestamp before the new installation publishes.
    time.sleep(2)
    c = open_peer(1 - sponsor, 'second-recipient', '-initial')
    secret = b.ask('secret')['secret']
    require(c.ask('import', secret=secret)['account'] == b_id, 'same-synthetic-account')
    del secret
    c.ask('publish')
    wait_for(lambda: c.ask('packages')['count'] >= 2, 'multiple-installation-packages')
    group = a.ask('create-chat', member=b_id)['group']
    wait_for(lambda: group in c.ask('invitations')['groups'], 'new-installation-invitation')
    # Both installations are awake and polling, but only one owns this package.
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        require(group not in b.ask('invitations')['groups'], 'unexpected-original-invitation')
        time.sleep(0.2)
    c.ask('accept', group=group)
    state = c.ask('state', group=group)
    require(state['current'] and state['members'] == 2, 'ordinary-current-group')
    text = 'synthetic-second-installation'
    check_message(c, group, a.ask('send', group=group, text=text), text, a_id,
                  'selected-installation-message')
    c.close(); peers.remove(c)
    offline_group = a.ask('create-chat', member=b_id)['group']
    require(offline_group != group, 'independent-offline-invitation')
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        require(offline_group not in b.ask('invitations')['groups'], 'unexpected-online-original-invitation')
        time.sleep(0.2)
    c = open_peer(1 - sponsor, 'second-recipient', '-reopened')
    require(c.ask('reopen')['account'] == b_id, 'original-second-installation-reopen')
    wait_for(lambda: offline_group in c.ask('invitations')['groups'], 'selected-offline-installation-replay')
    c.ask('accept', group=offline_group)
    for peer in (c, b, a):
        peer.close(); peers.remove(peer)
    return {'sponsor': versions[sponsor][2], 'same_account_independent_stores': True,
            'newer_installation_received_invitation': True,
            'original_installation_received_no_invitation_during_observation': True,
            'selected_installation_authenticated_message': True,
            'selected_offline_installation_received_on_reopen': True,
            'online_original_received_no_offline_invitation_during_observation': True,
            'negative_observation_seconds': 5}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--published', required=True)
    parser.add_argument('--experimental', required=True)
    parser.add_argument('--published-device', required=True)
    parser.add_argument('--experimental-device', required=True)
    parser.add_argument('--relay-binary', required=True)
    parser.add_argument('--scenario', choices=['mixed-version', 'unpaired-installations'], default='mixed-version')
    parser.add_argument('--port', type=int, default=18182)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    require(not args.output.exists(), 'fresh-output-required')
    args.output.mkdir(parents=True, mode=0o700)
    relay_log = (args.output / 'relay.stderr').open('xb')
    relay = subprocess.Popen([args.relay_binary, '--port', str(args.port)],
                             stdout=subprocess.PIPE, stderr=relay_log)
    peers = []
    checks = []
    failure = None
    try:
        require(select.select([relay.stdout], [], [], 15)[0], 'relay-start-timeout')
        endpoint = relay.stdout.readline().decode().strip()
        require(endpoint == 'ws://127.0.0.1:' + str(args.port), 'isolated-relay-endpoint')
        versions = [(args.published, args.published_device, 'published'),
                    (args.experimental, args.experimental_device, 'experimental')]
        for sponsor in (0, 1):
            cohort = args.output / ('sponsor-' + versions[sponsor][2])
            cohort.mkdir(mode=0o700)
            if args.scenario == 'unpaired-installations':
                checks.append(unpaired_installations(versions, sponsor, cohort, endpoint, peers))
                continue
            def open_peer(index, suffix):
                binary, device, name = versions[index]
                peer = Peer(binary, device, cohort / name, endpoint, cohort / (name + suffix + '.stderr'))
                peers.append(peer)
                return peer
            a = open_peer(sponsor, '-initial')
            b = open_peer(1 - sponsor, '-initial')
            a_id = a.ask('create')['account']
            b_id = b.ask('create')['account']
            require(a_id != b_id, 'independent-identities')
            for peer in (a, b):
                peer.ask('publish')
                wait_for(lambda: peer.ask('packages')['count'] > 0, 'public-key-package-publication')
            group = a.ask('create-chat', member=b_id)['group']
            wait_for(lambda: group in b.ask('invitations')['groups'], 'public-invitation-receipt')
            b.ask('accept', group=group)
            for peer in (a, b):
                state = peer.ask('state', group=group)
                require(state['current'] and state['members'] == 2, 'ordinary-two-member-current-group')
            text = 'synthetic-forward-' + str(sponsor)
            check_message(b, group, a.ask('send', group=group, text=text), text, a_id, 'forward-authenticated-message')
            text = 'synthetic-reverse-' + str(sponsor)
            check_message(a, group, b.ask('send', group=group, text=text), text, b_id, 'reverse-authenticated-message')
            b.close(); peers.remove(b)
            text = 'synthetic-offline-' + str(sponsor)
            sent = a.ask('send', group=group, text=text)
            b = open_peer(1 - sponsor, '-reopened')
            require(b.ask('reopen')['account'] == b_id, 'original-account-reopen')
            check_message(b, group, sent, text, a_id, 'offline-message-replay')
            b.close(); peers.remove(b)
            second = a.ask('create-chat', member=b_id)['group']
            require(second != group, 'independent-offline-invitation')
            b = open_peer(1 - sponsor, '-second-reopen')
            require(b.ask('reopen')['account'] == b_id, 'original-account-second-reopen')
            wait_for(lambda: second in b.ask('invitations')['groups'], 'offline-invitation-replay')
            b.ask('accept', group=second)
            checks.append({'sponsor': versions[sponsor][2], 'invitation': True,
                           'bidirectional_authenticated_messages': True, 'receiver_restart': True,
                           'offline_message': True, 'offline_invitation': True})
            b.close(); peers.remove(b)
            a.close(); peers.remove(a)
    except (Failure, OSError, ValueError, subprocess.SubprocessError) as error:
        failure = str(error) if isinstance(error, Failure) else 'controller-refused'
    finally:
        for peer in peers:
            try:
                peer.close()
            except Exception:
                failure = failure or 'cleanup-failed'
        if relay.poll() is None:
            relay.send_signal(signal.SIGINT)
            try:
                relay.wait(timeout=5)
            except subprocess.TimeoutExpired:
                relay.kill(); relay.wait()
        relay.stdout.close(); relay_log.close()
    result = {'gate': 'ios-public-chat-' + args.scenario, 'passed': len(checks),
              'failed': int(failure is not None), 'failure': failure, 'checks': checks,
              'published_sha256': hashlib.sha256(Path(args.published).read_bytes()).hexdigest(),
              'experimental_sha256': hashlib.sha256(Path(args.experimental).read_bytes()).hexdigest(),
              'scope': 'Real iOS native SDKs on isolated simulators and loopback relay; no TestFlight UI/APNS claim'}
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return int(failure is not None)


if __name__ == '__main__':
    raise SystemExit(main())
