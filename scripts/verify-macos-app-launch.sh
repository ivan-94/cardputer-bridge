#!/usr/bin/env bash
set -euo pipefail

app="${1:-}"
[[ -d "$app" ]] || {
  printf 'Usage: %s /path/to/Cardputer Bridge.app\n' "$0" >&2
  exit 2
}

executable="$app/Contents/MacOS/Cardputer Bridge"
[[ -x "$executable" ]] || {
  printf 'App executable missing: %s\n' "$executable" >&2
  exit 1
}

log_root="$(mktemp -d /tmp/cardputer-bridge-launch.XXXXXX)"
stdout_log="$log_root/stdout.log"
stderr_log="$log_root/stderr.log"
app_pid=""

cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill -TERM "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  rm -f "$stdout_log" "$stderr_log"
  rmdir "$log_root" 2>/dev/null || true
}
trap cleanup EXIT

"$executable" >"$stdout_log" 2>"$stderr_log" &
app_pid=$!

for _ in {1..40}; do
  if ! kill -0 "$app_pid" 2>/dev/null; then
    printf 'MACOS_APP_LAUNCH_FAIL process_exited\n' >&2
    cat "$stderr_log" >&2
    exit 1
  fi

  resident_kb="$(ps -o rss= -p "$app_pid" | tr -d ' ')"
  if [[ "$resident_kb" =~ ^[0-9]+$ ]] && (( resident_kb >= 16384 )); then
    printf 'MACOS_APP_LAUNCH_PASS pid=%s rss_kb=%s\n' "$app_pid" "$resident_kb"
    exit 0
  fi
  sleep 0.25
done

printf 'MACOS_APP_LAUNCH_FAIL dyld_stall pid=%s rss_kb=%s\n' \
  "$app_pid" "${resident_kb:-unknown}" >&2
cat "$stderr_log" >&2
exit 1
