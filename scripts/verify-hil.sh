#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/resolve-serial-python.sh"
port="${CARDPUTER_PORT:-/dev/cu.usbmodem2101}"
python="$(resolve_cardputer_serial_python)"

exec "$python" "$script_dir/verify_firmware_boot.py" \
  --port "$port" \
  --timeout "${CARDPUTER_BOOT_TIMEOUT_SECONDS:-8}"
