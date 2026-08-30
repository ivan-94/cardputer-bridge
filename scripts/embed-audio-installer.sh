#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:-}"
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"

[[ -d "$app/Contents/Resources" ]] || {
  printf 'App bundle is missing or incomplete: %s\n' "$app" >&2
  exit 1
}

CARDPUTER_BRIDGE_BUILD_ROOT="$build_root" \
  "$project_dir/scripts/build-audio-plugin.sh" >/dev/null

driver="$build_root/audio-plugin/CardputerBridgeAudio.driver"
installer_root="$app/Contents/Resources/AudioInstaller"
driver_archive="$installer_root/CardputerBridgeAudio.driver.zip"
temporary_archive="$installer_root/.CardputerBridgeAudio.driver.$$.zip"

[[ -d "$driver" ]] || {
  printf 'Audio driver missing: %s\n' "$driver" >&2
  exit 1
}
codesign --verify --deep --strict "$driver"

mkdir -p "$installer_root"
cleanup() {
  cleanup_status=$?
  rm -f "$temporary_archive"
  exit "$cleanup_status"
}
trap cleanup EXIT

ditto -c -k --sequesterRsrc --keepParent "$driver" "$temporary_archive"
mv -f "$temporary_archive" "$driver_archive"
cp \
  "$project_dir/packaging/macos/app-resources/AudioInstaller/install-bundled-audio-driver.sh" \
  "$installer_root/install-bundled-audio-driver.sh"
cp \
  "$project_dir/scripts/check-audio-hal-runtime.sh" \
  "$installer_root/check-audio-hal-runtime.sh"
chmod +x \
  "$installer_root/install-bundled-audio-driver.sh" \
  "$installer_root/check-audio-hal-runtime.sh"

[[ -f "$driver_archive" ]]
[[ -x "$installer_root/install-bundled-audio-driver.sh" ]]
[[ -x "$installer_root/check-audio-hal-runtime.sh" ]]

trap - EXIT
printf 'AUDIO_INSTALLER_EMBED_PASS app=%s\n' "$app"
