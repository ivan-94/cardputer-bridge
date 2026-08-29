#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
build_dir="${CARDPUTER_FIRMWARE_BUILD_DIR:-$build_root/firmware}"
binary="$build_dir/cardputer_bridge_firmware.bin"
lock="$project_dir/firmware/dependencies.lock"
esptool="${ESPTOOL:-}"
if [[ -z "$esptool" ]]; then
  esptool="$(find "$HOME/.espressif/python_env" -path '*/bin/esptool.py' -type f 2>/dev/null | head -n 1)"
fi
test -n "$esptool"
test -x "$esptool"

python3 "$project_dir/tests/integration/verify_device_ui_policy.py" \
  "$project_dir/firmware/main/main.cpp" \
  "$project_dir/firmware/components/device_audio/include/device_audio.hpp"
python3 "$project_dir/tests/integration/verify_device_audio_policy.py" \
  "$project_dir/firmware/components/device_audio/device_audio.cpp"
CARDPUTER_FIRMWARE_BUILD_DIR="$build_dir" "$project_dir/scripts/build-firmware.sh"
test -s "$binary"
grep -q '^target: esp32s3$' "$lock"
grep -q '^  m5stack/m5unified:$' "$lock"
grep -q '^    version: 0.2.21$' "$lock"
grep -q '^  m5stack/m5gfx:$' "$lock"
grep -q '^    version: 0.2.28$' "$lock"
grep -q '^CONFIG_FREERTOS_HZ=1000$' "$project_dir/firmware/sdkconfig"
grep -q '^CONFIG_FREERTOS_HZ=1000$' "$project_dir/firmware/sdkconfig.defaults"
grep -q '^CONFIG_APP_REPRODUCIBLE_BUILD=y$' "$project_dir/firmware/sdkconfig"
grep -q '^CONFIG_APP_REPRODUCIBLE_BUILD=y$' "$project_dir/firmware/sdkconfig.defaults"
grep -q '^CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y$' "$project_dir/firmware/sdkconfig"
grep -q '^CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=y$' "$project_dir/firmware/sdkconfig"
grep -Eq '^factory,[[:space:]]*app,[[:space:]]*factory,[[:space:]]*0x10000,[[:space:]]*0x200000,' "$project_dir/firmware/partitions.csv"
grep -Eq '^ota_0,[[:space:]]*app,[[:space:]]*ota_0,[[:space:]]*0x210000,[[:space:]]*0x200000,' "$project_dir/firmware/partitions.csv"
grep -Eq '^ota_1,[[:space:]]*app,[[:space:]]*ota_1,[[:space:]]*0x410000,[[:space:]]*0x200000,' "$project_dir/firmware/partitions.csv"
grep -Eq '^otadata,[[:space:]]*data,[[:space:]]*ota,[[:space:]]*0x610000,[[:space:]]*0x2000,' "$project_dir/firmware/partitions.csv"
grep -Eq '^[[:space:]]*set\(PROJECT_VER "0\.10\.0"\)$' \
  "$project_dir/firmware/CMakeLists.txt"
image_info="$("$esptool" image_info "$binary")"
grep -q 'ESP32-S3' <<EOF
$image_info
EOF
grep -q 'App version: 0.10.0' <<EOF
$image_info
EOF
size="$(stat -f '%z' "$binary")"
sha256="$(shasum -a 256 "$binary" | awk '{print $1}')"
printf 'FIRMWARE_BUILD_PASS size=%s sha256=%s binary=%s\n' "$size" "$sha256" "$binary"
