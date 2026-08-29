#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version=""
output_dir="$project_dir/.release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --output) output_dir="${2:-}"; shift 2 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'Usage: %s --version X.Y.Z [--output DIR]\n' "$0" >&2
  exit 2
}
for tool in xcodegen xcodebuild xcrun codesign ditto plutil file shasum sed; do
  command -v "$tool" >/dev/null || { printf 'Missing tool: %s\n' "$tool" >&2; exit 1; }
done

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  developer_dir="$DEVELOPER_DIR"
elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  developer_dir="/Applications/Xcode-beta.app/Contents/Developer"
else
  developer_dir="$(xcode-select -p)"
fi

grep -Fq "set(PROJECT_VER \"$version\")" "$project_dir/firmware/CMakeLists.txt" || {
  printf 'Firmware version does not match %s\n' "$version" >&2
  exit 1
}
grep -Eq "MARKETING_VERSION:[[:space:]]*$version$" "$project_dir/macos/project.yml" || {
  printf 'macOS version does not match %s\n' "$version" >&2
  exit 1
}

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
build_root="$output_dir/build-macos"
derived_data="$build_root/release-xcode"
payload="$build_root/Cardputer-Bridge-v${version}-macOS-arm64"
archive="$output_dir/Cardputer-Bridge-v${version}-macOS-arm64.zip"
checksum="$output_dir/Cardputer-Bridge-v${version}-macOS-arm64.sha256"

case "$build_root" in
  "$output_dir"/build-macos|"$output_dir"/build-macos/*) ;;
  *) printf 'Unsafe release build root: %s\n' "$build_root" >&2; exit 1 ;;
esac
rm -rf "$build_root"
mkdir -p "$derived_data"

(
  cd "$project_dir/macos"
  xcodegen generate --spec project.yml
  DEVELOPER_DIR="$developer_dir" xcodebuild \
    -project CardputerBridge.xcodeproj \
    -scheme CardputerBridge \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    -destination 'platform=macOS,arch=arm64' \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    clean build
)

app="$derived_data/Build/Products/Release/Cardputer Bridge.app"
executable="$app/Contents/MacOS/Cardputer Bridge"
[[ -d "$app" ]] || { printf 'App bundle missing: %s\n' "$app" >&2; exit 1; }
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
[[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" == "$version" ]]
file "$executable" | grep -q 'Mach-O 64-bit executable arm64'

CARDPUTER_BRIDGE_BUILD_ROOT="$build_root" DEVELOPER_DIR="$developer_dir" "$project_dir/scripts/build-audio-plugin.sh" >/dev/null
driver="$build_root/audio-plugin/CardputerBridgeAudio.driver"
[[ -d "$driver" ]] || { printf 'Audio driver missing: %s\n' "$driver" >&2; exit 1; }
codesign --verify --deep --strict "$driver"

mkdir -p "$payload/Audio"
ditto "$app" "$payload/Cardputer Bridge.app"
ditto "$driver" "$payload/Audio/CardputerBridgeAudio.driver"
sed "s/@VERSION@/$version/g" "$project_dir/packaging/macos/INSTALL.md" > "$payload/INSTALL.md"
cp "$project_dir/packaging/macos/install-audio-plugin.command" "$payload/install-audio-plugin.command"
cp "$project_dir/packaging/macos/uninstall-audio-plugin.command" "$payload/uninstall-audio-plugin.command"
cp "$project_dir/packaging/macos/restore-audio-plugin.command" "$payload/restore-audio-plugin.command"
cp "$project_dir/scripts/check-audio-hal-runtime.sh" "$payload/check-audio-hal-runtime.sh"
chmod +x \
  "$payload/install-audio-plugin.command" \
  "$payload/uninstall-audio-plugin.command" \
  "$payload/restore-audio-plugin.command" \
  "$payload/check-audio-hal-runtime.sh"
codesign --verify --deep --strict "$payload/Cardputer Bridge.app"
codesign --verify --deep --strict "$payload/Audio/CardputerBridgeAudio.driver"

rm -f "$archive" "$checksum"
ditto -c -k --sequesterRsrc --keepParent "$payload" "$archive"
(
  cd "$output_dir"
  shasum -a 256 "$(basename "$archive")" > "$(basename "$checksum")"
  shasum -a 256 -c "$(basename "$checksum")"
)

verify_dir="$(mktemp -d)"
cleanup_verify() { rm -rf "$verify_dir"; }
trap cleanup_verify EXIT
ditto -x -k "$archive" "$verify_dir"
verified_payload="$verify_dir/$(basename "$payload")"
codesign --verify --deep --strict "$verified_payload/Cardputer Bridge.app"
codesign --verify --deep --strict "$verified_payload/Audio/CardputerBridgeAudio.driver"
[[ -x "$verified_payload/install-audio-plugin.command" ]]
[[ -x "$verified_payload/uninstall-audio-plugin.command" ]]
[[ -x "$verified_payload/restore-audio-plugin.command" ]]
[[ -x "$verified_payload/check-audio-hal-runtime.sh" ]]
[[ -f "$verified_payload/INSTALL.md" ]]
trap - EXIT
cleanup_verify
printf 'MACOS_RELEASE_PASS archive=%s checksum=%s\n' "$archive" "$checksum"
