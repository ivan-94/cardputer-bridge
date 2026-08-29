#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
bundle="$build_root/audio-plugin/CardputerBridgeAudio.driver"
staging_bundle="$build_root/audio-plugin/.CardputerBridgeAudio.driver.$$"
executable="$staging_bundle/Contents/MacOS/CardputerBridgeAudio"
probe="$build_root/audio-plugin/factory_probe"
device_probe="$build_root/audio-plugin/audio_device_probe"
driver_contract_probe="$build_root/audio-plugin/driver_contract_probe"
audio_pcm_consumer="$build_root/audio-plugin/audio_pcm_consumer"
audio_test_producer="$build_root/audio-plugin/audio_test_producer"
audio_broker_test_server="$build_root/audio-plugin/audio_broker_test_server"
audio_shared_memory_test="$build_root/audio-plugin/audio_shared_memory_test"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  developer_dir="$DEVELOPER_DIR"
elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  developer_dir="/Applications/Xcode-beta.app/Contents/Developer"
else
  developer_dir="$(xcode-select -p)"
fi
compiler="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"
sdk="$(DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-path)"

case "$staging_bundle" in
  "$build_root"/audio-plugin/.CardputerBridgeAudio.driver.*) ;;
  *) printf 'FAIL unsafe staging path=%s\n' "$staging_bundle" >&2; exit 1 ;;
esac
cleanup_staging() {
  cleanup_exit=$?
  rm -rf "$staging_bundle"
  exit "$cleanup_exit"
}
trap cleanup_staging EXIT
rm -rf "$staging_bundle"
mkdir -p "$staging_bundle/Contents/MacOS"
cp "$project_dir/audio-plugin/Info.plist" "$staging_bundle/Contents/Info.plist"

"$compiler" \
  -std=c++17 -Wall -Wextra -Werror -fvisibility=hidden \
  -isysroot "$sdk" -mmacosx-version-min=15.0 \
  -bundle "$project_dir/audio-plugin/CardputerBridgeAudioDriver.cpp" \
  "$project_dir/audio-plugin/AudioBridgeSharedMemory.cpp" \
  "$project_dir/audio-plugin/AudioBridgeFDBroker.cpp" \
  -framework CoreAudio -framework CoreFoundation \
  -o "$executable"

"$compiler" \
  -std=c++17 -Wall -Wextra -Werror \
  -isysroot "$sdk" -mmacosx-version-min=15.0 \
  "$project_dir/audio-plugin/factory_probe.cpp" \
  -framework CoreAudio -framework CoreFoundation \
  -o "$probe"

"$compiler" \
  -std=c++17 -Wall -Wextra -Werror \
  -isysroot "$sdk" -mmacosx-version-min=15.0 \
  "$project_dir/audio-plugin/audio_device_probe.cpp" \
  -framework CoreAudio -framework CoreFoundation \
  -o "$device_probe"

"$compiler" \
  -std=c++17 -Wall -Wextra -Werror \
  -isysroot "$sdk" -mmacosx-version-min=15.0 \
  "$project_dir/audio-plugin/driver_contract_probe.cpp" \
  -framework CoreAudio -framework CoreFoundation \
  -o "$driver_contract_probe"

"$compiler" \
  -x objective-c++ -std=c++17 -Wall -Wextra -Werror -fblocks -fobjc-arc \
  -isysroot "$sdk" -mmacosx-version-min=15.0 \
  "$project_dir/audio-plugin/audio_pcm_consumer.cpp" \
  -framework AppKit -framework AVFoundation -framework CoreAudio -framework CoreFoundation \
  -o "$audio_pcm_consumer"

"$compiler" \
  -std=c++17 -Wall -Wextra -Werror \
  -isysroot "$sdk" -mmacosx-version-min=15.0 \
  "$project_dir/audio-plugin/audio_test_producer.cpp" \
  "$project_dir/audio-plugin/AudioBridgeSharedMemory.cpp" \
  "$project_dir/audio-plugin/AudioBridgeFDBroker.cpp" \
  -framework CoreAudio -framework CoreFoundation \
  -o "$audio_test_producer"

"$compiler" \
  -std=c++17 -Wall -Wextra -Werror \
  -isysroot "$sdk" -mmacosx-version-min=15.0 \
  "$project_dir/audio-plugin/audio_broker_test_server.cpp" \
  "$project_dir/audio-plugin/AudioBridgeSharedMemory.cpp" \
  "$project_dir/audio-plugin/AudioBridgeFDBroker.cpp" \
  -framework CoreAudio -framework CoreFoundation \
  -o "$audio_broker_test_server"

"$compiler" \
  -std=c++17 -Wall -Wextra -Werror \
  -isysroot "$sdk" -mmacosx-version-min=15.0 \
  "$project_dir/audio-plugin/audio_shared_memory_test.cpp" \
  "$project_dir/audio-plugin/AudioBridgeSharedMemory.cpp" \
  "$project_dir/audio-plugin/AudioBridgeFDBroker.cpp" \
  -framework CoreAudio -framework CoreFoundation \
  -o "$audio_shared_memory_test"

codesign --force --sign - "$staging_bundle"
codesign --verify --deep --strict --verbose=2 "$staging_bundle"

case "$bundle" in
  "$build_root"/audio-plugin/CardputerBridgeAudio.driver) ;;
  *) printf 'FAIL unsafe bundle path=%s\n' "$bundle" >&2; exit 1 ;;
esac
rm -rf "$bundle"
mv "$staging_bundle" "$bundle"
trap - EXIT

printf '%s\n' "$bundle"
