#!/bin/sh

resolve_cardputer_serial_python() {
  for cardputer_serial_candidate in \
    "${CARDPUTER_SERIAL_PYTHON:-}" \
    "$HOME/.local/share/cardputer-bridge/launcher-venv/bin/python" \
    "$HOME"/.espressif/python_env/*/bin/python \
    "$(command -v python3 2>/dev/null || true)"
  do
    if [ -n "$cardputer_serial_candidate" ] && \
       [ -x "$cardputer_serial_candidate" ] && \
       "$cardputer_serial_candidate" -c 'import serial' >/dev/null 2>&1; then
      printf '%s\n' "$cardputer_serial_candidate"
      return 0
    fi
  done

  printf 'BLOCKED CARDPUTER_SERIAL_PYTHON_UNAVAILABLE install=pyserial\n' >&2
  return 2
}
