#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$project_dir/scripts/resolve-serial-python.sh"
port="${CARDPUTER_PORT:-/dev/cu.usbmodem2101}"
serial_python="$(resolve_cardputer_serial_python)"
runtime_probe="${CARDPUTER_BRIDGE_MACOS_PROBE_PATH:-$HOME/.local/share/cardputer-bridge/runtime/macos-state.json}"
fixture="$project_dir/harness/fixtures/shortcut-config-v2.json"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cardputer-phase2.XXXXXX")"
temp_config="$temp_dir/config.json"
trap 'rm -f "$temp_config"; rmdir "$temp_dir" 2>/dev/null || true' EXIT

before_json="$($serial_python "$project_dir/scripts/verify_config_hil.py" --port "$port")"
current_version="$(printf '%s' "$before_json" | jq -er '.config_version')"
next_version="$((current_version + 1))"
jq --argjson version "$next_version" \
  '.configVersion = $version | .updatedAt = 0' \
  "$fixture" > "$temp_config"

CARDPUTER_BRIDGE_CONFIG_PATH="$temp_config" \
  "$project_dir/scripts/restart-macos-app.sh"

synced=false
for _ in {1..40}; do
  if jq -e --arg version "$next_version" \
      '.device_config_version == $version and (.device_state | contains("\"cfg_v\":"))' \
      "$runtime_probe" >/dev/null 2>&1; then
    synced=true
    break
  fi
  sleep 0.5
done
if [[ "$synced" != true ]]; then
  printf 'FAIL phase2_config_sync_timeout expected_version=%s probe=%s\n' \
    "$next_version" "$runtime_probe" >&2
  exit 1
fi

"$project_dir/scripts/verify-hil.sh"
persisted_json="$($serial_python "$project_dir/scripts/verify_config_hil.py" \
  --port "$port" \
  --expected-version "$next_version")"

printf '%s\n' "$before_json"
printf '%s\n' "$persisted_json"
printf 'PASS phase2_atomic_config_sync_and_reboot_persistence version=%s\n' \
  "$next_version"
