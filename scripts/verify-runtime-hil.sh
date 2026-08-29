#!/bin/sh
set -eu

port="${CARDPUTER_PORT:-/dev/cu.usbmodem2101}"
python="${CARDPUTER_SERIAL_PYTHON:-$HOME/.local/share/cardputer-bridge/launcher-venv/bin/python}"
macos_app="${CARDPUTER_MACOS_APP:-$HOME/.local/share/cardputer-bridge/build/xcode/Build/Products/Debug/Cardputer Bridge.app}"
mode="serial-control"
previous=""

for argument in "$@"; do
    if [ "$previous" = "--mode" ]; then
        mode="$argument"
    fi
    previous="$argument"
done

test -x "$python"

# The serial-control scenario must own the control lease. A running Mac App
# would keep sending real BLE heartbeats and make the intended lease-expiry
# assertion nondeterministic. Stop only this project's known app binary, then
# restore it after the run so the operator's desktop returns to its prior state.
app_was_running=0
app_executable="$macos_app/Contents/MacOS/Cardputer Bridge"
matching_app_pids() {
    {
        pgrep -f -x "$app_executable" || true
        pgrep -f -x "$app_executable .*" || true
    } | sort -u
}
restore_app() {
    if [ "$app_was_running" -eq 1 ]; then
        "$(dirname "$0")/restart-macos-app.sh" >/dev/null 2>&1 || true
    fi
}
trap restore_app EXIT

if [ "$mode" = "serial-control" ] && [ -x "$app_executable" ]; then
    app_pids="$(matching_app_pids)"
    if [ -n "$app_pids" ]; then
        app_was_running=1
        kill -TERM $app_pids
        attempts=0
        while [ -n "$(matching_app_pids)" ] && [ "$attempts" -lt 50 ]; do
            sleep 0.1
            attempts=$((attempts + 1))
        done
    fi
fi

if "$python" "$(dirname "$0")/verify_runtime_hil.py" --port "$port" "$@"; then
    result=0
else
    result=$?
fi

exit "$result"
