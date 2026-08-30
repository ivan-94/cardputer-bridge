#!/usr/bin/env bash
set -euo pipefail

bundle_id="io.nexu.cardputerbridge.app"
reset_home="${CARDPUTER_BRIDGE_RESET_HOME:-$HOME}"
backup_root="${CARDPUTER_BRIDGE_RESET_BACKUP_ROOT:-$reset_home/.local/share/cardputer-bridge/reset-backups}"
test_mode="${CARDPUTER_BRIDGE_TEST_MODE:-0}"
confirmed=false
keep_audio_driver=false
launch_app=""

usage() {
  cat <<'EOF'
usage: reset-local-acceptance.sh --confirm-reset [--keep-audio-driver] [--app APP]

Resets Cardputer Bridge on this Mac to its first-run state. User data is moved
to a timestamped backup. Cardputer firmware and the macOS Bluetooth bond are
not changed.
EOF
}

while (($#)); do
  case "$1" in
    --confirm-reset)
      confirmed=true
      shift
      ;;
    --keep-audio-driver)
      keep_audio_driver=true
      shift
      ;;
    --app)
      if (($# < 2)); then
        usage >&2
        exit 2
      fi
      launch_app="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$confirmed" != true ]]; then
  printf 'BLOCKED LOCAL_RESET_NOT_CONFIRMED\n' >&2
  usage >&2
  exit 2
fi

if [[ "$test_mode" == 1 ]]; then
  if [[ -L "$reset_home" || -L "$backup_root" ]]; then
    printf 'FAIL TEST_ROOT_SYMLINK reset_home=%s backup_root=%s\n' \
      "$reset_home" "$backup_root" >&2
    exit 1
  fi
  resolved_home="$(cd "$reset_home" && pwd -P)"
  case "$resolved_home/" in
    "${TMPDIR:-/tmp}"* | /tmp/* | /private/tmp/* | /var/folders/* | /private/var/folders/*) ;;
    *) printf 'FAIL TEST_ROOT_NOT_TEMP root=%s\n' "$resolved_home" >&2; exit 1 ;;
  esac
  reset_home="$resolved_home"
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="$backup_root/$timestamp-$$"
created_backup=false

ensure_backup_dir() {
  if [[ "$created_backup" != true ]]; then
    mkdir -p "$backup_dir"
    created_backup=true
  fi
}

move_to_backup() {
  local source="$1"
  local label="$2"
  if [[ ! -e "$source" && ! -L "$source" ]]; then
    return
  fi
  ensure_backup_dir
  mv "$source" "$backup_dir/$label"
  printf 'BACKED_UP source=%s destination=%s\n' "$source" "$backup_dir/$label"
}

stop_apps() {
  if [[ "$test_mode" == 1 ]]; then
    return
  fi

  matching_pids() {
    {
      pgrep -f -x '.*/Cardputer Bridge\.app/Contents/MacOS/Cardputer Bridge' || true
      pgrep -f -x '.*/Cardputer Bridge\.app/Contents/MacOS/Cardputer Bridge .*' || true
    } | sort -u
  }

  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  for _ in {1..30}; do
    if [[ -z "$(matching_pids)" ]]; then
      return
    fi
    sleep 0.1
  done

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill -TERM "$pid"
  done < <(matching_pids)
}

stop_apps

move_to_backup \
  "$reset_home/Library/Application Support/Cardputer Bridge" \
  "Application Support"
move_to_backup \
  "$reset_home/Library/Preferences/$bundle_id.plist" \
  "$bundle_id.plist"
move_to_backup \
  "$reset_home/Library/Caches/$bundle_id" \
  "Caches"
move_to_backup \
  "$reset_home/Library/HTTPStorages/$bundle_id" \
  "HTTPStorages"
move_to_backup \
  "$reset_home/Library/Saved Application State/$bundle_id.savedState" \
  "Saved Application State"

if [[ "$test_mode" != 1 ]]; then
  defaults delete "$bundle_id" >/dev/null 2>&1 || true
fi

if [[ "$keep_audio_driver" != true ]]; then
  if [[ "$test_mode" == 1 ]]; then
    printf 'SKIPPED_AUDIO_DRIVER_UNINSTALL reason=test-mode\n'
  else
    script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
    "$script_dir/uninstall-audio-plugin.sh" --confirm-system-change
  fi
fi

if [[ "$created_backup" == true ]]; then
  printf 'RESET_COMPLETE recoverable_backup=%s\n' "$backup_dir"
else
  printf 'RESET_COMPLETE previous_state=already-absent\n'
fi
printf 'PRESERVED cardputer_firmware=true bluetooth_bond=true\n'

if [[ -n "$launch_app" ]]; then
  if [[ "$test_mode" == 1 ]]; then
    printf 'SKIPPED_APP_LAUNCH reason=test-mode app=%s\n' "$launch_app"
  elif [[ ! -d "$launch_app" ]]; then
    printf 'FAIL APP_NOT_FOUND app=%s\n' "$launch_app" >&2
    exit 1
  else
    open -n -F "$launch_app" --args -ApplePersistenceIgnoreState YES
    printf 'APP_LAUNCHED app=%s\n' "$launch_app"
  fi
fi
