#!/usr/bin/env python3
"""Exercise explicit worker onboarding on fresh native Mac stores and real relay."""
import argparse, hashlib, json, os, pathlib, select, subprocess

class Peer:
    def __init__(self, binary, root, relay, log):
        self.log = log.open('xb')
        self.p = subprocess.Popen([str(binary), str(root), relay], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=self.log)
    def ask(self, command, **args):
        self.p.stdin.write((json.dumps(dict(command=command, **args))+'\n').encode()); self.p.stdin.flush()
        if not select.select([self.p.stdout], [], [], 60)[0]:
            raise RuntimeError('worker-response-timeout')
        response = json.loads(self.p.stdout.readline())
        return response
    def close(self):
        response=self.ask('close')
        assert response['ok']; assert self.p.wait(timeout=30)==0
        self.log.close()

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--worker',type=pathlib.Path,required=True)
    ap.add_argument('--relay-binary',type=pathlib.Path,required=True)
    ap.add_argument('--output',type=pathlib.Path,required=True)
    ap.add_argument('--port',type=int,default=18249)
    a=ap.parse_args(); os.umask(0o077); a.output.mkdir(mode=0o700)
    relaylog=(a.output/'relay.stderr').open('xb')
    relay=subprocess.Popen([str(a.relay_binary),'--port',str(a.port)], stdout=subprocess.PIPE,stderr=relaylog)
    peers=[]; checks=[]
    try:
        assert select.select([relay.stdout],[],[],15)[0]
        endpoint=relay.stdout.readline().decode().strip(); assert endpoint==f'ws://127.0.0.1:{a.port}'
        first=Peer(a.worker,a.output/'primary',endpoint,a.output/'primary.stderr'); peers.append(first)
        identity=first.ask('create'); assert identity['ok']
        secret=first.ask('secret')['value']['secret']
        before=first.ask('package-observation'); assert before['ok'] and before['value']['count']>0
        second=Peer(a.worker,a.output/'companion',endpoint,a.output/'companion.stderr');peers.append(second)
        begin=second.ask('onboarding-begin',secret=secret); del secret
        assert begin['ok'] and not begin['value']['ready']
        state=second.ask('onboarding-run');assert state['ok']
        state=state['value']; notice=state.get('notice');assert notice and notice['other_package_count']>0
        stale=second.ask('onboarding-ack',revision=state['revision']+1);assert not stale['ok']
        unchanged=second.ask('onboarding-status')['value'];assert unchanged==state
        checks.append('actual-companion-notice-and-stale-revision-refusal')
        for _ in range(32):
            if state['ready']:break
            step=next((s for s in state['steps'] if s['status'] in ('needsInput','retryableFailure')),None)
            if step and step['step']=='singleDevice' and 'continueAnyway' in step['actions']:
                response=second.ask('onboarding-ack',revision=state['revision'])
            elif step and 'continueWithout' in step['actions']:
                response=second.ask('onboarding-continue-without',revision=state['revision'],step=step['step'])
            else:response=second.ask('onboarding-run')
            assert response['ok'];state=response['value']
        assert state['ready']; checks.append('actual-displayed-action-ready')
        second.close();peers.remove(second)
        second=Peer(a.worker,a.output/'companion',endpoint,a.output/'companion-reopened.stderr');peers.append(second)
        assert second.ask('reopen')['ok']
        assert second.ask('onboarding-status')['value']==state
        observation=second.ask('invitation-observation');assert observation['ok'] and observation['value']['pending_count']==0
        checks.append('encrypted-original-reopen-and-pending-observation')
        after=first.ask('package-observation');assert after['ok']
        for p in list(peers):p.close();peers.remove(p)
        result={'passed':len(checks),'failed':0,'checks':checks,
                'worker_sha256':hashlib.sha256(a.worker.read_bytes()).hexdigest(),
                'slot_set_unchanged':before['value']['slot_set_digest']==after['value']['slot_set_digest'],
                'scope':'Published native worker explicit onboarding and observation controls only; no experimental receiver hold or cross-version delivery claim'}
        (a.output/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
    finally:
        for p in peers:
            if p.p.poll() is None:p.p.terminate();p.p.wait(timeout=30)
            p.log.close()
        relay.terminate();relay.wait(timeout=30);relaylog.close()
if __name__=='__main__':main()
