#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
probe="${CARDPUTER_BRIDGE_AUDIO_PROBE_PATH:-$HOME/.local/share/cardputer-bridge/runtime/audio-state.json}"
timeout_seconds="${CARDPUTER_BRIDGE_AUDIO_TIMEOUT_SECONDS:-15}"

deadline=$(( $(date +%s) + timeout_seconds ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -f "$probe" ] && \
     PYTHONPATH="$project_dir" python3 -m harness.verifier.audio_runtime_probe --ready "$probe" >/dev/null 2>&1; then
    PYTHONPATH="$project_dir" python3 -m harness.verifier.audio_runtime_probe --ready "$probe"
    serial_python="${CARDPUTER_SERIAL_PYTHON:-$HOME/.local/share/cardputer-bridge/launcher-venv/bin/python}"
    port="${CARDPUTER_PORT:-/dev/cu.usbmodem2101}"
    "$serial_python" "$project_dir/scripts/verify_audio_hil.py" \
      --port "$port" \
      --audio-probe "$probe" \
      --capture-seconds "${CARDPUTER_PHASE3_CAPTURE_SECONDS:-8}"
    "$project_dir/scripts/verify_macos_restart_mute_hil.py"
    printf 'PASS phase3_authenticated_udp_to_app_and_mute\n'
    exit 0
  fi
  sleep 1
done

printf 'BLOCKED phase3_no_authenticated_audio probe=%s\n' "$probe" >&2
if [ -f "$probe" ]; then
  PYTHONPATH="$project_dir" python3 -m harness.verifier.audio_runtime_probe --ready "$probe" || true
fi
exit 2
