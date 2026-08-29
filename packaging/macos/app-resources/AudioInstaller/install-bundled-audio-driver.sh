#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source_archive="$script_dir/CardputerBridgeAudio.driver.zip"
preflight="$script_dir/check-audio-hal-runtime.sh"
destination="/Library/Audio/Plug-Ins/HAL/CardputerBridgeAudio.driver"
backup_root="/Library/Application Support/Cardputer Bridge/Backups/Audio"
failed_root="$backup_root/Failed"
staging_root=""
staging=""
backup=""
old_driver_moved=0
new_driver_installed=0

[[ "${EUID:-$(id -u)}" -eq 0 ]] || {
  printf '需要 macOS 管理员权限。\n' >&2
  exit 1
}
[[ -x "$preflight" ]] || { printf '找不到运行时兼容性检查。\n' >&2; exit 1; }
"$preflight"
[[ -f "$source_archive" ]] || { printf '应用内缺少音频驱动归档。\n' >&2; exit 1; }
[[ ! -L "$source_archive" ]] || { printf '拒绝安装符号链接来源。\n' >&2; exit 1; }
[[ ! -L "$destination" ]] || { printf '拒绝替换符号链接目标。\n' >&2; exit 1; }

rollback() {
  status=$?
  if [[ $status -ne 0 ]]; then
    /bin/mkdir -p "$failed_root" || true
    if [[ $new_driver_installed -eq 1 && -e "$destination" ]]; then
      /bin/mv "$destination" "$failed_root/CardputerBridgeAudio.driver.$$.failed" || true
    fi
    if [[ $old_driver_moved -eq 1 && -e "$backup" && ! -e "$destination" ]]; then
      /bin/mv "$backup" "$destination" || true
    fi
    if [[ -n "$staging_root" && -d "$staging_root" ]]; then
      /bin/mv "$staging_root" "$failed_root/CardputerBridgeAudio.install.$$.failed" || true
    fi
  fi
  exit "$status"
}
trap rollback EXIT

/bin/mkdir -p "/Library/Audio/Plug-Ins/HAL" "$backup_root"
staging_root="$(/usr/bin/mktemp -d "/Library/Audio/Plug-Ins/HAL/.CardputerBridgeAudio.install.XXXXXX")"
staging="$staging_root/CardputerBridgeAudio.driver"
/usr/bin/ditto -x -k "$source_archive" "$staging_root"
[[ -d "$staging" ]] || { printf '音频驱动归档不完整。\n' >&2; exit 1; }
[[ ! -L "$staging" ]] || { printf '拒绝安装符号链接驱动。\n' >&2; exit 1; }
if [[ -n "$(/usr/bin/find "$staging_root" -mindepth 1 -maxdepth 1 ! -name CardputerBridgeAudio.driver -print -quit)" ]]; then
  printf '音频驱动归档包含意外内容。\n' >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$staging"
/usr/sbin/chown -R root:wheel "$staging"
/usr/bin/codesign --verify --deep --strict "$staging"

if [[ -e "$destination" ]]; then
  backup="$backup_root/CardputerBridgeAudio.driver.$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
  /bin/mv "$destination" "$backup"
  old_driver_moved=1
fi
/bin/mv "$staging" "$destination"
new_driver_installed=1
/bin/rmdir "$staging_root"
staging_root=""

/bin/rm -f \
  /tmp/io.nexu.cardputerbridge.audio-v1.sock \
  /tmp/io.nexu.cardputerbridge.audio-v1.sock.lock
/usr/bin/killall coreaudiod 2>/dev/null || true

new_driver_installed=0
trap - EXIT
printf 'Cardputer Microphone 安装完成。\n'
