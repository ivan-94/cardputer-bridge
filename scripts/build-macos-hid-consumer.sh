#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
output_dir="$build_root/hid-consumer"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
source="$project_dir/harness/macos/macos_hid_event_consumer.c"
binary="$output_dir/macos-hid-event-consumer"
stamp="$output_dir/source.sha256"
mkdir -p "$output_dir"

cache_key="$({ shasum -a 256 "$source"; DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx clang --version; } | shasum -a 256 | awk '{print $1}')"
if [[ ! -x "$binary" || ! -f "$stamp" || "$(<"$stamp")" != "$cache_key" ]]; then
  temporary="$binary.tmp.$$"
  trap 'rm -f "$temporary"' EXIT
  DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx clang \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    "$source" \
    -framework ApplicationServices \
    -o "$temporary"
  mv "$temporary" "$binary"
  printf '%s\n' "$cache_key" > "$stamp"
  trap - EXIT
fi

printf '%s\n' "$binary"
