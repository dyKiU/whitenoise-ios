#!/bin/bash
set -euo pipefail
if [[ $# != 4 && $# != 8 ]]; then
  echo 'usage: build.sh swift-bindings simulator-native-directory output-binary module-cache [installed-package source-sha producer-run profile]' >&2
  exit 2
fi
script_dir=$(cd "$(dirname "$0")" && pwd)
api_flags=()
if [[ $# == 8 ]]; then
  # This mode is for an actual installer-created isolated overlay, never a raw
  # capability flag. The reviewed sibling validator binds real Git F and the
  # full qualification/native/Swift inventory before enabling the API branch.
  case "$8" in default) private=0 ;; experimental) private=1 ;; *) exit 2 ;; esac
  verified_profile=$(python3 "$script_dir/../validate_local_sdk_profile.py" \
    --package "$5" --platform ios --profile "$8" --source "$6" --run-id "$7" --private "$private")
  [[ "$verified_profile" == "$8" ]]
  cmp -s "$1" "$5/LOCAL_BUILD_INPUTS/MarmotKit.swift"
  actual_native=$(cd "$2" && pwd -P)
  verified_native=$(cd "$5/Artifacts/MarmotKit.xcframework/ios-arm64-simulator" && pwd -P)
  [[ "$actual_native" == "$verified_native" ]]
  # Ordinary public chat needs the new public API, never private enrollment.
  api_flags=(-D WN_CURRENT_SDK_API)
fi
mkdir -p "$(dirname "$3")" "$4"
xcrun swiftc "${api_flags[@]}" -swift-version 5 -parse-as-library -target arm64-apple-ios18.0-simulator \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -module-cache-path "$4" \
  -I "$2/Headers" "$1" "$script_dir/Worker.swift" "$2/libmarmot_uniffi.a" \
  -framework Security -framework SystemConfiguration -framework CoreFoundation \
  -framework Network -lc++ -o "$3"
codesign --force --sign - "$3"
