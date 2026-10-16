#!/usr/bin/env python3
"""Inspect an immutable existing XCResult remotely; never compile or execute tests."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile

BASE='2faae569578517e6d54849dfa621b40bec6a8c28'
SELF='scripts/custom-emoji-existing-xcresult.py'
WORKFLOW='.github/workflows/tests.yml'
RUN=38858098768
ARTIFACT=12029008742
ARTIFACT_SHA='2ec080af1958805b599d13ebe86308ee3412f6226791b7bef61ed576a9594687'
SOURCE='68fcd9a8fa6449bc4f610316ea650982b2f0fe9d'
CASE='CustomEmojiSendingFixtureTests/taggedMessageRoundTripsThroughTheRuntime()'
ALLOWED={CASE,'whitenoise-iosTests/'+CASE}
OUT=Path('build/CustomEmoji-existing-export.json')
OWN_REASONS={'remote-only','source-identity','only-exporter-workflow-change','source-pristine','one-exact-known-case','known-case-positive','known-case-negative','runner-disk-reserve','immutable-artifact-provenance','archive-digest','uncompressed-bound','archive-safe-path','one-existing-bundle-layout','summary-command','native-schema','tests-tree-command'}

def ensure(ok,reason):
    if not ok:raise ValueError(reason)

def guard():
    ensure(os.environ.get('GITHUB_ACTIONS')=='true','remote-only')
    source=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
    ensure(source==os.environ.get('GITHUB_SHA'),'source-identity')
    ensure(set(subprocess.check_output(['git','diff','--name-only',BASE],text=True).splitlines())<={SELF,WORKFLOW},'only-exporter-workflow-change')
    ensure(subprocess.run(['git','diff','--quiet','HEAD']).returncode==0,'source-pristine')
    return {'controller_source':source,'controller_tree':subprocess.check_output(['git','rev-parse','HEAD^{tree}'],text=True).strip(),'controller_baseline':BASE,'published_manifest_sha256':hashlib.sha256(Path('Packages/MarmotKit/Package.swift').read_bytes()).hexdigest(),'fixture_sha256':hashlib.sha256(Path('whitenoise-iosTests/CustomEmojiSendingFixtureTests.swift').read_bytes()).hexdigest()}

def command(args):
    return subprocess.run(args,capture_output=True,text=True,timeout=120)

def cli_category(result):
    if result.returncode==0:return 'success'
    text=result.stderr.lower()
    if '--test-id' in text and any(word in text for word in ['required','missing','expected']):return 'missing-required-test-id'
    if '--id' in text and any(word in text for word in ['required','missing','expected']):return 'missing-required-id'
    if 'console' in text and any(word in text for word in ['invalid','unexpected','unrecognized']):return 'console-type-not-supported'
    if any(word in text for word in ['not found','does not exist','unable to find']):return 'object-not-found'
    return 'other-cli-error'

def known_case(tree):
    rows=[]
    def visit(value):
        if isinstance(value,list):
            for child in value:visit(child)
        elif isinstance(value,dict):
            identifier=value.get('nodeIdentifier',value.get('testIdentifier'))
            if value.get('nodeType')=='Test Case' and identifier in ALLOWED:
                status=value.get('result',value.get('status'))
                rows.append({'identifier':identifier,'status':status if status in ['Passed','Failed','Skipped','passed','failed','skipped'] else 'unknown'})
            for child in value.values():
                if isinstance(child,(dict,list)):visit(child)
    visit(tree);ensure(len(rows)==1,'one-exact-known-case');return rows[0]

def console_log_reference(details):
    # Accept only XCResult's typed logRef Reference representation. A test ID,
    # identifier URL or an untyped string is never promoted into a log object ID.
    references=[]
    def visit(value):
        if isinstance(value,list):
            for child in value:visit(child)
        elif isinstance(value,dict):
            reference=value.get('logRef')
            if isinstance(reference,dict) and reference.get('_type',{}).get('_name')=='Reference':
                identifier=reference.get('id',{}).get('_value')
                if isinstance(identifier,str) and identifier:references.append(identifier)
            for child in value.values():
                if isinstance(child,(dict,list)):visit(child)
    visit(details)
    unique=set(references)
    return next(iter(unique)) if len(unique)==1 else None

def bounded_failure_details(details):
    # Only explicit structured failure text/category and repository test sites.
    # These fixed values cannot distinguish readiness rejection from SDK errors.
    rejected=False;locations=set()
    allowed_files={'CustomEmojiSendingFixtureTests.swift','MarmotLocalSendFixtureReadiness.swift'}
    def visit(value):
        nonlocal rejected
        if isinstance(value,list):
            for child in value:visit(child)
        elif isinstance(value,dict):
            for key in ['failureText','message']:
                if value.get(key)=='Caught error: rejected':rejected=True
            filename=value.get('fileName');line=value.get('lineNumber')
            if isinstance(filename,str) and type(line) is int and 0<line<100000:
                leaf=filename.rsplit('/',1)[-1]
                if leaf in allowed_files:locations.add((leaf,line))
            for child in value.values():
                if isinstance(child,(dict,list)):visit(child)
    visit(details)
    return {'closed_error_category':'caught-rejected-untyped' if rejected else 'unknown','known_test_locations':[{'file':file,'line':line} for file,line in sorted(locations)[:8]],'location_overflow':len(locations)>8,'typed_rejection_origin':'unknown'}

def main():
    OUT.parent.mkdir(exist_ok=True)
    report={'qualification_passed':False,'new_test_executions':0,'artifact_run':RUN,'artifact_source':SOURCE,'artifact_id':ARTIFACT,'artifact_sha256':ARTIFACT_SHA,'instrumented_markers_expected':False,'inspection_complete':False,'console_export_qualified':False,'diagnostic_complete':False,'original_failure_cause_established':False,'raw_exports_retained':False}
    def save():OUT.write_text(json.dumps(report,indent=2)+'\n')
    save();before=None
    try:
        before=guard();report.update(before);save()
        # Parser fixtures operate only on a fixed known identifier/status schema.
        ensure(known_case({'testNodes':[{'nodeType':'Test Case','nodeIdentifier':CASE,'result':'Failed'}]})['status']=='Failed','known-case-positive')
        negatives=0
        for tree in [{},{'testNodes':[{'nodeType':'Test Case','nodeIdentifier':'unknown'}]},{'testNodes':[{'nodeType':'Test Case','nodeIdentifier':CASE}]*2}]:
            rejected=False
            try:known_case(tree)
            except ValueError:rejected=True
            ensure(rejected,'known-case-negative');negatives+=1
        report.update(parser_positive=1,parser_negative=negatives);save()
        ensure(shutil.disk_usage(os.environ['RUNNER_TEMP']).free>=8*1024**3,'runner-disk-reserve')
        metadata=json.loads(subprocess.check_output(['gh','api',f'repos/dyKiU/whitenoise-ios/actions/artifacts/{ARTIFACT}'],text=True))
        ensure(metadata['id']==ARTIFACT and metadata['name']=='TestResults' and metadata['size_in_bytes']==93363955 and metadata['digest']=='sha256:'+ARTIFACT_SHA and metadata['workflow_run']['id']==RUN and metadata['workflow_run']['head_sha']==SOURCE and not metadata['expired'],'immutable-artifact-provenance')
        report['artifact_metadata_verified']=True;save()
        with tempfile.TemporaryDirectory(prefix='emoji-existing-',dir=os.environ['RUNNER_TEMP']) as temp:
            root=Path(temp);archive=root/'result.zip'
            with archive.open('wb') as stream:subprocess.run(['gh','api',f'repos/dyKiU/whitenoise-ios/actions/artifacts/{ARTIFACT}/zip'],stdout=stream,stderr=subprocess.DEVNULL,check=True,timeout=300)
            report['archive_size_matches']=archive.stat().st_size==93363955
            report['archive_digest_matches']=hashlib.sha256(archive.read_bytes()).hexdigest()==ARTIFACT_SHA
            save();ensure(report['archive_size_matches'] and report['archive_digest_matches'],'archive-digest')
            extracted=root/'extracted';extracted.mkdir()
            with zipfile.ZipFile(archive) as zipped:
                report['archive_uncompressed_within_bound']=sum(entry.file_size for entry in zipped.infolist())<=2*1024**3
                save();ensure(report['archive_uncompressed_within_bound'],'uncompressed-bound')
                for entry in zipped.infolist():
                    target=(extracted/entry.filename).resolve()
                    ensure(target.is_relative_to(extracted.resolve()) and not stat.S_ISLNK(entry.external_attr>>16),'archive-safe-path')
                zipped.extractall(extracted)
            report['unwrapped_info_present']=(extracted/'Info.plist').is_file()
            report['unwrapped_data_present']=(extracted/'Data').is_dir()
            wrapped=[candidate for candidate in extracted.rglob('*.xcresult') if candidate.is_dir() and (candidate/'Info.plist').is_file() and (candidate/'Data').is_dir()]
            report['nonempty_wrapped_bundle_count']=len(wrapped)
            candidates=wrapped+([extracted] if report['unwrapped_info_present'] and report['unwrapped_data_present'] else [])
            report['valid_bundle_root_count']=len(candidates);save()
            ensure(len(candidates)==1,'one-existing-bundle-layout')
            # GitHub directory uploads may omit the .xcresult wrapper. Restore
            # only that container name, leaving every archived bundle byte intact.
            owned=root/'inspection.xcresult';owned.mkdir()
            for child in candidates[0].iterdir():shutil.move(str(child),owned/child.name)
            report['owned_bundle_info_present']=(owned/'Info.plist').is_file()
            report['owned_bundle_data_present']=(owned/'Data').is_dir();save()
            bundle=str(owned)
            summary=command(['xcrun','xcresulttool','get','test-results','summary','--path',bundle]);report['summary_exit']=summary.returncode;save();ensure(summary.returncode==0,'summary-command')
            native=json.loads(summary.stdout);keys=['totalTestCount','passedTests','failedTests','skippedTests']
            ensure(all(type(native.get(k)) is int and native[k]>=0 for k in keys),'native-schema')
            report['native_counts']={k:native[k] for k in keys};save()
            tests=command(['xcrun','xcresulttool','get','test-results','tests','--path',bundle]);report['tests_tree_exit']=tests.returncode;save();ensure(tests.returncode==0,'tests-tree-command')
            case=known_case(json.loads(tests.stdout));report['known_case']=case;save()
            help_result=command(['xcrun','xcresulttool','get','log','--help'])
            report['console_help']={'exit':help_result.returncode,'supports_id':'--id' in help_result.stdout,'supports_test_id':'--test-id' in help_result.stdout,'supports_path':'--path' in help_result.stdout,'mentions_console':'console' in help_result.stdout,'static_flag_inventory':sorted(set(re.findall(r'--[a-z][a-z0-9-]*',help_result.stdout)))[:32]};save()
            old=command(['xcrun','xcresulttool','get','log','--path',bundle,'--type','console'])
            report['original_console_invocation']={'exit':old.returncode,'category':cli_category(old)};save()
            details_help=command(['xcrun','xcresulttool','get','test-results','test-details','--help'])
            report['details_help']={'exit':details_help.returncode,'supports_test_id':'--test-id' in details_help.stdout};save()
            reference=None
            if details_help.returncode==0 and '--test-id' in details_help.stdout:
                details=command(['xcrun','xcresulttool','get','test-results','test-details','--path',bundle,'--test-id',case['identifier']])
                report['known_case_details']={'exit':details.returncode,'category':cli_category(details)};save()
                if details.returncode==0:
                    detail_tree=json.loads(details.stdout)
                    reference=console_log_reference(detail_tree)
                    report['bounded_failure_details']=bounded_failure_details(detail_tree);save()
            report['typed_log_reference_available']=reference is not None
            report['console_export_qualified']=old.returncode==0
            if help_result.returncode==0 and report['console_help']['supports_test_id']:
                scoped=command(['xcrun','xcresulttool','get','log','--path',bundle,'--type','console','--test-id',case['identifier']])
                report['verified_case_console_invocation']={'exit':scoped.returncode,'category':cli_category(scoped)}
                report['console_export_qualified'] |= scoped.returncode==0
            elif reference is not None and report['console_help']['supports_id']:
                scoped=command(['xcrun','xcresulttool','get','log','--path',bundle,'--type','console','--id',reference])
                report['referenced_console_invocation']={'exit':scoped.returncode,'category':cli_category(scoped)}
                report['console_export_qualified'] |= scoped.returncode==0
            report['marker_coverage']='unavailable: original68fcd fixture has no diagnostic hooks'
            report['diagnostic_complete']=False
            report['original_failure_cause_established']=False
            report['inspection_complete']=True;save()
        report['ephemeral_archive_removed']=True
    except Exception as error:
        report['controller_exception']=type(error).__name__
        if isinstance(error,ValueError) and str(error) in OWN_REASONS:report['closed_failure_reason']=str(error)
    finally:
        try:
            after=guard();report['final_source_guard']=after;report['inputs_pristine']=before==after
        except Exception as error:report.update(inputs_pristine=False,final_guard_exception=type(error).__name__)
        save()
    raise SystemExit(0 if report['inspection_complete'] and report['inputs_pristine'] else 1)

if __name__=='__main__':main()
