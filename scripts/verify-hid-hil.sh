#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$project_dir/scripts/resolve-serial-python.sh"
port="${CARDPUTER_PORT:-/dev/cu.usbmodem2101}"
python="$(resolve_cardputer_serial_python)"

if /usr/sbin/ioreg -l -w 0 -c IOHIDSystem | \
  /usr/bin/grep -q '"CGSSessionScreenIsLocked"=Yes'; then
  printf '{"result":"BLOCKED","code":"macos_session_locked"}\n'
  exit 2
fi

consumer="$($project_dir/scripts/build-macos-hid-consumer.sh)"

if [[ "${1:-}" == "--preflight" ]]; then
  exec "$consumer" --preflight
fi
cd "$project_dir"
export PYTHONPATH="$project_dir${PYTHONPATH:+:$PYTHONPATH}"
exec "$python" "$project_dir/scripts/verify_hid_hil.py" \
  --port "$port" \
  --consumer "$consumer" \
  "$@"
