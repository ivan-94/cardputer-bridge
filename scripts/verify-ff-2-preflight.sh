#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$project_dir/artifacts/build/host"
evidence_dir="${CARDPUTER_BRIDGE_EVIDENCE_DIR:-$project_dir/artifacts/verification/manual-ff2-preflight}"
events_path="$evidence_dir/input-events.ndjson"
mkdir -p "$evidence_dir"

cd "$project_dir"
python3 -m harness.verifier.gate_contract harness/contracts/ff-2.json

set +e
negative_output="$(python3 -m harness.verifier.input_event_stream \
  harness/fixtures/invalid-hid-events.ndjson 2>&1)"
negative_exit=$?
set -e
printf '%s\n' "$negative_output"
if [[ $negative_exit -ne 1 ]]; then
  printf 'FAIL FF2_INPUT_VERIFIER_RED_EXPECTED exit=%s\n' "$negative_exit" >&2
  exit 1
fi
printf 'PASS ff2_input_verifier_rejects_stuck_hid_fixture\n'

"$project_dir/scripts/build-host.sh"
ctest --test-dir "$build_dir" --output-on-failure \
  -R 'input_router_test|input_router_host_verifier'

"$build_dir/input_router_host" \
  < "$project_dir/harness/fixtures/input-router-scenario.ndjson" \
  > "$events_path"
python3 -m harness.verifier.input_event_stream "$events_path"

printf 'FF2_PREFLIGHT_PASS evidence_level=E0-E2 runtime_ble_hid_gatt=NOT_RUN events=%s\n' \
  "$events_path"
