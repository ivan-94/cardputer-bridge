#!/bin/sh
set -eu

xcode_developer_dir="${XCODE_DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
idf_entry="${IDF_CARDPUTER_BIN:-$HOME/.local/bin/idf-cardputer-5.4.2}"

test -d "$xcode_developer_dir"
test -x "$idf_entry"
command -v cmake >/dev/null
command -v python3 >/dev/null

printf 'XCODE_DEVELOPER_DIR=%s\n' "$xcode_developer_dir"
DEVELOPER_DIR="$xcode_developer_dir" xcodebuild -version
DEVELOPER_DIR="$xcode_developer_dir" xcrun swift --version | head -1
"$idf_entry" --version
cmake --version | head -1
python3 --version
