#!/usr/bin/env python3
"""Remote-only fixed-taxonomy observation of an unchanged published fixture under native load."""
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
TEST_SCRIPT = 'scripts/test.sh'
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

def known_case(raw):
    rows=[]
    def visit(value):
        if isinstance(value,list):
            for child in value:visit(child)
        elif isinstance(value,dict):
            identifier=value.get('nodeIdentifier',value.get('testIdentifier'))
            if value.get('nodeType')=='Test Case' and identifier in EXPECTED_CASES:
                status=value.get('result',value.get('status'))
                rows.append({'identifier':identifier,'status':status if status in ['Passed','Failed','Skipped'] else 'unknown'})
            for child in value.values():
                if isinstance(child,(dict,list)):visit(child)
    visit(json.loads(raw));ensure(len(rows)==1,'one-known-native-case');return rows[0]

def source_guard():
    ensure(os.environ.get('GITHUB_ACTIONS')=='true','remote-only')
    head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
    ensure(head==os.environ.get('GITHUB_SHA'),'exact-source')
    changed=subprocess.check_output(['git','diff','--name-only',BASE],text=True).splitlines()
    ensure(set(changed)<={FILE,SELF,WORKFLOW,TEST_SCRIPT},'unreviewed-input-change')
    original=subprocess.check_output(['git','show',BASE+':'+FILE])
    current=Path(FILE).read_bytes()
    pattern=rb'(?m)^[ \t]*// CUSTOM_EMOJI_DIAGNOSTIC_BEGIN\n.*?^[ \t]*// CUSTOM_EMOJI_DIAGNOSTIC_END\n'
    ensure(current.count(b'CUSTOM_EMOJI_DIAGNOSTIC_BEGIN')==current.count(b'CUSTOM_EMOJI_DIAGNOSTIC_END')==12,'bounded-passive-blocks')
    ensure(re.sub(pattern,b'',current,flags=re.S)==original,'fixture-after-strip-not-exact')
    old_script=subprocess.check_output(['git','show',BASE+':'+TEST_SCRIPT])
    old_condition=b'  if command -v xcbeautify >/dev/null 2>&1; then'
    new_condition=b'  if [ "${WN_TEST_RAW_OUTPUT:-0}" != "1" ] && command -v xcbeautify >/dev/null 2>&1; then'
    script=Path(TEST_SCRIPT).read_bytes()
    ensure(script.count(new_condition)==1 and script.replace(new_condition,old_condition,1)==old_script,'only-reviewed-raw-output-condition')
    ensure(subprocess.run(['git','diff','--quiet','HEAD']).returncode==0,'pristine')
    return {'source':head,'tree':subprocess.check_output(['git','rev-parse','HEAD^{tree}'],text=True).strip(),'baseline':BASE,'original_fixture_exact_after_strip':True,'all_other_product_tests_sdk_config_exact':True,'fixture_sha256':hashlib.sha256(current).hexdigest(),'test_script_sha256':hashlib.sha256(script).hexdigest(),'published_manifest_sha256':hashlib.sha256(Path('Packages/MarmotKit/Package.swift').read_bytes()).hexdigest(),'selector':SELECTOR,'qualification_passed':False}

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
        report['console_cli_available']=help_result.returncode==0 and all(flag in help_result.stdout for flag in ['--path','--type']) and 'console' in help_result.stdout
        tests_help=subprocess.run(['xcrun','xcresulttool','get','test-results','tests','--help'],capture_output=True,text=True)
        ensure(tests_help.returncode==0 and '--path' in tests_help.stdout,'installed-tests-command-unsupported')
        for expected in EXPECTED_CASES:
            ensure(parse_test_identifiers(json.dumps({'testNodes':[{'nodeType':'Test Case','nodeIdentifier':expected}]}))==[expected],'positive-native-case-parser')
        ensure(known_case(json.dumps({'testNodes':[{'nodeType':'Test Case','nodeIdentifier':'OtherSuite/other()'},{'nodeType':'Test Case','nodeIdentifier':next(iter(EXPECTED_CASES)),'result':'Passed'}]}))['status']=='Passed','positive-full-native-case')
        identity_negatives=0
        for nodes in [[],[{'nodeType':'Test Case','nodeIdentifier':'OtherSuite/other()'}],[{'nodeType':'Test Case','nodeIdentifier':next(iter(EXPECTED_CASES))}]*2]:
            rejected=False
            try:known_case(json.dumps({'testNodes':nodes}))
            except ValueError:rejected=True
            ensure(rejected,'negative-full-native-case');identity_negatives+=1
        syntax=subprocess.run(['bash','-n',TEST_SCRIPT],capture_output=True,text=True)
        ensure(syntax.returncode==0,'test-script-syntax')
        report.update(full_case_positive=1,full_case_negative=identity_negatives)
        report.update(parser_positive=2,parser_negative=len(negatives),native_identity_positive=len(EXPECTED_CASES),tests_cli_supported=True,actual_bodies=0)
        report['preflight_passed']=True
    except Exception as error:
        report['preflight_exception']=type(error).__name__
        raise
    finally:
        OUT.write_text(json.dumps(report,indent=2)+'\n')
    return report

def run(full=False):
    report=preflight();report.update(mode='full-underload' if full else 'isolated',actual_outcome='unknown',diagnostic_complete=False,console_export_qualified=False)
    def save(): OUT.write_text(json.dumps(report,indent=2)+'\n')
    command=['./scripts/test-with-relay.sh']+([] if full else ['-only-testing:'+SELECTOR])
    report.update(test_command=command,raw_xcodebuild_output=full);save();started=time.monotonic();raw=''
    try:
        env=dict(os.environ)
        if full:env['WN_TEST_RAW_OUTPUT']='1'
        try:
            result=subprocess.run(command,capture_output=True,text=True,timeout=2400,env=env)
            raw=result.stdout+result.stderr;report['test_command_exit']=result.returncode
        except subprocess.TimeoutExpired as error:
            def text(value):return value.decode(errors='replace') if isinstance(value,bytes) else value or ''
            raw=text(error.stdout)+text(error.stderr);report['watchdog_triggered']=True
        report['seconds']=time.monotonic()-started
        report['test_execution_marker']='failed' if '** TEST EXECUTE FAILED **' in raw else 'passed' if '** TEST EXECUTE SUCCEEDED **' in raw else 'unknown'
        report['test_build_marker']='failed' if '** TEST BUILD FAILED **' in raw else 'passed' if '** TEST BUILD SUCCEEDED **' in raw else 'unknown'
        save()
        # Persist direct markers before touching XCResult. No raw output is saved.
        try:report['direct_observations']=parse_console(raw)
        except Exception as error:report['direct_parser_exception']=type(error).__name__
        save();del raw
        # Each export is independent: exporter failure never erases actual results.
        try:
            summary=subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path','build/TestResults.xcresult'],capture_output=True,text=True,timeout=60)
            report['summary_export_exit']=summary.returncode;save()
            ensure(summary.returncode==0,'native-summary-unavailable')
            native=json.loads(summary.stdout);keys=['totalTestCount','passedTests','failedTests','skippedTests']
            ensure(all(type(native.get(key)) is int and native[key]>=0 for key in keys),'native-count-schema')
            report['native_counts']={key:native[key] for key in keys}
            report['native_summary_consistent']=native['totalTestCount']==sum(native[key] for key in ['passedTests','failedTests','skippedTests'])
            report['actual_outcome']='passed' if report.get('test_command_exit')==0 and native['failedTests']==0 and native['passedTests']>0 else 'failed'
        except Exception as error:report['summary_exception']=type(error).__name__
        save()
        try:
            tests=subprocess.run(['xcrun','xcresulttool','get','test-results','tests','--path','build/TestResults.xcresult'],capture_output=True,text=True,timeout=60)
            report['tests_export_exit']=tests.returncode;save();ensure(tests.returncode==0,'native-tests-tree-unavailable')
            report['known_native_case']=known_case(tests.stdout)
        except Exception as error:report['tests_tree_exception']=type(error).__name__
        save()
        if not report.get('direct_observations',{}).get('observation_complete') and report.get('console_cli_available'):
            try:
                console=subprocess.run(['xcrun','xcresulttool','get','log','--path','build/TestResults.xcresult','--type','console'],capture_output=True,text=True,timeout=60)
                report['console_export_exit']=console.returncode
                if console.returncode==0:
                    report['console_export_qualified']=True;report['console_observations']=parse_console(console.stdout)
            except Exception as error:report['console_exception']=type(error).__name__
        observation=report.get('direct_observations',{})
        if not observation.get('observation_complete'):observation=report.get('console_observations',{})
        report['marker_coverage']='complete' if observation.get('observation_complete') else 'unknown-or-partial'
        report['diagnostic_complete']=bool(observation.get('observation_complete') and report.get('native_summary_consistent') is True and report.get('known_native_case',{}).get('status') in ['Passed','Failed'] and not report.get('watchdog_triggered'))
        save()
    except Exception as error:report['controller_exception']=type(error).__name__
    finally:
        try:
            final=source_guard();report['final_source_guard']=final
            report['inputs_pristine']=all(final[key]==report[key] for key in ['source','tree','fixture_sha256','published_manifest_sha256','test_script_sha256'])
        except Exception as error:report.update(inputs_pristine=False,final_guard_exception=type(error).__name__)
        save()
    raise SystemExit(0 if report['diagnostic_complete'] and report.get('inputs_pristine') and report['actual_outcome']=='passed' else 1)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--mode',choices=['preflight','run','full'],required=True);args=parser.parse_args()
    if args.mode=='preflight':preflight()
    else:run(full=args.mode=='full')
