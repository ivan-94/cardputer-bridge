#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

cd "$project_root"
python3 -m unittest discover -s tests/contract -p 'test_*.py'

set +e
negative_output=$(python3 -m harness.verifier.event_stream harness/fixtures/invalid-control-loss.ndjson 2>&1)
negative_status=$?
set -e

printf '%s\n' "$negative_output"
if [ "$negative_status" -ne 1 ]; then
  printf 'FAIL negative fixture expected exit 1, got %s\n' "$negative_status" >&2
  exit 1
fi

printf 'PASS verifier_rejects_known_bad_fixture\n'

set +e
audio_negative_output=$(python3 harness/verifier/audio_bundle.py harness/fixtures/invalid-audio.driver 2>&1)
audio_negative_status=$?
set -e

printf '%s\n' "$audio_negative_output"
if [ "$audio_negative_status" -ne 1 ]; then
  printf 'FAIL audio bundle negative fixture expected exit 1, got %s\n' "$audio_negative_status" >&2
  exit 1
fi

printf 'PASS audio_verifier_cli_rejects_known_bad_fixture\n'

set +e
gate_negative_output=$(python3 -m harness.verifier.gate_contract harness/fixtures/invalid-ff1-contract.json 2>&1)
gate_negative_status=$?
set -e

printf '%s\n' "$gate_negative_output"
if [ "$gate_negative_status" -ne 1 ]; then
  printf 'FAIL gate contract negative fixture expected exit 1, got %s\n' "$gate_negative_status" >&2
  exit 1
fi

python3 -m harness.verifier.gate_contract harness/contracts/ff-1.json
python3 -m harness.verifier.gate_contract harness/contracts/ff-2.json
printf 'PASS gate_contract_cli_red_and_green\n'

set +e
input_negative_output=$(python3 -m harness.verifier.input_event_stream harness/fixtures/invalid-hid-events.ndjson 2>&1)
input_negative_status=$?
set -e

printf '%s\n' "$input_negative_output"
if [ "$input_negative_status" -ne 1 ]; then
  printf 'FAIL input event negative fixture expected exit 1, got %s\n' "$input_negative_status" >&2
  exit 1
fi
printf 'PASS input_event_verifier_cli_rejects_stuck_hid_fixture\n'

set +e
pcm_negative_output=$(python3 -m harness.verifier.pcm_metrics harness/fixtures/invalid-pcm-metrics.json 2>&1)
pcm_negative_status=$?
set -e

printf '%s\n' "$pcm_negative_output"
if [ "$pcm_negative_status" -ne 1 ]; then
  printf 'FAIL PCM metrics negative fixture expected exit 1, got %s\n' "$pcm_negative_status" >&2
  exit 1
fi
printf 'PASS pcm_metrics_cli_rejects_non_silent_tail\n'
