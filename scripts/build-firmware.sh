#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
firmware_dir="$project_root/firmware"
idf_entry="${IDF_CARDPUTER_BIN:-$HOME/.local/bin/idf-cardputer-5.4.2}"
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
firmware_build_dir="${CARDPUTER_FIRMWARE_BUILD_DIR:-$build_root/firmware}"

test -x "$idf_entry"

if [ ! -f "$firmware_dir/sdkconfig" ]; then
  "$idf_entry" -C "$firmware_dir" -B "$firmware_build_dir" set-target esp32s3
fi

"$idf_entry" -C "$firmware_dir" -B "$firmware_build_dir" build
