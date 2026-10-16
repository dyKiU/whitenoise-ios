#!/usr/bin/env python3
"""Remote-only fixed-taxonomy observation of one unchanged published fixture."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

BASE = '68fcd9a8fa6449bc4f610316ea650982b2f0fe9d'
FILE = 'whitenoise-iosTests/CustomEmojiSendingFixtureTests.swift'
SELF = 'scripts/custom-emoji-rejection-diagnostic.py'
WORKFLOW = '.github/workflows/tests.yml'
SELECTOR = 'whitenoise-iosTests/CustomEmojiSendingFixtureTests'
EXPECTED_CASES = {'CustomEmojiSendingFixtureTests/taggedMessageRoundTripsThroughTheRuntime()', 'whitenoise-iosTests/CustomEmojiSendingFixtureTests/taggedMessageRoundTripsThroughTheRuntime()'}
STAGES = ['setup', 'readiness-send', 'readiness-wait', 'readiness-complete', 'first-tagged', 'upload', 'first-sdk-send', 'first-readback', 'second-tagged', 'second-sdk-send', 'second-readback', 'closed']
CATEGORIES = ['readiness-rejected', 'readiness-missing', 'readiness-timeout', 'cancelled', 'sdk-error', 'other']
OUT = Path('build/CustomEmoji-diagnostic.json')

def ensure(value, reason):
    if not value: raise ValueError(reason)

def parse_console(raw):
    # Console export may be JSON with embedded log strings or plain text.
    try:
        obj=json.loads(raw)
        strings=[]
        def visit(value):
            if isinstance(value,str): strings.append(value)
            elif isinstance(value,list):
                for item in value: visit(item)
            elif isinstance(value,dict):
                for item in value.values(): visit(item)
        visit(obj); raw='\n'.join(strings)
    except json.JSONDecodeError: pass
    stages=[]; failures=[]; malformed=0
    for line in raw.splitlines():
        if 'custom-emoji-diagnostic ' not in line: continue
        line=line[line.index('custom-emoji-diagnostic '):].strip()
        m=re.fullmatch(r'custom-emoji-diagnostic stage=([a-z-]+)',line)
        f=re.fullmatch(r'custom-emoji-diagnostic failure-stage=([a-z-]+) category=([a-z-]+)',line)
        if m and m[1] in STAGES: stages.append(m[1])
        elif f and f[1] in STAGES and f[2] in CATEGORIES: failures.append({'stage':f[1],'category':f[2]})
        else: malformed+=1
    valid=not malformed and len(stages)<=len(STAGES) and len(failures)<=1 and stages==STAGES[:len(stages)] and bool(stages)
    if failures: valid &= failures[0]['stage']==stages[-1] and stages[-1]!='closed'
    else: valid &= stages==STAGES
    return {'stages':stages[:len(STAGES)],'failures':failures[:1],'malformed_or_excess':malformed+max(0,len(stages)-len(STAGES))+max(0,len(failures)-1),'observation_complete':bool(valid)}

def parse_test_identifiers(raw):
    tree=json.loads(raw); identifiers=[]; unknown=0
    def visit(value):
        nonlocal unknown
        if isinstance(value,list):
            for item in value: visit(item)
        elif isinstance(value,dict):
            if value.get('nodeType') in ['Test Case','Test Case Run']:
                identifier=value.get('nodeIdentifier',value.get('testIdentifier'))
                if identifier in EXPECTED_CASES: identifiers.append(identifier)
                else: unknown+=1
            for item in value.values():
                if isinstance(item,(dict,list)): visit(item)
    visit(tree)
    ensure(unknown==0 and len(identifiers)==1,'exact-native-case-identity')
    return identifiers

def source_guard():
    ensure(os.environ.get('GITHUB_ACTIONS')=='true','remote-only')
    head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
    ensure(head==os.environ.get('GITHUB_SHA'),'exact-source')
    changed=subprocess.check_output(['git','diff','--name-only',BASE],text=True).splitlines()
    ensure(set(changed)<={FILE,SELF,WORKFLOW},'unreviewed-input-change')
    original=subprocess.check_output(['git','show',BASE+':'+FILE])
    current=Path(FILE).read_bytes()
    pattern=rb'(?m)^[ \t]*// CUSTOM_EMOJI_DIAGNOSTIC_BEGIN\n.*?^[ \t]*// CUSTOM_EMOJI_DIAGNOSTIC_END\n'
    ensure(current.count(b'CUSTOM_EMOJI_DIAGNOSTIC_BEGIN')==current.count(b'CUSTOM_EMOJI_DIAGNOSTIC_END')==12,'bounded-passive-blocks')
    ensure(re.sub(pattern,b'',current,flags=re.S)==original,'fixture-after-strip-not-exact')
    ensure(subprocess.run(['git','diff','--quiet','HEAD']).returncode==0,'pristine')
    return {'source':head,'tree':subprocess.check_output(['git','rev-parse','HEAD^{tree}'],text=True).strip(),'baseline':BASE,'original_fixture_exact_after_strip':True,'all_other_product_tests_sdk_config_exact':True,'fixture_sha256':hashlib.sha256(current).hexdigest(),'published_manifest_sha256':hashlib.sha256(Path('Packages/MarmotKit/Package.swift').read_bytes()).hexdigest(),'selector':SELECTOR,'qualification_passed':False}

def preflight():
    OUT.parent.mkdir(exist_ok=True)
    report={'qualification_passed':False,'actual_bodies':0,'preflight_passed':False}
    try:
        report.update(source_guard())
        positive='\n'.join('custom-emoji-diagnostic stage='+stage for stage in STAGES)
        ensure(parse_console(positive)['observation_complete'],'positive-console-parser')
        partial='\n'.join('custom-emoji-diagnostic stage='+stage for stage in STAGES[:3])+'\ncustom-emoji-diagnostic failure-stage=readiness-wait category=readiness-rejected'
        ensure(parse_console(partial)['observation_complete'],'positive-failure-parser')
        negatives=[positive+'\ncustom-emoji-diagnostic stage=unknown',positive+'\ncustom-emoji-diagnostic stage=closed',positive.replace('stage=upload','stage=setup'),partial.replace('category=readiness-rejected','category=private-data'),partial.replace('failure-stage=readiness-wait','failure-stage=setup'),'']
        ensure(all(not parse_console(raw)['observation_complete'] for raw in negatives),'negative-console-parser')
        # Verify installed syntax before compilation. No installation or fallback guessing.
        help_result=subprocess.run(['xcrun','xcresulttool','get','log','--help'],capture_output=True,text=True)
        ensure(help_result.returncode==0 and all(flag in help_result.stdout for flag in ['--path','--type']) and 'console' in help_result.stdout,'installed-console-command-unsupported')
        tests_help=subprocess.run(['xcrun','xcresulttool','get','test-results','tests','--help'],capture_output=True,text=True)
        ensure(tests_help.returncode==0 and '--path' in tests_help.stdout,'installed-tests-command-unsupported')
        for expected in EXPECTED_CASES:
            ensure(parse_test_identifiers(json.dumps({'testNodes':[{'nodeType':'Test Case','nodeIdentifier':expected}]}))==[expected],'positive-native-case-parser')
        report.update(parser_positive=2,parser_negative=len(negatives),native_identity_positive=len(EXPECTED_CASES),console_cli_supported=True,tests_cli_supported=True,actual_bodies=0)
        report['preflight_passed']=True
    except Exception as error:
        report['preflight_exception']=type(error).__name__
        raise
    finally:
        OUT.write_text(json.dumps(report,indent=2)+'\n')
    return report

def run():
    report=preflight();report.update(actual_outcome='unknown',diagnostic_complete=False)
    def save(): OUT.write_text(json.dumps(report,indent=2)+'\n')
    save();started=time.monotonic()
    try:
        result=subprocess.run(['./scripts/test-with-relay.sh','-only-testing:'+SELECTOR],capture_output=True,text=True,timeout=2400)
        report.update(test_command_exit=result.returncode,seconds=time.monotonic()-started)
        # Never export xcodebuild output, arbitrary errors, log JSON or console payloads.
        report['test_execution_marker']='failed' if '** TEST EXECUTE FAILED **' in result.stdout else 'passed' if '** TEST EXECUTE SUCCEEDED **' in result.stdout else 'unknown'
        save()
        console=subprocess.run(['xcrun','xcresulttool','get','log','--path','build/TestResults.xcresult','--type','console'],capture_output=True,text=True,timeout=60)
        report['console_export_exit']=console.returncode;save()
        ensure(console.returncode==0,'console-export-failed')
        report['observations']=parse_console(console.stdout)
        summary=subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path','build/TestResults.xcresult'],capture_output=True,text=True,timeout=60)
        ensure(summary.returncode==0,'native-summary-unavailable')
        native=json.loads(summary.stdout)
        keys=['totalTestCount','passedTests','failedTests','skippedTests']
        ensure(all(type(native.get(key)) is int and native[key]>=0 for key in keys),'native-count-schema')
        report['native_counts']={key:native[key] for key in keys}; save()
        tests=subprocess.run(['xcrun','xcresulttool','get','test-results','tests','--path','build/TestResults.xcresult'],capture_output=True,text=True,timeout=60)
        ensure(tests.returncode==0,'native-tests-tree-unavailable')
        report['actual_native_case_identifiers']=parse_test_identifiers(tests.stdout)
        report['actual_outcome']='passed' if result.returncode==0 and native['passedTests']==1 and native['failedTests']==0 else 'failed'
        report['diagnostic_complete']=report['observations']['observation_complete'] and native['totalTestCount']==1 and native['passedTests']+native['failedTests']==1 and native['skippedTests']==0
    except Exception as error: report['controller_exception']=type(error).__name__
    finally:
        try:
            final=source_guard(); report['final_source_guard']=final
            report['inputs_pristine']=all(final[key]==report[key] for key in ['source','tree','fixture_sha256','published_manifest_sha256'])
        except Exception as error:report.update(inputs_pristine=False,final_guard_exception=type(error).__name__)
        save()
    raise SystemExit(0 if report['diagnostic_complete'] and report['inputs_pristine'] and report['actual_outcome']=='passed' else 1)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--mode',choices=['preflight','run'],required=True);args=parser.parse_args()
    if args.mode=='preflight':preflight()
    else:run()
