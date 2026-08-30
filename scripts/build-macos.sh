#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
macos_dir="$project_dir/macos"
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
derived_data="$build_root/xcode"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
. "$project_dir/scripts/macos-build-lock.sh"
acquire_macos_build_lock "$build_root"

command -v xcodegen >/dev/null
(
  cd "$macos_dir"
  xcodegen generate --spec project.yml
  DEVELOPER_DIR="$developer_dir" xcodebuild \
    -project CardputerBridge.xcodeproj \
    -scheme CardputerBridge \
    -configuration Debug \
    -derivedDataPath "$derived_data" \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO \
    build
)

app="$derived_data/Build/Products/Debug/Cardputer Bridge.app"
CARDPUTER_BRIDGE_BUILD_ROOT="$build_root" DEVELOPER_DIR="$developer_dir" \
  "$project_dir/scripts/embed-audio-installer.sh" "$app"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

printf '%s\n' "$app"
