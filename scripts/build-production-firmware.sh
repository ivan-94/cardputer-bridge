#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
firmware_dir="$project_dir/firmware"
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
build_dir="${CARDPUTER_PRODUCTION_BUILD_DIR:-$build_root/firmware-production}"
idf_entry="${IDF_CARDPUTER_BIN:-$HOME/.local/bin/idf-cardputer-5.4.2}"
signing_key="${CARDPUTER_FIRMWARE_SIGNING_KEY:-}"

if [[ -z "$signing_key" || ! -s "$signing_key" ]]; then
  printf 'FAIL missing CARDPUTER_FIRMWARE_SIGNING_KEY\n' >&2
  exit 2
fi
if [[ ! -x "$idf_entry" ]]; then
  printf 'FAIL missing ESP-IDF launcher: %s\n' "$idf_entry" >&2
  exit 2
fi

mkdir -p "$firmware_dir/keys" "$build_dir"
install -m 600 "$signing_key" \
  "$firmware_dir/keys/firmware-signing-rsa3072.pem"
trap 'rm -f "$firmware_dir/keys/firmware-signing-rsa3072.pem"' EXIT

# sdkconfig.production is generated from the two tracked defaults. Reusing an
# older generated file would silently preserve obsolete TLS settings.
rm -f "$firmware_dir/sdkconfig.production"
SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.production.defaults" \
  "$idf_entry" -C "$firmware_dir" -B "$build_dir" \
  -D SDKCONFIG="$firmware_dir/sdkconfig.production" \
  fullclean
SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.production.defaults" \
  "$idf_entry" -C "$firmware_dir" -B "$build_dir" \
  -D SDKCONFIG="$firmware_dir/sdkconfig.production" \
  build

grep -q '^CONFIG_SECURE_SIGNED_ON_UPDATE_NO_SECURE_BOOT=y$' \
  "$firmware_dir/sdkconfig.production"
grep -q '^CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y$' \
  "$firmware_dir/sdkconfig.production"
grep -q '^CONFIG_MBEDTLS_DYNAMIC_BUFFER=y$' \
  "$firmware_dir/sdkconfig.production"
grep -q '^CONFIG_MBEDTLS_TLS_CLIENT_ONLY=y$' \
  "$firmware_dir/sdkconfig.production"
grep -q '^CONFIG_ESP_HTTPS_OTA_ALLOW_HTTP=y$' \
  "$firmware_dir/sdkconfig.production"
"$idf_entry" -C "$firmware_dir" -B "$build_dir" secure-verify-signature \
  --version 2 \
  --keyfile "$signing_key" \
  "$build_dir/cardputer_bridge_firmware.bin"
printf 'PRODUCTION_FIRMWARE_BUILD_PASS dir=%s\n' "$build_dir"
