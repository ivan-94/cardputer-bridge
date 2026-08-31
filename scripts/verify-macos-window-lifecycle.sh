#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
app="${CARDPUTER_MACOS_APP:-$build_root/xcode/Build/Products/Debug/Cardputer Bridge.app}"
executable="$app/Contents/MacOS/Cardputer Bridge"

if [[ ! -x "$executable" ]]; then
  printf 'BLOCKED CARDPUTER_MACOS_APP_NOT_BUILT app=%s\n' "$app" >&2
  exit 2
fi

"$project_dir/scripts/restart-macos-app.sh"

pid="$(
  {
    pgrep -f -x "$executable" || true
    pgrep -f -x "$executable .*" || true
  } | sort -u | head -1
)"
if [[ -z "$pid" ]]; then
  printf 'FAIL CARDPUTER_MACOS_APP_PROCESS_NOT_FOUND\n' >&2
  exit 1
fi

osascript -e \
  'tell application "System Events" to tell process "Cardputer Bridge" to perform action "AXPress" of (first button of window 1 whose role description is "close button")' \
  >/dev/null

for _ in {1..30}; do
  window_count="$(
    osascript -e \
      'tell application "System Events" to tell process "Cardputer Bridge" to count windows'
  )"
  [[ "$window_count" == "0" ]] && break
  sleep 0.1
done
if [[ "$window_count" != "0" ]]; then
  printf 'FAIL CARDPUTER_MACOS_WINDOW_DID_NOT_CLOSE count=%s\n' "$window_count" >&2
  exit 1
fi

for _ in {1..30}; do
  application_info="$(lsappinfo info -app "$pid")"
  [[ "$application_info" == *'type="UIElement"'* ]] && break
  sleep 0.1
done
if [[ "$application_info" != *'type="UIElement"'* ]]; then
  printf 'FAIL CARDPUTER_MACOS_DOCK_ICON_REMAINED_AFTER_CLOSE pid=%s\n' \
    "$pid" >&2
  exit 1
fi

open "$app"

for _ in {1..50}; do
  if ! kill -0 "$pid" 2>/dev/null; then
    printf 'FAIL CARDPUTER_MACOS_CLOSE_REOPEN_CRASHED pid=%s\n' "$pid" >&2
    exit 1
  fi
  window_count="$(
    osascript -e \
      'tell application "System Events" to tell process "Cardputer Bridge" to count windows' \
      2>/dev/null || printf '0'
  )"
  if [[ "$window_count" != "0" ]]; then
    application_info="$(lsappinfo info -app "$pid")"
    if [[ "$application_info" != *'type="Foreground"'* ]]; then
      sleep 0.1
      continue
    fi
    printf 'PASS cardputer_macos_window_close_reopen pid=%s windows=%s\n' \
      "$pid" "$window_count"
    exit 0
  fi
  sleep 0.1
done

printf 'FAIL CARDPUTER_MACOS_WINDOW_DID_NOT_REOPEN pid=%s\n' "$pid" >&2
exit 1
