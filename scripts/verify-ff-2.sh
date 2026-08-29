#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$project_dir/scripts/verify-ff-2-preflight.sh"

port="${CARDPUTER_PORT:-}"
if [[ -z "$port" ]]; then
  port="$(find /dev -maxdepth 1 \( -name 'cu.usbmodem*' -o -name 'cu.usbserial*' \) -print -quit)"
fi
serial_candidate="$port"
if [[ -z "$serial_candidate" ]]; then
  printf 'BLOCKED FF2_CARDPUTER_NOT_CONNECTED required_evidence=E4 preflight=PASS\n' >&2
  exit 2
fi
if [[ ! -e "$serial_candidate" ]]; then
  printf 'BLOCKED FF2_CARDPUTER_PORT_MISSING port=%s\n' "$serial_candidate" >&2
  exit 2
fi
export CARDPUTER_PORT="$serial_candidate"

# Fail before resetting the device when macOS cannot provide the independent
# system-event observation required by the Gate.
"$project_dir/scripts/verify-hid-hil.sh" --preflight

"$project_dir/scripts/build-macos.sh" >/dev/null
"$project_dir/scripts/restart-macos-app.sh"

# A boot probe resets the device. The following heartbeat assertion therefore
# proves that the already-running App automatically restores encrypted GATT.
"$project_dir/scripts/verify-hil.sh"
"$project_dir/scripts/verify-runtime-hil.sh" \
  --mode ble-heartbeat \
  --observation-seconds 12

"$project_dir/scripts/verify-hid-hil.sh" --case q
"$project_dir/scripts/verify-hid-hil.sh" --case g0-q

# Reset once more with the App left running and require both HID/GATT recovery.
"$project_dir/scripts/verify-hil.sh"
"$project_dir/scripts/verify-runtime-hil.sh" \
  --mode ble-heartbeat \
  --observation-seconds 12

printf 'HUMAN_GATE FF2_PHYSICAL_KEY_SOURCE_REQUIRED device=%s automated=BLE_HID_GATT_RECONNECT_Q_G0Q_ALL_KEYS_UP\n' \
  "$serial_candidate" >&2
exit 3
