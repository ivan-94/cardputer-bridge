#!/usr/bin/env bash
set -euo pipefail

if [[ "${CARDPUTER_BRIDGE_TEST_MODE:-0}" == 1 ]]; then
  product_version="${CARDPUTER_BRIDGE_TEST_PRODUCT_VERSION:?test product version required}"
  build_version="${CARDPUTER_BRIDGE_TEST_BUILD_VERSION:?test build version required}"
else
  product_version="$(sw_vers -productVersion)"
  build_version="$(sw_vers -buildVersion)"
fi
major_version="${product_version%%.*}"

if [[ ! "$major_version" =~ ^[0-9]+$ ]]; then
  printf 'FAIL HAL_RUNTIME_VERSION_INVALID product_version=%s build_version=%s\n' \
    "$product_version" "$build_version" >&2
  exit 1
fi

if [[ "$product_version" == "27.0" && "$build_version" == "26A5421a" ]]; then
  printf 'PASS HAL_RUNTIME_BUILD_VALIDATED product_version=%s build_version=%s evidence=FF-1-Beta7-runtime-2026-08-28\n' \
    "$product_version" "$build_version"
  exit 0
fi

if (( major_version >= 27 )); then
  if [[ "${CARDPUTER_BRIDGE_ALLOW_UNVALIDATED_HAL_RUNTIME:-0}" == 1 ]]; then
    printf 'WARNING HAL_RUNTIME_OVERRIDE product_version=%s build_version=%s\n' \
      "$product_version" "$build_version" >&2
    exit 0
  fi
  printf 'BLOCKED FF1_HAL_RUNTIME_UNVALIDATED product_version=%s build_version=%s reason=legacy_AudioServerPlugIn_enumeration_spin\n' \
    "$product_version" "$build_version" >&2
  printf 'EVIDENCE Cardputer_driver_and_Apple_NullAudio_control_both_hung_CoreAudio_enumeration_with_sustained_coreaudiod_CPU\n' >&2
  printf 'NEXT keep_Cardputer_driver_absent_from_HAL_and_rerun_after_OS_update_or_with_explicit_override\n' >&2
  exit 2
fi

printf 'PASS HAL_RUNTIME_VERSION_POLICY product_version=%s build_version=%s\n' \
  "$product_version" "$build_version"
