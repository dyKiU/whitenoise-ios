#!/usr/bin/env bash
# Build a clean, pinned MDK checkout. Local artifacts are never committed.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo 'usage: scripts/sync-local-bindings.sh <mdk-checkout> <full-source-sha>' >&2
  exit 2
fi
local_mdk="$(cd "$1" && pwd)"
source_sha="$2"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$(git -C "$local_mdk" rev-parse HEAD)" == "$source_sha" ]] || { echo 'MDK checkout does not match requested SHA' >&2; exit 1; }
[[ -z "$(git -C "$local_mdk" status --porcelain)" ]] || { echo 'MDK checkout must be clean' >&2; exit 1; }
ios_root="$(cd "$(dirname "$0")/.." && pwd)"
export OTLP_EXPORT=1 PRODUCT_ANALYTICS_EXPORT=1
"$local_mdk/crates/marmot-uniffi/xcframework.sh"
[[ "$(git -C "$local_mdk" rev-parse HEAD)" == "$source_sha" && -z "$(git -C "$local_mdk" status --porcelain)" ]] || exit 1
"$local_mdk/crates/marmot-uniffi/validate-ios-artifact.sh" "$local_mdk/crates/marmot-uniffi/output/MarmotKit.xcframework" 18.0
(
  cd "$local_mdk"
  ./crates/marmot-uniffi/package-ios-artifacts.sh "local-$source_sha" "local-$source_sha" "$source_sha" "$ios_root/build/local-marmotkit" "$source_sha"
)
python3 - "$local_mdk" "$ios_root" "$source_sha" <<'PY'
from pathlib import Path
import datetime,hashlib,json,os,shutil,subprocess,sys
mdk,root,sha=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
package=root/'Packages/MarmotKit'
manifest=json.loads((root/f'build/local-marmotkit/marmotkit-ios-local-{sha}.manifest.json').read_text())
features=manifest.get('features')
expected_features=['otlp-export','product-analytics-export']
experimental=os.environ.get('EXPERIMENTAL_DEVICE_SYNC','0')
if experimental not in {'','0','false','1','true'}:
    raise ValueError('EXPERIMENTAL_DEVICE_SYNC must be 0, false, 1 or true')
if experimental in {'1','true'}:
    expected_features.append('experimental-device-sync')
if features != expected_features:
    raise ValueError('built MarmotKit features do not match the requested local profile')
if manifest.get('source_sha') != sha or manifest.get('builder_sha') != sha:
    raise ValueError('built MarmotKit source identity does not match the pinned checkout')
features_csv=','.join(features)
branch=subprocess.check_output(['git','-C',str(mdk),'rev-parse','--abbrev-ref','HEAD'],text=True).strip()
if branch == 'HEAD':
    branch='detached'
artifact=package/'Artifacts/MarmotKit.xcframework'
if artifact.exists(): shutil.rmtree(artifact)
shutil.copytree(mdk/'crates/marmot-uniffi/output/MarmotKit.xcframework',artifact)
swift=(mdk/'crates/marmot-uniffi/output/MarmotKit.swift').read_text()
(package/'Sources/MarmotKit/MarmotKit.swift').write_text('\n'.join(line.rstrip() for line in swift.splitlines())+'\n')
import re
text=(package/'Package.swift').read_text()
text=re.sub(r'let marmotKitLocalPath: String\? = .*', 'let marmotKitLocalPath: String? = "Artifacts/MarmotKit.xcframework"',text)
resources=package/'Sources/MarmotKit/Resources'
resources.mkdir(exist_ok=True)
shutil.copy2(mdk/'crates/marmot-uniffi/output/PrivacyInfo.xcprivacy', resources/'PrivacyInfo.xcprivacy')
if 'resources: [.copy("Resources/PrivacyInfo.xcprivacy")]' not in text:
    text=text.replace('path: "Sources/MarmotKit",', 'path: "Sources/MarmotKit",\n            resources: [.copy("Resources/PrivacyInfo.xcprivacy")],')
(package/'Package.swift').write_text(text)
manifest['installation']='local; immutable snapshot required before merge'
manifest['xcode']=subprocess.check_output(['xcodebuild','-version'],text=True).strip().splitlines()
manifest['swift']=subprocess.check_output(['xcrun','swift','--version'],text=True).strip().splitlines()
manifest['apple_sdks']={sdk:subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-version'],text=True).strip() for sdk in ['iphoneos','iphonesimulator']}
manifest['installed_swift_sha256']=hashlib.sha256((package/'Sources/MarmotKit/MarmotKit.swift').read_bytes()).hexdigest()
(package/'LOCAL_BUILD.json').write_text(json.dumps(manifest,indent=2)+'\n')
built=datetime.datetime.now(datetime.timezone.utc).isoformat()
uniffi=re.search(r'uniffi = \{ version = "([^"]+)"', (mdk/'crates/marmot-uniffi/Cargo.toml').read_text()).group(1)
(package/'MARMOT_VERSION').write_text(f'mdk-sha: {sha}\nmdk-branch: {branch}\nmdk-tag: local-{sha}\nbuilt-at: {built}\nuniffi-version: {uniffi}\nfeatures: {features_csv}\nSee LOCAL_BUILD.json for exact artifact checksums and toolchain.\n')
(package/'Sources/MarmotKit/MarmotKitVersion.swift').write_text(f'''import Foundation

/// Provenance for locally built, unpublished bindings.
public enum MarmotKitVersion {{
    public static let mdkSHA = "{sha}"
    public static let mdkTag = "local-{sha}"
    public static let builtAt = "{built}"
    public static let uniffiVersion = "{uniffi}"
    public static let features = "{features_csv}"
}}
''')
PY
