#!/bin/bash
# Build-time only. Sourced with repo_root set; never run by the installed app.
device_sync_settings=()
validate_sdk_build_arguments() {
  [[ "${WN_SDK_PROFILE:-}" == default ]] || return 0
  local argument
  for argument in "$@"; do
    case "$argument" in
      OTHER_SWIFT_FLAGS=*|SWIFT_ACTIVE_COMPILATION_CONDITIONS=*|SWIFT_FLAGS=*|-xcconfig*|@*|*WN_EXPERIMENTAL_DEVICE_SYNC*|WN_CURRENT_SDK_API=*|WN_SDK_PROFILE=*)
        echo 'Default SDK refuses unchecked compilation/configuration overrides' >&2
        return 2 ;;
    esac
  done
}
unset WN_VERIFIED_SDK_PROFILE
private_flag="${WN_EXPERIMENTAL_DEVICE_SYNC:-0}"
current_flag="${WN_CURRENT_SDK_API:-0}"
case "$private_flag:$current_flag" in
  0:0|0:1|1:0|1:1) ;;
  *) echo 'SDK capability flags must be 0 or 1' >&2; return 2 ;;
esac
sdk_profile="${WN_SDK_PROFILE:-}"
if [[ -z "$sdk_profile" ]]; then
  if [[ "$private_flag" == 0 ]]; then
    if [[ "$current_flag" != 0 ]]; then
      echo 'Current SDK API requires verified profile provenance' >&2
      return 1
    fi
    WN_CURRENT_SDK_API=0
    return 0
  fi
  sdk_profile=experimental
fi
case "$sdk_profile:$private_flag" in
  default:0|experimental:1) ;;
  *) echo 'SDK profile does not match private opt-in' >&2; return 2 ;;
esac
if [[ "$sdk_profile" == default ]]; then
  case "${OTHER_SWIFT_FLAGS:-} ${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} ${SWIFT_FLAGS:-}" in
    *WN_EXPERIMENTAL_DEVICE_SYNC*) echo 'Default SDK refuses private compilation flags' >&2; return 2 ;;
  esac
  if [[ -n "${OTHER_SWIFT_FLAGS:-}${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-}${SWIFT_FLAGS:-}" ]]; then
    echo 'Default SDK refuses unchecked Swift compiler environment overrides' >&2
    return 2
  fi
  if [[ -n "${XCODE_XCCONFIG_FILE:-}" ]]; then
    echo 'Default SDK refuses an unchecked Xcode configuration override' >&2
    return 2
  fi
fi
if ! verified_profile=$(python3 "$repo_root/scripts/validate_local_sdk_profile.py" \
    --package "$repo_root/Packages/MarmotKit" --platform ios \
    --profile "$sdk_profile" --private "$private_flag" \
    --source "${WN_SDK_SOURCE_SHA:-${SOURCE_SHA:-}}" --run-id "${WN_SDK_RUN_ID:-${SDK_RUN_ID:-}}"); then
  return 1
fi
if [[ "$verified_profile" != "$sdk_profile" ]]; then
  echo 'SDK profile validator did not establish the requested cohort' >&2
  return 1
fi
WN_VERIFIED_SDK_PROFILE="$verified_profile"
WN_CURRENT_SDK_API=1
if [[ "$private_flag" == 1 ]]; then
  device_sync_settings=('OTHER_SWIFT_FLAGS=$(inherited) -D WN_CURRENT_SDK_API -D WN_EXPERIMENTAL_DEVICE_SYNC')
else
  device_sync_settings=('OTHER_SWIFT_FLAGS=$(inherited) -D WN_CURRENT_SDK_API')
fi
