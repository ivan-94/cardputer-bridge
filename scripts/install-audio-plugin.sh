#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${CARDPUTER_BRIDGE_BUILD_ROOT:-$HOME/.local/share/cardputer-bridge/build}"
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
source_bundle="$build_root/audio-plugin/CardputerBridgeAudio.driver"
destination="$hal_root/CardputerBridgeAudio.driver"
if [[ "$test_mode" == 1 && -L "$destination" ]]; then
  printf 'FAIL DESTINATION_SYMLINK destination=%s\n' "$destination" >&2
  exit 1
fi
confirmed=false
reload_coreaudio=false

while (($#)); do
  case "$1" in
    --source)
      source_bundle="$2"
      shift 2
      ;;
    --confirm-system-change)
      confirmed=true
      shift
      ;;
    --reload-coreaudio)
      reload_coreaudio=true
      shift
      ;;
    *)
      printf 'usage: install-audio-plugin.sh [--source <bundle>] [--reload-coreaudio] --confirm-system-change\n' >&2
      exit 2
      ;;
  esac
done

if [[ "$confirmed" != true ]]; then
  printf 'BLOCKED SYSTEM_CHANGE_NOT_CONFIRMED destination=%s\n' "$destination" >&2
  exit 2
fi
if [[ "$test_mode" == 1 && "$reload_coreaudio" == true ]]; then
  printf 'FAIL CORE_AUDIO_RELOAD_FORBIDDEN_IN_TEST_MODE\n' >&2
  exit 2
fi
if [[ ! -d "$source_bundle" ]]; then
  printf 'FAIL SOURCE_BUNDLE_MISSING source=%s\n' "$source_bundle" >&2
  exit 1
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

reload_core_audio_service() {
  # A force-stopped out-of-process HAL driver can leave its socket and lock
  # behind. The replacement driver runs as _coreaudiod and may be sandboxed
  # from removing those stale filesystem objects even though it owns them.
  # Remove only this product's exact IPC endpoints before restarting the
  # service, so install + reload needs one authorization session.
  run_target rm -f \
    /tmp/io.nexu.cardputerbridge.audio-v1.sock \
    /tmp/io.nexu.cardputerbridge.audio-v1.sock.lock
  run_target killall coreaudiod
  printf 'CORE_AUDIO_RELOAD_REQUESTED stale_broker_endpoints_removed=true\n'
}

removal_directive="$source_bundle/REMOVE_FROM_HAL"
if [[ -f "$removal_directive" ]]; then
  if [[ "$(cat "$removal_directive")" != 'REMOVE_CARDPUTER_BRIDGE_AUDIO_FROM_HAL_v1' ]]; then
    printf 'FAIL HAL_REMOVAL_DIRECTIVE_INVALID source=%s\n' "$source_bundle" >&2
    exit 1
  fi
  if [[ ! -e "$destination" ]]; then
    printf 'ALREADY_ABSENT destination=%s\n' "$destination"
    exit 0
  fi
  removal_backup_dir="$backup_root/$(date -u +%Y%m%dT%H%M%SZ)-runtime-quarantine-$$"
  removal_backup="$removal_backup_dir/CardputerBridgeAudio.driver"
  mkdir -p "$removal_backup_dir"
  run_target mv "$destination" "$removal_backup"
  printf 'QUARANTINED_FROM_HAL destination=%s recoverable_backup=%s\n' \
    "$destination" "$removal_backup"
  exit 0
fi

probe="$build_root/audio-plugin/factory_probe"
if [[ "$test_mode" != 1 ]]; then
  "$project_dir/scripts/check-audio-hal-runtime.sh"
fi
python3 "$project_dir/harness/verifier/audio_bundle.py" "$source_bundle" "$probe" >/dev/null

if [[ -d "$destination" ]] && diff -qr "$source_bundle" "$destination" >/dev/null; then
  printf 'ALREADY_INSTALLED destination=%s\n' "$destination"
  if [[ "$reload_coreaudio" == true ]]; then
    reload_core_audio_service
  fi
  exit 0
fi

mkdir -p "$backup_root"
run_target mkdir -p "$hal_root"
staging="$hal_root/.CardputerBridgeAudio.install.$$.driver"
backup_dir="$backup_root/$(date -u +%Y%m%dT%H%M%SZ)-$$"
backup_bundle="$backup_dir/CardputerBridgeAudio.driver"
mkdir -p "$backup_dir"

previous_moved=false
rollback() {
  rollback_exit=$?
  if [[ $rollback_exit -ne 0 && "$previous_moved" == true && ! -e "$destination" && -e "$backup_bundle" ]]; then
    run_target mv "$backup_bundle" "$destination" || true
  fi
  if [[ $rollback_exit -ne 0 && -e "$staging" ]]; then
    run_target mv "$staging" "$backup_dir/failed-staging.driver" || true
  fi
  exit "$rollback_exit"
}
trap rollback EXIT

run_target ditto "$source_bundle" "$staging"
python3 "$project_dir/harness/verifier/audio_bundle.py" "$staging" "$probe" >/dev/null

if [[ -e "$destination" ]]; then
  run_target mv "$destination" "$backup_bundle"
  previous_moved=true
fi
if [[ "$test_mode" == 1 && "${CARDPUTER_BRIDGE_TEST_FAIL_AFTER_BACKUP:-0}" == 1 ]]; then
  printf 'FAIL INJECTED_AFTER_BACKUP\n' >&2
  false
fi
if [[ "$needs_privilege" == true ]]; then
  run_target chown -R root:wheel "$staging"
fi
run_target mv "$staging" "$destination"
trap - EXIT

printf 'INSTALLED destination=%s backup=%s\n' "$destination" "$backup_bundle"
if [[ "$reload_coreaudio" == true ]]; then
  reload_core_audio_service
else
  printf 'NEXT rerun with --reload-coreaudio or reboot only after explicit authorization\n'
fi
