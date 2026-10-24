#!/usr/bin/env python3
"""REMOTE metadata-only omission controls: three independent fresh P/F/P chains."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile

from bounded_capture import capture

HERE = Path(__file__).resolve().parent
CASES = [
    ('private-zero', 'validate_local_sdk_profile.py',
     "    require(private == ('0' if profile == 'default' else '1'), 'Private flag differs from SDK profile')",
     "    pass  # REMOTE METADATA MUTANT: omit only profile/private agreement",
     'test_default_rejects_private_one'),
    ('trusted-git-lock', 'sdk_profiles.py',
     "proof['cargo_lock_sha256'] != trusted_lock", 'False',
     'test_consistent_lock_spoof_rejected_against_git'),
    ('header-digest', 'validate_local_sdk_profile.py',
     "require(digest(path) == expected_hash, 'Installed SDK inventory digest differs')",
     "require(name.endswith('/marmot_uniffiFFI.h') or digest(path) == expected_hash, 'Installed SDK inventory digest differs')",
     'test_modified_header_digest_rejected'),
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run_body(method, cache):
    result = capture([sys.executable, '-B', '-m', 'unittest',
                             'test_local_sdk_profile.LocalSdkProfileTests.' + method],
                            cwd=HERE, env=dict(os.environ, PYTHONPYCACHEPREFIX=str(cache)),
                            timeout=120)
    raw = result.stdout + result.stderr  # RAM only; never emitted or uploaded.
    summaries = re.findall(r'^Ran (\d+) test(?:s)? in [0-9.]+s$', raw, re.M)
    expected_failure = re.search(r'^FAILED \(failures=1\)$', raw, re.M) is not None
    passed = re.search(r'^OK$', raw, re.M) is not None
    # No generic compile/import/zero-test/assertion credit. The sole intended
    # failure is the selected negative assertion observing ValueError not raised.
    intended = ('AssertionError: ValueError not raised' in raw
                and raw.count('FAIL: ' + method + ' ') == 1
                and not re.search(r'^ERROR: ', raw, re.M))
    return {'method': method, 'executed': 1 if summaries == ['1'] else None,
            'passed': 1 if passed and result.returncode == 0 and summaries == ['1'] else 0,
            'intended_failures': 1 if expected_failure and intended and result.returncode != 0
                                  and summaries == ['1'] else 0,
            'errors_or_unknown': not (summaries == ['1'] and ((passed and result.returncode == 0)
                                   or (expected_failure and intended and result.returncode != 0))),
            'skipped': 0 if 'skipped=' not in raw else None,
            'exit_code': result.returncode}


def require(value, message):
    if not value:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    require(not args.output.exists(), 'Fresh aggregate output required')
    originals = {HERE / name: ((HERE / name).read_bytes(), stat.S_IMODE((HERE / name).stat().st_mode))
                 for name in ['validate_local_sdk_profile.py', 'sdk_profiles.py']}
    report = {'scope': 'synthetic guard metadata ONLY; no SDK artifact/install qualification',
              'source_sha': os.environ['PROFILE_CONTROL_SOURCE_SHA'],
              'run_id': os.environ['GITHUB_RUN_ID'], 'chains': [], 'complete': False}
    def restore():
        for path, (data, mode) in originals.items():
            path.write_bytes(data)
            path.chmod(mode)
    def interrupted(signum, frame):
        restore()
        raise RuntimeError('Metadata PFP interrupted; source restored')
    for name in [signal.SIGTERM, signal.SIGINT]:
        signal.signal(name, interrupted)
    try:
        with tempfile.TemporaryDirectory(prefix='guard-pfp-cache-') as temp:
            for index, (name, filename, old, new, method) in enumerate(CASES):
                restore()
                chain = {'case': name, 'phases': []}
                report['chains'].append(chain)
                baseline = run_body(method, Path(temp) / f'{index}-baseline')
                chain['phases'].append(baseline)
                require(baseline['passed'] == 1 and not baseline['errors_or_unknown']
                        and baseline['skipped'] == 0, 'Baseline metadata body not exactly one pass')
                path = HERE / filename
                original = originals[path][0]
                require(original.count(old.encode()) == 1, 'Unique mutation seam required')
                path.write_bytes(original.replace(old.encode(), new.encode(), 1))
                try:
                    mutant = run_body(method, Path(temp) / f'{index}-mutant')
                    chain['phases'].append(mutant)
                finally:
                    restore()
                require(mutant['intended_failures'] == 1 and not mutant['errors_or_unknown']
                        and mutant['skipped'] == 0, 'Mutant not killed by sole intended metadata assertion')
                restored = run_body(method, Path(temp) / f'{index}-restored')
                chain['phases'].append(restored)
                require(restored['passed'] == 1 and not restored['errors_or_unknown']
                        and restored['skipped'] == 0, 'Restored metadata body not exactly one pass')
                chain['restored_source_sha256'] = sha(path.read_bytes())
                require(path.read_bytes() == original, 'Exact source restore failed')
            report['complete'] = True
    finally:
        restore()
        report['source_restored'] = all(path.read_bytes() == data
                                       and stat.S_IMODE(path.stat().st_mode) == mode
                                       for path, (data, mode) in originals.items())
        report['source_sha256'] = {path.name: sha(data) for path, (data, _) in originals.items()}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    require(report['complete'] and report['source_restored'], 'Incomplete metadata PFP')


if __name__ == '__main__':
    main()
