#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

"$script_dir/build-host.sh"
ctest --test-dir "$project_root/artifacts/build/host" --output-on-failure

evidence_dir="${CARDPUTER_BRIDGE_EVIDENCE_DIR:-$project_root/artifacts/verification/manual-host}"
events_path="$evidence_dir/host-events.ndjson"
mkdir -p "$evidence_dir"
"$project_root/artifacts/build/host/bridge_domain_host" \
  < "$project_root/harness/fixtures/host-scenario.ndjson" \
  > "$events_path"
(cd "$project_root" && python3 -m harness.verifier.event_stream "$events_path")
cat "$events_path"
