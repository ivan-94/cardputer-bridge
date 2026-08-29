#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
device_probe="$build_root/audio-plugin/audio_device_probe"
pcm_consumer="${CARDPUTER_BRIDGE_PCM_CONSUMER:-$HOME/Applications/Cardputer Audio Verifier.app/Contents/MacOS/audio_pcm_consumer}"
test_producer="$build_root/audio-plugin/audio_test_producer"

set +e
runtime_policy_output="$("$project_dir/scripts/check-audio-hal-runtime.sh" 2>&1)"
runtime_policy_exit=$?
set -e
if [[ $runtime_policy_exit -eq 2 ]]; then
  printf 'CURRENT_GATE FF1=FAIL previous_E3=legacy_HAL_runtime_enumeration_spin\n' >&2
  printf '%s\n' "$runtime_policy_output" >&2
  exit 2
fi
if [[ $runtime_policy_exit -ne 0 ]]; then
  printf '%s\n' "$runtime_policy_output" >&2
  exit "$runtime_policy_exit"
fi
printf '%s\n' "$runtime_policy_output"
"$project_dir/scripts/verify-ff-1-preflight.sh"

if [[ -n "${CARDPUTER_BRIDGE_EVIDENCE_DIR:-}" ]]; then
  ff1_evidence_dir="$CARDPUTER_BRIDGE_EVIDENCE_DIR/ff1-audio"
else
  ff1_evidence_dir="$build_root/ff1/manual-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
mkdir -p "$ff1_evidence_dir"
producer_log="$ff1_evidence_dir/producer.log"
consumer_log="$ff1_evidence_dir/consumer.log"
running_probe_log="$ff1_evidence_dir/running-probe.log"
capture_raw="$ff1_evidence_dir/capture.f32le"
capture_metrics="$ff1_evidence_dir/metrics.json"
restart_raw="$ff1_evidence_dir/restart-muted.f32le"
restart_metrics="$ff1_evidence_dir/restart-muted-metrics.json"

run_bounded_probe() {
  local output_file="$1"
  shift
  "$@" >"$output_file" 2>&1 &
  local bounded_pid=$!
  for _bounded_tick in {1..750}; do
    if ! kill -0 "$bounded_pid" 2>/dev/null; then
      if wait "$bounded_pid"; then
        return 0
      else
        local bounded_exit=$?
        return "$bounded_exit"
      fi
    fi
    sleep 0.02
  done
  kill -9 "$bounded_pid" 2>/dev/null || true
  wait "$bounded_pid" 2>/dev/null || true
  return 124
}

initial_probe_log="$ff1_evidence_dir/initial-device-probe.log"
set +e
run_bounded_probe "$initial_probe_log" \
  "$device_probe" --require-input "Cardputer Microphone"
device_probe_exit=$?
set -e
cat "$initial_probe_log"
if [[ $device_probe_exit -eq 124 ]]; then
  printf 'FAIL FF1_COREAUDIO_ENUMERATION_TIMEOUT timeout_seconds=15 log=%s\n' \
    "$initial_probe_log" >&2
  exit 1
fi
if [[ $device_probe_exit -ne 0 ]]; then
  printf 'BLOCKED FF1_DEVICE_NOT_INSTALLED no_system_change_was_attempted\n' >&2
  exit 2
fi
if [[ ! -x "$pcm_consumer" ]]; then
  printf 'BLOCKED FF1_AUTHORIZED_CONSUMER_MISSING path=%s\n' "$pcm_consumer" >&2
  printf 'NEXT build and authorize Cardputer Audio Verifier.app once\n' >&2
  exit 2
fi

producer_pid=""
consumer_pid=""
cleanup_children() {
  if [[ -n "$producer_pid" ]] && kill -0 "$producer_pid" 2>/dev/null; then
    kill "$producer_pid" 2>/dev/null || true
    wait "$producer_pid" 2>/dev/null || true
  fi
  if [[ -n "$consumer_pid" ]] && kill -0 "$consumer_pid" 2>/dev/null; then
    kill "$consumer_pid" 2>/dev/null || true
    wait "$consumer_pid" 2>/dev/null || true
  fi
}
trap cleanup_children EXIT

"$pcm_consumer" \
  --capture-name "Cardputer Microphone" \
  --frames 144000 \
  --raw "$capture_raw" \
  --metrics "$capture_metrics" >"$consumer_log" 2>&1 &
consumer_pid=$!

sleep 0.1
if ! kill -0 "$consumer_pid" 2>/dev/null; then
  set +e
  wait "$consumer_pid"
  consumer_exit=$?
  set -e
  consumer_pid=""
  if [[ $consumer_exit -eq 3 ]]; then
    printf 'HUMAN_GATE FF1_MICROPHONE_PERMISSION_REQUIRED log=%s\n' \
      "$consumer_log" >&2
    exit 3
  fi
  printf 'FAIL FF1_CONSUMER_EXITED_BEFORE_PRODUCER exit=%s log=%s\n' \
    "$consumer_exit" "$consumer_log" >&2
  exit 1
fi

# macOS may serve kAudioDevicePropertyDeviceIsRunning from a stale HAL cache.
# Preserve it as diagnostic evidence, but use actual consumed PCM as the gate.
probe_attempt_log="$ff1_evidence_dir/running-probe-attempt.log"
set +e
run_bounded_probe "$probe_attempt_log" \
  "$device_probe" --require-running-input "Cardputer Microphone"
running_probe_exit=$?
set -e
cat "$probe_attempt_log" >>"$running_probe_log"
printf 'OBSERVED FF1_RUNNING_PROPERTY exit=%s log=%s\n' \
  "$running_probe_exit" "$running_probe_log"

"$test_producer" --ff1-pulse >"$producer_log" 2>&1 &
producer_pid=$!
producer_ready=false
for _attempt in {1..100}; do
  if grep -q '^READY audio_test_producer' "$producer_log"; then
    producer_ready=true
    break
  fi
  if ! kill -0 "$producer_pid" 2>/dev/null; then break; fi
  sleep 0.02
done
if [[ "$producer_ready" != true ]]; then
  printf 'FAIL FF1_PRODUCER_NOT_READY log=%s\n' "$producer_log" >&2
  exit 1
fi

set +e
wait "$consumer_pid"
consumer_exit=$?
consumer_pid=""
wait "$producer_pid"
producer_exit=$?
set -e
producer_pid=""
if [[ $consumer_exit -ne 0 ]]; then
  if [[ $consumer_exit -eq 3 ]]; then
    printf 'HUMAN_GATE FF1_MICROPHONE_PERMISSION_REQUIRED log=%s\n' \
      "$consumer_log" >&2
    exit 3
  fi
  printf 'FAIL FF1_CONSUMER_EXIT exit=%s log=%s\n' "$consumer_exit" "$consumer_log" >&2
  exit 1
fi
if [[ $producer_exit -ne 0 ]]; then
  printf 'FAIL FF1_PRODUCER_EXIT exit=%s log=%s\n' "$producer_exit" "$producer_log" >&2
  exit 1
fi
if ! grep -Eq '^OBSERVED audio_test_producer consumed_frames=[1-9][0-9]*$' "$producer_log"; then
  printf 'FAIL FF1_SHARED_BUFFER_NOT_CONSUMED log=%s\n' "$producer_log" >&2
  exit 1
fi
python3 "$project_dir/harness/verifier/pcm_metrics.py" "$capture_metrics"
python3 "$project_dir/harness/verifier/pcm_raw.py" \
  --require-counting-pulse-and-silence "$capture_raw"

"$pcm_consumer" \
  --capture-name "Cardputer Microphone" \
  --frames 4800 \
  --raw "$restart_raw" \
  --metrics "$restart_metrics"
python3 "$project_dir/harness/verifier/pcm_raw.py" \
  --require-silence "$restart_raw"

printf 'FF1_PARTIAL_MACHINE_ASSERTIONS_PASS device_format_pulse_stop_silence\n'
printf 'BLOCKED FF1_RELOAD_SOAK_AND_SYSTEM_UI_NOT_RUN evidence=%s\n' "$ff1_evidence_dir" >&2
exit 2
