#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
firmware_dir="$project_root/firmware"
idf_entry="${IDF_CARDPUTER_BIN:-$HOME/.local/bin/idf-cardputer-5.4.2}"
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
diagnostic_build_dir="${CARDPUTER_LED_DIAGNOSTIC_BUILD_DIR:-$build_root/firmware-led-diagnostic}"

test -x "$idf_entry"

"$idf_entry" \
  -C "$firmware_dir" \
  -B "$diagnostic_build_dir" \
  -D CARDPUTER_LED_DIAGNOSTIC=ON \
  build
