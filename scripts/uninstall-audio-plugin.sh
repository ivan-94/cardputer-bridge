#!/usr/bin/env bash
set -euo pipefail

hal_root="/Library/Audio/Plug-Ins/HAL"
backup_root="$HOME/.local/share/cardputer-bridge/backups/audio-plugin"
test_mode="${CARDPUTER_BRIDGE_TEST_MODE:-0}"
if [[ "$test_mode" == 1 ]]; then
  hal_root="${CARDPUTER_BRIDGE_HAL_ROOT:?test HAL root required}"
  backup_root="${CARDPUTER_BRIDGE_BACKUP_ROOT:?test backup root required}"
  if [[ -L "$hal_root" || -L "$backup_root" ]]; then
    printf 'FAIL TEST_ROOT_SYMLINK hal_root=%s backup_root=%s\n' "$hal_root" "$backup_root" >&2
    exit 1
  fi
  test_root="$(cd "$(dirname "$hal_root")" && pwd -P)"
  hal_root="$test_root/$(basename "$hal_root")"
  backup_root="$test_root/$(basename "$backup_root")"
  case "$test_root/" in
    "${TMPDIR:-/tmp}"* | /tmp/* | /private/tmp/* | /var/folders/* | /private/var/folders/*) ;;
    *) printf 'FAIL TEST_ROOT_NOT_TEMP root=%s\n' "$test_root" >&2; exit 1 ;;
  esac
fi
destination="$hal_root/CardputerBridgeAudio.driver"
if [[ "$test_mode" == 1 && -L "$destination" ]]; then
  printf 'FAIL DESTINATION_SYMLINK destination=%s\n' "$destination" >&2
  exit 1
fi
confirmed=false

if [[ ${1:-} == "--confirm-system-change" && $# -eq 1 ]]; then
  confirmed=true
elif (($#)); then
  printf 'usage: uninstall-audio-plugin.sh --confirm-system-change\n' >&2
  exit 2
fi

if [[ "$confirmed" != true ]]; then
  printf 'BLOCKED SYSTEM_CHANGE_NOT_CONFIRMED destination=%s\n' "$destination" >&2
  exit 2
fi
if [[ ! -e "$destination" ]]; then
  printf 'ALREADY_ABSENT destination=%s\n' "$destination"
  exit 0
fi

needs_privilege=true
if [[ "$test_mode" == 1 ]]; then needs_privilege=false; fi
run_target() {
  if [[ "$needs_privilege" == true ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

backup_dir="$backup_root/$(date -u +%Y%m%dT%H%M%SZ)-uninstall-$$"
backup_bundle="$backup_dir/CardputerBridgeAudio.driver"
mkdir -p "$backup_dir"
run_target mv "$destination" "$backup_bundle"

printf 'UNINSTALLED destination=%s recoverable_backup=%s\n' "$destination" "$backup_bundle"
printf 'NEXT restart coreaudiod or reboot only after explicit authorization\n'
