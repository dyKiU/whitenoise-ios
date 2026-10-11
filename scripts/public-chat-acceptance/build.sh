#!/bin/bash
set -euo pipefail
if [[ $# != 4 ]]; then
  echo 'usage: build.sh swift-bindings simulator-native-directory output-binary module-cache' >&2
  exit 2
fi
script_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$(dirname "$3")" "$4"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-ios18.0-simulator \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -module-cache-path "$4" \
  -I "$2/Headers" "$1" "$script_dir/Worker.swift" "$2/libmarmot_uniffi.a" \
  -framework Security -framework SystemConfiguration -framework CoreFoundation \
  -framework Network -lc++ -o "$3"
codesign --force --sign - "$3"
