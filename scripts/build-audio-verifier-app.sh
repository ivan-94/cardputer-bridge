#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
consumer="$build_root/audio-plugin/audio_pcm_consumer"
app="$build_root/audio-plugin/Cardputer Audio Verifier.app"
executable="$app/Contents/MacOS/audio_pcm_consumer"

if [[ ! -x "$consumer" ]]; then
  "$project_dir/scripts/build-audio-plugin.sh" >/dev/null
fi

mkdir -p "$app/Contents/MacOS"
cp "$project_dir/audio-plugin/AudioPCMConsumerInfo.plist" "$app/Contents/Info.plist"
cp "$consumer" "$executable"
chmod 0755 "$executable"
codesign --force --sign - \
  --identifier io.nexu.cardputerbridge.audio-verifier \
  "$app" >/dev/null
codesign --verify --strict "$app"

printf '%s\n' "$app"
