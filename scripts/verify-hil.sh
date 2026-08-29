#!/bin/sh
set -eu

port="${CARDPUTER_PORT:-/dev/cu.usbmodem2101}"
python="${CARDPUTER_SERIAL_PYTHON:-$HOME/.local/share/cardputer-bridge/launcher-venv/bin/python}"

test -x "$python"
exec "$python" "$(dirname "$0")/verify_firmware_boot.py" \
  --port "$port" \
  --timeout "${CARDPUTER_BOOT_TIMEOUT_SECONDS:-8}"
