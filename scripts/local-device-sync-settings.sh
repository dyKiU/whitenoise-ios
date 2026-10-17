#!/bin/bash
# Sourced by development/test builders after repo_root is set.
device_sync_settings=()
case "${WN_EXPERIMENTAL_DEVICE_SYNC:-0}" in
  0) ;;
  1)
    if [[ ! -r "$repo_root/Packages/MarmotKit/LOCAL_BUILD.json" ]]; then
      echo 'Experimental app requires installed matching local MarmotKit bindings' >&2
      return 1
    fi
    python3 - "$repo_root/Packages/MarmotKit" <<'PY'
from pathlib import Path
import hashlib,json,re,sys
package=Path(sys.argv[1])
manifest=json.loads((package/'LOCAL_BUILD.json').read_text())
expected=['otlp-export','product-analytics-export','experimental-device-sync']
if manifest.get('features') != expected:
    raise SystemExit('Experimental app requires the matched local device-sync artifact cohort')
source=manifest.get('source_sha','')
if not re.fullmatch('[0-9a-f]{40}',source) or manifest.get('builder_sha') != source:
    raise SystemExit('Experimental app requires full matching source/builder commits')
if f'mdk-sha: {source}\n' not in (package/'MARMOT_VERSION').read_text():
    raise SystemExit('Local binding source provenance does not match the artifact')
swift=package/'Sources/MarmotKit/MarmotKit.swift'
if hashlib.sha256(swift.read_bytes()).hexdigest() != manifest.get('installed_swift_sha256'):
    raise SystemExit('Local Swift bindings changed after matched installation')
if not (package/'Artifacts/MarmotKit.xcframework/Info.plist').is_file():
    raise SystemExit('Matched local XCFramework is absent')
native={name:record for name,record in manifest.get('artifacts',{}).items()
        if name.startswith('MarmotKit.xcframework/') and name.endswith('.a')}
if len(native) != 2:
    raise SystemExit('Matched local manifest must identify both iOS native archives')
for name,record in native.items():
    relative=Path(name)
    if '..' in relative.parts:
        raise SystemExit('Invalid native artifact path')
    if hashlib.sha256((package/'Artifacts'/relative).read_bytes()).hexdigest() != record.get('sha256'):
        raise SystemExit('Local native archive changed after matched installation')
PY
    device_sync_settings=('OTHER_SWIFT_FLAGS=$(inherited) -D WN_EXPERIMENTAL_DEVICE_SYNC')
    ;;
  *) echo 'WN_EXPERIMENTAL_DEVICE_SYNC must be 0 or 1' >&2; return 2 ;;
esac
