#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
app="$build_root/xcode/Build/Products/Debug/Cardputer Bridge.app"
executable="$app/Contents/MacOS/Cardputer Bridge"
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/cardputer-bridge-ble.XXXXXX")
probe_path="$probe_dir/state.json"
log_path="$probe_dir/app.log"

cleanup() {
    status=$?
    if [ -n "${app_pid:-}" ]; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    rm -rf "$probe_dir"
    trap - EXIT
    exit "$status"
}
trap cleanup EXIT INT TERM

test -x "$executable"
if pgrep -x "Cardputer Bridge" >/dev/null 2>&1; then
    printf 'BLUETOOTH_RUNTIME_BLOCKED app_already_running\n'
    exit 2
fi
open -n -F \
    --env "CARDPUTER_BRIDGE_BLUETOOTH_PROBE_PATH=$probe_path" \
    -o "$log_path" \
    --stderr "$log_path" \
    "$app"

attempt=0
while [ "$attempt" -lt 20 ]; do
    app_pid=$(pgrep -x "Cardputer Bridge" | tail -1 || true)
    if [ -n "$app_pid" ]; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done
if [ -z "${app_pid:-}" ]; then
    printf 'BLUETOOTH_RUNTIME_FAIL app_not_launched\n'
    exit 1
fi

attempt=0
while [ "$attempt" -lt 50 ]; do
    if [ -f "$probe_path" ] && python3 - "$probe_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
raise SystemExit(
    0 if state.get("phase") not in (None, "waitingForBluetooth") else 1
)
PY
    then
        cat "$probe_path"
        printf '\nBLUETOOTH_RUNTIME_PASS\n'
        exit 0
    fi
    if ! kill -0 "$app_pid" 2>/dev/null; then
        printf 'BLUETOOTH_RUNTIME_FAIL app_exited\n'
        cat "$log_path"
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done

printf 'BLUETOOTH_RUNTIME_FAIL no_radio_callback\n'
if [ -f "$probe_path" ]; then
    cat "$probe_path"
    printf '\n'
fi
cat "$log_path"
exit 1
