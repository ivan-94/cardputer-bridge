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
for tool in xcodegen xcodebuild xcrun codesign create-dmg ditto hdiutil plutil file shasum sed; do
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
dmg="$output_dir/Cardputer-Bridge-v${version}-macOS-arm64.dmg"
dmg_checksum="$output_dir/Cardputer-Bridge-v${version}-macOS-arm64.dmg.sha256"

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
[[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" == "$version" ]]
file "$executable" | grep -q 'Mach-O 64-bit executable arm64'

CARDPUTER_BRIDGE_BUILD_ROOT="$build_root" DEVELOPER_DIR="$developer_dir" \
  "$project_dir/scripts/embed-audio-installer.sh" "$app"
driver="$build_root/audio-plugin/CardputerBridgeAudio.driver"
[[ -d "$driver" ]] || { printf 'Audio driver missing: %s\n' "$driver" >&2; exit 1; }
codesign --verify --deep --strict "$driver"

audio_installer_resources="$app/Contents/Resources/AudioInstaller"
driver_archive="$audio_installer_resources/CardputerBridgeAudio.driver.zip"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
[[ -f "$driver_archive" ]]
[[ ! -e "$audio_installer_resources/Audio/CardputerBridgeAudio.driver" ]]
driver_archive_verify="$build_root/driver-archive-verify"
mkdir -p "$driver_archive_verify"
ditto -x -k "$driver_archive" "$driver_archive_verify"
codesign --verify --deep --strict \
  "$driver_archive_verify/CardputerBridgeAudio.driver"
"$project_dir/scripts/verify-macos-app-launch.sh" "$app"

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

rm -f "$archive" "$checksum" "$dmg" "$dmg_checksum"
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

dmg_source="$build_root/dmg-source"
mkdir -p "$dmg_source"
ditto "$app" "$dmg_source/Cardputer Bridge.app"
sed "s/@VERSION@/$version/g" \
  "$project_dir/packaging/macos/dmg/安装说明.html" \
  > "$dmg_source/安装说明.html"
volicon="$app/Contents/Resources/AppIcon.icns"
[[ -f "$volicon" ]] || { printf 'App volume icon missing: %s\n' "$volicon" >&2; exit 1; }

create-dmg \
  --volname "Cardputer Bridge $version" \
  --volicon "$volicon" \
  --background "$project_dir/packaging/macos/dmg/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 720 460 \
  --icon-size 112 \
  --text-size 13 \
  --icon "Cardputer Bridge.app" 170 225 \
  --hide-extension "Cardputer Bridge.app" \
  --app-drop-link 550 225 \
  --icon "安装说明.html" 360 105 \
  --hide-extension "安装说明.html" \
  --no-internet-enable \
  "$dmg" \
  "$dmg_source"

hdiutil verify "$dmg"
mount_root="$(mktemp -d)"
mountpoint="$mount_root/Cardputer Bridge"
mkdir -p "$mountpoint"
dmg_attached=0
cleanup_dmg_verify() {
  cleanup_status=$?
  if [[ $dmg_attached -eq 1 ]]; then
    hdiutil detach "$mountpoint" -force >/dev/null || true
  fi
  rm -rf "$mount_root"
  exit "$cleanup_status"
}
trap cleanup_dmg_verify EXIT
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mountpoint" >/dev/null
dmg_attached=1
mounted_app="$mountpoint/Cardputer Bridge.app"
[[ -d "$mounted_app" ]]
[[ -L "$mountpoint/Applications" ]]
[[ "$(readlink "$mountpoint/Applications")" == "/Applications" ]]
[[ -f "$mountpoint/安装说明.html" ]]
[[ -x "$mounted_app/Contents/Resources/AudioInstaller/install-bundled-audio-driver.sh" ]]
[[ -x "$mounted_app/Contents/Resources/AudioInstaller/check-audio-hal-runtime.sh" ]]
[[ -f "$mounted_app/Contents/Resources/AudioInstaller/CardputerBridgeAudio.driver.zip" ]]
[[ ! -e "$mounted_app/Contents/Resources/AudioInstaller/Audio/CardputerBridgeAudio.driver" ]]
codesign --verify --deep --strict "$mounted_app"
mounted_driver_verify="$mount_root/driver-verify"
mkdir -p "$mounted_driver_verify"
ditto -x -k \
  "$mounted_app/Contents/Resources/AudioInstaller/CardputerBridgeAudio.driver.zip" \
  "$mounted_driver_verify"
codesign --verify --deep --strict "$mounted_driver_verify/CardputerBridgeAudio.driver"
hdiutil detach "$mountpoint" >/dev/null
dmg_attached=0
trap - EXIT
rm -rf "$mount_root"

(
  cd "$output_dir"
  shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg_checksum")"
  shasum -a 256 -c "$(basename "$dmg_checksum")"
)
printf 'MACOS_RELEASE_PASS archive=%s checksum=%s dmg=%s dmg_checksum=%s\n' \
  "$archive" "$checksum" "$dmg" "$dmg_checksum"
