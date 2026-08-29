#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
macos_dir="$project_dir/macos"
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
derived_data="$build_root/xcode"
app="$derived_data/Build/Products/Debug/Cardputer Bridge.app"
executable="$app/Contents/MacOS/Cardputer Bridge"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
. "$project_dir/scripts/macos-build-lock.sh"
acquire_macos_build_lock "$build_root"

ui_policy_verifier="$project_dir/tests/integration/verify_macos_system_microphone_ui_policy.py"
invalid_ui_fixture="$project_dir/harness/fixtures/invalid-macos-system-microphone-ui.swift"
app_source="$macos_dir/Sources/CardputerBridgeApp/CardputerBridgeApp.swift"
audio_bridge_source="$macos_dir/Sources/CardputerBridgeApp/AudioBridgeProducerBridge.cpp"
product_ui_verifier="$project_dir/tests/integration/verify_product_ui_policy.py"
invalid_product_ui_fixture="$project_dir/harness/fixtures/invalid-product-ui.swift"
ble_source="$macos_dir/Sources/CardputerBridgeApp/BLEBridgeController.swift"

if python3 "$ui_policy_verifier" "$invalid_ui_fixture" "$audio_bridge_source" \
    >/dev/null 2>&1; then
  printf 'FAIL MACOS_SYSTEM_MICROPHONE_UI_POLICY_BAD_FIXTURE_ACCEPTED fixture=%s\n' \
    "$invalid_ui_fixture" >&2
  exit 1
fi
printf 'PASS macos_system_microphone_ui_policy_rejects_bad_fixture\n'
python3 "$ui_policy_verifier" "$app_source" "$audio_bridge_source"
if python3 "$product_ui_verifier" "$invalid_product_ui_fixture" \
    "$invalid_product_ui_fixture" "$macos_dir" >/dev/null 2>&1; then
  printf 'FAIL PRODUCT_UI_POLICY_BAD_FIXTURE_ACCEPTED fixture=%s\n' \
    "$invalid_product_ui_fixture" >&2
  exit 1
fi
printf 'PASS product_ui_policy_rejects_bad_fixture\n'
python3 "$product_ui_verifier" "$app_source" "$ble_source" "$macos_dir"

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
    clean test
)

codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
test "$(plutil -extract CFBundlePackageType raw "$app/Contents/Info.plist")" = "APPL"
test "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" = "io.nexu.cardputerbridge.app"
test -n "$(plutil -extract NSBluetoothAlwaysUsageDescription raw "$app/Contents/Info.plist")"
file "$executable" | grep -q 'Mach-O 64-bit executable arm64'
printf 'MACOS_APP_BUILD_PASS app=%s\n' "$app"
