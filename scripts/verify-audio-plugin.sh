#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
bundle="$build_root/audio-plugin/CardputerBridgeAudio.driver"
executable="$bundle/Contents/MacOS/CardputerBridgeAudio"
probe="$build_root/audio-plugin/factory_probe"
device_probe="$build_root/audio-plugin/audio_device_probe"
driver_contract_probe="$build_root/audio-plugin/driver_contract_probe"
audio_pcm_consumer="$build_root/audio-plugin/audio_pcm_consumer"
audio_test_producer="$build_root/audio-plugin/audio_test_producer"
audio_broker_test_server="$build_root/audio-plugin/audio_broker_test_server"
audio_shared_memory_test="$build_root/audio-plugin/audio_shared_memory_test"
ipc_test_name="/cardputer_bridge_test_v$$"

ring_policy="$project_dir/tests/integration/verify_audio_ring_spsc_policy.py"
ring_header="$project_dir/audio-plugin/AudioBridgeSharedMemory.hpp"
if python3 "$ring_policy" \
    "$project_dir/harness/fixtures/invalid-audio-ring-multiwriter.cpp" \
    "$ring_header" >/dev/null 2>&1; then
  printf 'FAIL AUDIO_RING_SPSC_BAD_FIXTURE_ACCEPTED\n' >&2
  exit 1
fi
printf 'PASS audio_ring_spsc_policy_rejects_bad_fixture\n'
python3 "$ring_policy" \
  "$project_dir/audio-plugin/AudioBridgeSharedMemory.cpp" \
  "$ring_header"

"$project_dir/scripts/build-audio-plugin.sh"
python3 "$project_dir/tests/integration/verify_audio_hal_runtime_policy.py" \
  "$project_dir/scripts/check-audio-hal-runtime.sh"
runtime_coreaudio_allowed=true
set +e
runtime_policy_output="$("$project_dir/scripts/check-audio-hal-runtime.sh" 2>&1)"
runtime_policy_exit=$?
set -e
if [[ $runtime_policy_exit -eq 2 ]]; then
  runtime_coreaudio_allowed=false
  printf '%s\n' "$runtime_policy_output" >&2
elif [[ $runtime_policy_exit -ne 0 ]]; then
  printf '%s\n' "$runtime_policy_output" >&2
  exit "$runtime_policy_exit"
else
  printf '%s\n' "$runtime_policy_output"
fi
plutil -lint "$bundle/Contents/Info.plist"
test "$(plutil -extract CFBundlePackageType raw "$bundle/Contents/Info.plist")" = "BNDL"
file "$executable" | grep -q 'Mach-O 64-bit bundle arm64'
nm -gU "$executable" | grep -q '_CardputerBridgeAudioFactory'
codesign --verify --deep --strict --verbose=2 "$bundle"
"$probe" "$executable"
"$audio_shared_memory_test"
env CARDPUTER_BRIDGE_AUDIO_TEST_MODE=1 CARDPUTER_BRIDGE_AUDIO_SHM_NAME="$ipc_test_name" \
  "$driver_contract_probe" "$executable" publication
env CARDPUTER_BRIDGE_AUDIO_TEST_MODE=1 CARDPUTER_BRIDGE_AUDIO_SHM_NAME="$ipc_test_name" \
  "$driver_contract_probe" "$executable" hal-scan
env CARDPUTER_BRIDGE_AUDIO_TEST_MODE=1 CARDPUTER_BRIDGE_AUDIO_SHM_NAME="$ipc_test_name" \
  "$driver_contract_probe" "$executable" format
env CARDPUTER_BRIDGE_AUDIO_TEST_MODE=1 CARDPUTER_BRIDGE_AUDIO_SHM_NAME="$ipc_test_name" \
  "$driver_contract_probe" "$executable" silence
env CARDPUTER_BRIDGE_AUDIO_TEST_MODE=1 CARDPUTER_BRIDGE_AUDIO_SHM_NAME="$ipc_test_name" \
  "$driver_contract_probe" "$executable" surface
python3 "$project_dir/harness/verifier/audio_bundle.py" "$bundle" "$probe"
if [[ "$runtime_coreaudio_allowed" == true ]]; then
  python3 "$project_dir/tests/integration/verify_audio_device_probe.py" "$device_probe"
  python3 "$project_dir/tests/integration/verify_audio_pcm_consumer.py" "$audio_pcm_consumer"
else
  printf 'NOT_RUN CoreAudio_client_enumeration_and_PCM_consumer reason=unvalidated_HAL_runtime\n'
fi
python3 "$project_dir/tests/integration/verify_audio_ipc.py" \
  "$audio_test_producer" "$driver_contract_probe" "$executable"
python3 "$project_dir/tests/integration/verify_audio_fd_broker.py" \
  "$audio_broker_test_server" "$audio_test_producer" \
  "$driver_contract_probe" "$executable"
python3 "$project_dir/tests/integration/verify_audio_ipc_boundary.py" \
  "$project_dir/scripts/verify-audio-ipc-boundary.sh"
python3 "$project_dir/tests/integration/verify_audio_plugin_lifecycle.py" "$bundle"
printf 'AUDIO_PLUGIN_BUILD_PASS bundle=%s\n' "$bundle"
