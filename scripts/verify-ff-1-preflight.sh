#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

(
  cd "$project_dir"
  python3 -m harness.verifier.gate_contract harness/contracts/ff-1.json
)
"$project_dir/scripts/verify-contracts.sh"
python3 "$project_dir/tests/integration/verify_ff1_runner.py" \
  "$project_dir/scripts/verify-ff-1.sh"
"$project_dir/scripts/verify-audio-plugin.sh"
"$project_dir/scripts/verify-audio-ipc-boundary.sh"

printf 'FF1_PREFLIGHT_PASS stage=B boundary=product_driver_ipc_and_recoverable_installer\n'
printf 'FF1_PREFLIGHT_BOUNDARY no_HAL_write_no_coreaudiod_restart_no_virtual_device_claim\n'
printf 'FF1_PREFLIGHT_NEXT validated_OS_HAL_runtime_then_real_E3_capture\n'
